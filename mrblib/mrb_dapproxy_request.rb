# DAP Proxy
class DapProxy
  def mruby_step_in(message)
    return message unless stop_at_mruby_code?

    #    @mruby_code_fetch_bp.use_stepin_breakpoint = true
    #    @debugger.setFunctionBreakpoints(@mruby_code_fetch_bp.c_breakpoints) do |res|
    @debugger.evaluate({ 'expression' => "#{@debugger_config[:expression_prefix]}tbreak mrb_debug_breakpoint_function",
                         'context' => 'repl' }) do |res|
      @logger.puts res
      return message if res['success'] == false
    end
    message['command'] = 'continue'
    message
  end

  def mruby_next(message)
    return message unless stop_at_mruby_code?

    @logger.puts "framdid = #{@frame_id}"
    return message unless mruby_break('mruby_next')

    @mruby_code_fetch_bp.use_next_breakpoint = true
    @debugger.setBreakpoints(@mruby_code_fetch_bp.c_breakpoints_line) do |res|
      return message if res['success'] == false
    end
    message['command'] = 'continue'
    message
  end

  def mruby_step_out(message)
    return message unless stop_at_mruby_code?

    return message unless mruby_break('mruby_step_out')

    @mruby_code_fetch_bp.use_stepout_breakpoint = true
    @debugger.setBreakpoints(@mruby_code_fetch_bp.c_breakpoints_line) do |res|
      return message if res['success'] == false
    end
    message['command'] = 'continue'
    message
  end

  # The native frame of the stop (the synthetic [mruby] frame is one id below it).
  def native_frame_id
    @last_stack['id'] + 1
  end

  # lldb-dap's command interpreter has no target, so a command such as `expr` cannot see `mrb`.
  # With :watch_evaluate the expression is evaluated by the DAP-managed path instead.
  def mruby_evaluate(expression)
    args = if @debugger_config[:watch_evaluate]
             { 'expression' => expression, 'context' => 'watch', 'frameId' => native_frame_id }
           else
             { 'expression' => "#{@debugger_config[:expression_prefix]}expr -R -f s -- #{expression}",
               'frameId' => @last_stack['id'] }
           end
    @logger.puts "mruby_evaluate: context=#{args['context']} frameId=#{args['frameId']} expression=#{args['expression']}"
    res = nil
    @debugger.evaluate(args) { |response| res = response }
    @logger.puts res
    res
  end

  # mrb_break() returns void, which the expression path rejects, so it is wrapped in a comma expression.
  def mruby_break(caller_name)
    args = if @debugger_config[:watch_evaluate]
             { 'expression' => '(int)(mrb_break(mrb), 0)', 'context' => 'watch', 'frameId' => native_frame_id }
           else
             { 'expression' => "#{@debugger_config[:expression_prefix]}expr mrb_break(mrb)",
               'context' => 'repl', 'frameId' => native_frame_id }
           end
    res = nil
    @debugger.evaluate(args) { |response| res = response }
    @logger.puts res
    return true unless res.nil? || res['success'] == false

    @logger.puts "#{caller_name}: mrb_break failed"
    false
  end

  def parse_mruby_expr(result_str)
    return nil unless result_str.is_a?(String)

    # lldb-dap: 0x000000011802b704 "[\"a\", \"b\"]" (LLDB appends ... when it truncates the summary)
    matched = result_str.scan(/\A0x[0-9a-fA-F]+ "(.*)"(\.\.\.)?\z/m)
    unless matched.empty?
      # mruby-onig-regexp returns "" (not nil) for a group that did not participate
      if !matched[0][1].nil? && !matched[0][1].empty?
        @logger.puts 'parse_mruby_expr: LLDB truncated the string summary'
        return nil
      end
      return eval_mruby_literal(unescape_lldb_summary(matched[0][0]))
    end

    # command interpreter: (const char *) $0 = "["a", "b"]"
    matched = result_str.scan(/^\(const char \*\) \$\d+ = "(.*)"$/)
    return eval_mruby_literal(matched[0][0]) unless matched.empty?

    nil
  end

  def eval_mruby_literal(text)
    instance_eval(text)
  rescue ScriptError, StandardError => e
    @logger.puts "parse_mruby_expr: cannot evaluate #{text.inspect}: #{e}"
    nil
  end

  def unescape_lldb_summary(str)
    chars = str.chars
    out = ''
    i = 0
    while i < chars.size
      c = chars[i]
      if c == '\\' && i + 1 < chars.size
        n = chars[i + 1]
        case n
        when '"', '\\' then out << n
        when 'n' then out << "\n"
        when 't' then out << "\t"
        when 'r' then out << "\r"
        else out << c << n
        end
        i += 2
      else
        out << c
        i += 1
      end
    end
    out
  end

  def mruby_variables_expr(index)
    "mrb_debug_get_#{MRUBY_VARIABLE_TYPE[index]}_variables(mrb)"
  end

  def mruby_variable_expr(index, varname)
    "mrb_debug_get_#{MRUBY_VARIABLE_TYPE[index]}_variable(mrb, \"#{varname}\")"
  end

  def mruby_scopes(message)
    @logger.puts "mruby_scopes: frameId=#{message['arguments']['frameId']} " \
                 "last_stack=#{@last_stack.nil? ? 'nil' : @last_stack['id']} " \
                 "code_fetch_bp=#{@mruby_code_fetch_bp.nil? ? 'nil' : 'set'}"
    return message if @mruby_code_fetch_bp.nil?
    return message if @last_stack.nil?
    return message unless stop_at_mruby_code?
    return message if message['arguments']['frameId'] != @last_stack['id']

    scope_body = { 'scopes' => [] }
    seq = 0
    0.upto 2 do |i|
      res = mruby_evaluate(mruby_variables_expr(i))
      next if res.nil? || !res['success']

      seq = res['seq']
      variables = parse_mruby_expr(res['body']['result'])
      next if variables.nil?

      scope_body['scopes'].push({ 'name' => "#{MRUBY_VARIABLE_TYPE[i]} variables",
                                  'presentationHint' => "#{MRUBY_VARIABLE_TYPE[i]}s",
                                  'namedVariables' => variables.size,
                                  'indexedVariables' => 0,
                                  'expensive' => false,
                                  'variablesReference' => i + 1 })
    end
    response = { 'seq' => seq, 'type' => 'response', 'request_seq' => message['seq'],
                 'success' => true, 'command' => 'scopes', 'body' => scope_body }
    @logger.puts '<=========='
    @logger.puts response
    send_message(@client_out, response)
    return nil
  end

  def mruby_variable(var_index, varname)
    res = mruby_evaluate(mruby_variable_expr(var_index, varname))
    return parse_mruby_expr(res['body']['result']) if !res.nil? && res['success']

    {}
  end

  def mruby_variables(message)
    return message unless stop_at_mruby_code?

    var_index = message['arguments']['variablesReference'] - 1
    res = mruby_evaluate(mruby_variables_expr(var_index))
    return message if res.nil? || !res['success']

    vars = []
    var_list = parse_mruby_expr(res['body']['result']) || []
    var_list.each do |varname|
      v = mruby_variable(var_index, varname)
      unless v.nil?
        v['variablesReference'] = 0
        vars.push v
      end
    end
    response = { 'seq' => res['seq'], 'type' => 'response', 'request_seq' => message['seq'],
                 'success' => true, 'command' => 'variables', 'body' => { 'variables' => vars } }
    @logger.puts '<=========='
    @logger.puts response
    send_message(@client_out, response)
    nil
  end

  def mruby_set_function_breakpoints(message)
    return message if @mruby_code_fetch_bp.nil?

    # message['arguments']['breakpoints'].concat(@mruby_code_fetch_bp.c_breakpoints['breakpoints'])
    message
  end
end
