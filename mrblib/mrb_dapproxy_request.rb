class DapProxy
  def mruby_step_in(message)
    return message unless stop_at_mruby_code?

    #    @mruby_code_fetch_bp.use_stepin_breakpoint = true
    #    @debugger.setFunctionBreakpoints(@mruby_code_fetch_bp.c_breakpoints) do |res|
    @debugger.evaluate({ 'expression' => '`tbreak mrb_debug_breakpoint_function' }) do |res|
      return message if res['sucess'] == false
    end
    message['command'] = 'continue'
    message
  end

  def mruby_next(message)
    return message unless stop_at_mruby_code?

    @debugger.evaluate({ 'expression' => '`expr mrb_break(mrb)' }) do |res|
      return message if res['sucess'] == false
    end
    @mruby_code_fetch_bp.use_next_breakpoint = true
    @debugger.setBreakpoints(@mruby_code_fetch_bp.c_breakpoints_line) do |res|
      return message if res['sucess'] == false
    end
    message['command'] = 'continue'
    message
  end

  def mruby_step_out(message)
    return message unless stop_at_mruby_code?

    @debugger.evaluate({ 'expression' => '`expr mrb_break(mrb)' }) do |res|
      return message if res['sucess'] == false
    end
    @mruby_code_fetch_bp.use_stepout_breakpoint = true
    @debugger.setBreakpoints(@mruby_code_fetch_bp.c_breakpoints_line) do |res|
      return message if res['sucess'] == false
    end
    message['command'] = 'continue'
    message
  end

  def parse_mruby_expr(result_str)
    vars = nil
#    line.scan(/\{name=\\?"(.+?)\\?",value=\\?"(.+?)\\?",type=\\?"(.+?)\\?"\}/) do |match|
#    result_str.scan(/^\(const char \*\) \$\d+ = "([])"$/) do |match|
    result_str.scan(/^\(const char \*\) \$\d+ = "(.*)"$/) do |match|
      vars = instance_eval(match[0])
    end
    vars
  end

  def mruby_variables_expr(index)
    "`expr -R -f s -- mrb_debug_get_#{MRUBY_VARIABLE_TYPE[index]}_variables(mrb)"
  end

  def mruby_variable_expr(index, varname)
    "`expr -R -f s -- mrb_debug_get_#{MRUBY_VARIABLE_TYPE[index]}_variable(mrb, \"#{varname}\")"
  end

  def mruby_scopes(message)
    return message if @mruby_code_fetch_bp.nil?
    return message if @last_stack.nil?
    return message if message['arguments']['frameId'] != @last_stack['id']

    scope_body = { 'scopes' => [] }
    seq = 0
    0.upto 2 do |i|
      @debugger.evaluate({ 'expression' => mruby_variables_expr(i), 'frameId' => @last_stack['id'] }) do |res|
        if res['success']
          variables = parse_mruby_expr(res['body']['result'])
          unless variables.nil?
            scope_body['scopes'].push({ 'name' => "#{MRUBY_VARIABLE_TYPE[i]} variables",
                                        'presentationHint' => "#{MRUBY_VARIABLE_TYPE[i]}s",
                                        'namedVariables' => variables.size,
                                        'indexedVariables' => 0,
                                        'expensive' => false,
                                        'variablesReference' => i + 1 })
          end
          seq = res['seq']
        end
      end
    end
    response = { 'seq' => seq, 'type' => 'response', 'request_seq' => message['seq'],
                 'success' => true, 'command' => 'scopes', 'body' => scope_body }
    send_message(@client_out, response)
    return nil
  end

  def mruby_variable(var_index, frame_id, varname)
    @debugger.evaluate({ 'expression' => mruby_variable_expr(var_index, varname), 'frameId' => frame_id }) do |res|
      if res['success']
        return parse_mruby_expr(res['body']['result'])
      end
    end
    {}
  end

  def mruby_variables(message)
    return message unless stop_at_mruby_code?

    var_index = message['arguments']['variablesReference'] - 1
    @debugger.evaluate({ 'expression' => mruby_variables_expr(var_index), 'frameId' => @last_stack['id'] }) do |res|
      if res['success']
        vars = []
        var_list = parse_mruby_expr(res['body']['result'])
        var_list.each do |varname|
          v = mruby_variable(var_index, @last_stack['id'], varname)
          unless v.nil?
            v['variablesReference'] = 0
            vars.push v
          end
        end
        response = { 'seq' => res['seq'], 'type' => 'response', 'request_seq' => message['seq'],
                     'success' => true, 'command' => 'variables', 'body' => { 'variables' => vars } }
        send_message(@client_out, response)
        return nil
      end
    end
    message
  end

  def mruby_set_function_breakpoints(message)
    return message if @mruby_code_fetch_bp.nil?

    # message['arguments']['breakpoints'].concat(@mruby_code_fetch_bp.c_breakpoints['breakpoints'])
    message
  end
end
