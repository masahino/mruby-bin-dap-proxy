class DapProxy
  MRUBY_CODE_FETCH_FUNC = 'mrb_gdb_code_fetch'.freeze

  def initialize(adapter = 'lldb-vscode', adapter_args = {})
    @client = DAP::Client.new(adapter, adapter_args)
    #    @client = DAP::Client.new("#{ENV['HOME']}/.vscode/extensions/vadimcn.vscode-lldb-1.7.4/adapter/codelldb",
    #        { 'args' => ['--port 4711'], 'port' => 4711 })
    @client.exec_debug_adapter
    @readings = [$stdin, @client.io]
    @mruby_code_fetch_source = nil
    @mruby_code_fetch_line = 0
    @mruby_code_fetch_bp = nil
    @last_filename = ''
    @last_line = ''
    @last_ciidx = 999
    @last_stack = nil
    @request_buffer = []
  end

  def breakpoints_r2c(message)
    return message if File.extname(message['arguments']['source']['path']) != '.rb'

    mrb_filename = message['arguments']['source']['path']
    prepare_mruby_breakpoint if @mruby_code_fetch_source.nil?
    return message if @mruby_code_fetch_bp.nil?

    @mruby_code_fetch_bp.clear_breakpoints(mrb_filename)
    @mruby_code_fetch_bp.set_breakpoints(mrb_filename, message['arguments']['breakpoints'])
    message['arguments'] = @mruby_code_fetch_bp.c_breakpoints
    message
  end

  def breakpoints_c2r(message)
    @request_buffer.select { |req| req['seq'] == message['request_seq'] }.each do |org_req|
      org_source = org_req['arguments']['source']
      org_bp = org_req['arguments']['breakpoints']
      message['body']['breakpoints'].each_with_index do |bp, i|
        unless bp['source'].nil?
          message['body']['breakpoints'][i]['source'] = org_source
          message['body']['breakpoints'][i]['line'] = org_bp[i]['line']
        end
      end
    end
    message
  end

  def stop_at_mruby_code?
    return false if @last_stack.nil?
    return true if File.extname(@last_stack['source']['path']) == '.rb'

    false
  end

  def mruby_step_in(message)
    return message unless stop_at_mruby_code?

    @mruby_code_fetch_bp.use_stepin_breakpoint = true
    @client.setBreakpoints(@mruby_code_fetch_bp.c_breakpoints) do |res|
      return message if res['sucess'] == false
    end
    message['command'] = 'continue'
    message
  end

  def mruby_next(message)
    return message unless stop_at_mruby_code?

    @mruby_code_fetch_bp.stepover_breakpoint = @last_ciidx
    @client.setBreakpoints(@mruby_code_fetch_bp.c_breakpoints) do |res|
      return message if res['sucess'] == false
    end
    message['command'] = 'continue'
    message
  end

  def mruby_parse_locals(line)
    variables = []
    index = 0
    line.scan(/\{name=\\?"(.+?)\\?",value=\\?"(.+?)\\?",type=\\?"(.+?)\\?"\}/) do |match|
      value = if match[2] == 'String'
                match[1].delete_prefix('\\').gsub(/\\"/, '"')
              else
                match[1]
              end
      variables.push({ 'name' => match[0], 'value' => value, 'type' => match[2],
                       'variablesReference' => index })
      index += 1
    end
    variables
  end

  def mruby_scopes(message)
    return message if @mruby_code_fetch_bp.nil?
    return message if @last_stack.nil?
    return message if message['arguments']['frameId'] != @last_stack['id']

    @client.evaluate({ 'expression' => '`expr mrb_gdb_get_locals(mrb)', 'frameId' => @last_stack['id'] }) do |res|
      if res['success']
        variables = mruby_parse_locals(res['body']['result'])
        scope_body = { 'scopes' => [{ 'name' => 'Local variables',
                                      'presentationHint' => 'locals',
                                      'namedVariables' => variables.size,
                                      'indexedVariables' => 0,
                                      'expensive' => false,
                                      'variablesReference' => 1 }] }
        response = { 'seq' => res['seq'], 'type' => 'response', 'request_seq' => message['seq'],
                     'success' => true, 'command' => 'scopes', 'body' => scope_body }
        send_message($stdout, response)
        return nil
      end
    end
    message
  end

  def mruby_variables(message)
    return message unless stop_at_mruby_code?

    @client.evaluate({ 'expression' => '`expr mrb_gdb_get_locals(mrb)', 'frameId' => @last_stack['id'] }) do |res|
      if res['success']
        variables = mruby_parse_locals(res['body']['result'])
        response = { 'seq' => res['seq'], 'type' => 'response', 'request_seq' => message['seq'],
                     'success' => true, 'command' => 'variables', 'body' => { 'variables' => variables } }
        send_message($stdout, response)
        return nil
      end
    end
    message
  end

  def process_client
    headers, message = recv_message($stdin)
    return if headers == {}

    if message['type'] == 'request'
      @request_buffer.push message.dup
      case message['command']
      when 'setBreakpoints'
        message = breakpoints_r2c(message)
      when 'stepIn'
        message = mruby_step_in(message)
      when 'next'
        message = mruby_next(message)
      when 'scopes'
        message = mruby_scopes(message)
        return if message.nil?
      when 'variables'
        message = mruby_variables(message)
        return if message.nil?
      end
    end
    @client.send_message(message)
  end

  def add_mruby_stack(message)
    levels = 0
    @request_buffer.select { |req| req['seq'] == message['request_seq'] }.each do |org_req|
      if !org_req['arguments']['startFrame'].nil? && org_req['arguments']['startFrame'] > 0
        return message
      end
      levels = org_req['arguments']['levels'] unless org_req['arguments']['levels'].nil?
    end

    @last_stack = message['body']['stackFrames'][0]
    frame_id = @last_stack['id'].to_i
    return message if @last_stack['source']['path'] != @mruby_code_fetch_source['path']

    mrb_stack = { 'column' => 1, 'id' => @last_stack['id'] - 1, 'name' => MRUBY_CODE_FETCH_FUNC }
    @client.scopes({ 'frameId' => frame_id }) do |res|
      return message if res['success'] == false
    end
    @client.variables({ 'variablesReference' => 2 }) do |res|
      if res['success']
        res['body']['variables'].each do |var|
          if var['name'] == 'filename'
            mrb_stack['source'] = DAP::Type::Source.new(var['value'].split(' ')[-1].gsub('"', '')).to_h
          end
          mrb_stack['line'] = var['value'].to_i if var['name'] == 'line'
          @last_ciidx = var['value'].to_i if var['name'] == 'prev_ciidx'
        end
        @last_stack = mrb_stack
        message['body']['totalFrames'] += 1
        if levels == 1
          message['body']['stackFrames'][0] = mrb_stack
        else
          message['body']['stackFrames'].unshift mrb_stack
        end
      end
    end
    message
  end

  def prepare_mruby_breakpoint
    bp = DAP::Type::FunctionBreakpoint.new(MRUBY_CODE_FETCH_FUNC)
    @client.setFunctionBreakpoints({ 'breakpoints' => [bp] }) do |res|
      if res['success'] && !res['body']['breakpoints'][0]['source'].nil?
        @mruby_code_fetch_source = res['body']['breakpoints'][0]['source']
        @mruby_code_fetch_line = res['body']['breakpoints'][0]['line'].to_i + 20 # 8
        @mruby_code_fetch_bp = MrubyBreakpoint.new(@mruby_code_fetch_source['path'], @mruby_code_fetch_line)
      end
    end
    @client.setFunctionBreakpoints({ 'breakpoints' => [] }) do |res|
    end
  end

  def delete_temporary_breakpoint
    return message if @mruby_code_fetch_bp.nil?

    @mruby_code_fetch_bp.use_stepin_breakpoint = false
    @mruby_code_fetch_bp.stepover_breakpoint = 0
    @client.setBreakpoints(@mruby_code_fetch_bp.c_breakpoints) do |res|
    end
  end

  def restore_response(message)
    @request_buffer.select { |req| req['seq'] == message['request_seq'] }.each do |org_req|
      message['command'] = org_req['command']
    end
    message
  end

  def process_adapter
    message = @client.wait_message
    if message['type'] == 'event'
      case message['event']
      when 'stopped'
        if !@mruby_code_fetch_bp.nil? && @mruby_code_fetch_bp.use_temporary_breakpoint
          delete_temporary_breakpoint
        end
      when 'terminated'
        terminate(message)
      end
    end
    if message['type'] == 'response'
      case message['command']
      when 'setBreakpoints'
        message = breakpoints_c2r(message) unless @mruby_code_fetch_source.nil?
      when 'stackTrace'
        message = add_mruby_stack(message) unless @mruby_code_fetch_source.nil?
      when 'stepIn', 'next'
        message = restore_response(message) unless @mruby_code_fetch_source.nil?
      end
    end
    @request_buffer.delete_if { |request| request['seq'] == message['request_seq'] }
    send_message($stdout, message)
  end

  def terminate(message)
    send_message($stdout, message)
    exit
  end

  def run
    loop do
      readable, _writable = IO.select(@readings)
      readable.each do |ri|
        if ri == $stdin
          process_client
        elsif ri == @client.io
          process_adapter # unless @client.io.eof?
        end
      end
    end
  end
end

def __main__(_argv)
  DapProxy.new.run
end
