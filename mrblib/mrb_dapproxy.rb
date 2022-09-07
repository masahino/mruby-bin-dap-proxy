class DapProxy
  MRUBY_CODE_FETCH_FUNC = 'mrb_debug_breakpoint_function'.freeze
  MRUBY_VARIABLE_TYPE = %w[local global instance].freeze

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
    prepare_mruby_breakpoint if @mruby_code_fetch_bp.nil?
    return message if @mruby_code_fetch_bp.nil?

    @mruby_code_fetch_bp.clear_breakpoints(mrb_filename)
    @mruby_code_fetch_bp.set_breakpoints(mrb_filename, message['arguments']['breakpoints'])
    message['command'] = 'setFunctionBreakpoints'
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

  def prepare_mruby_breakpoint
    @mruby_code_fetch_bp = MrubyBreakpoint.new(MRUBY_CODE_FETCH_FUNC)
#    bp = DAP::Type::FunctionBreakpoint.new(MRUBY_CODE_FETCH_FUNC)
#    @client.setFunctionBreakpoints({ 'breakpoints' => [bp] }) do |res|
#      if res['success'] && !res['body']['breakpoints'][0]['source'].nil?
#        @mruby_code_fetch_source = res['body']['breakpoints'][0]['source']
#        @mruby_code_fetch_line = res['body']['breakpoints'][0]['line'].to_i + 20 # 8
#        @mruby_code_fetch_bp = MrubyBreakpoint.new(@mruby_code_fetch_source['path'], @mruby_code_fetch_line)
#      end
#    end
#    @client.setFunctionBreakpoints({ 'breakpoints' => [] }) do |res|
#    end
  end

  def delete_temporary_breakpoint
    return message if @mruby_code_fetch_bp.nil?

    @mruby_code_fetch_bp.use_stepin_breakpoint = false
    @mruby_code_fetch_bp.stepover_breakpoint = 0
    @client.setFunctionBreakpoints(@mruby_code_fetch_bp.c_breakpoints) do |res|
    end
  end

  def stop_at_mruby_code?
    return false if @last_stack.nil?
    return true if File.extname(@last_stack['source']['path']) == '.rb'

    false
  end

  def process_client
    headers, message = recv_message($stdin)
    return if headers == {}

    if message['type'] == 'request'
      @request_buffer.push message.dup
      case message['command']
      when 'setBreakpoints'
        message = breakpoints_r2c(message)
      when 'setFunctionBreakponts'
        message = mruby_set_function_breakpoints(message)
      when 'stepIn'
        message = mruby_step_in(message)
      when 'next'
        message = mruby_next(message)
      when 'stepOut'
        message = mruby_step_out(message)
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
    return message if @last_stack['name'] != MRUBY_CODE_FETCH_FUNC

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
          @last_ciidx = var['value'].to_i if var['name'] == 'ciidx'
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
          $stderr.puts message
        end
      when 'terminated'
        terminate(message)
      end
    end
    if message['type'] == 'response'
      case message['command']
      when 'setBreakpoints'
        message = breakpoints_c2r(message) unless @mruby_code_fetch_bp.nil?
      when 'stackTrace'
        message = add_mruby_stack(message) unless @mruby_code_fetch_bp.nil?
      when 'stepIn', 'next'
        message = restore_response(message) unless @mruby_code_fetch_bp.nil?
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

def __main__(argv)
  lldb_vscode_path = 'lldb-vscode'
  argv.each_with_index do |arg, i|
    case arg
    when '-l', '--lldb_vscode_path'
      lldb_vscode_path = argv[i + 1] unless argv[i + 1].nil?
    end
  end
  DapProxy.new(lldb_vscode_path).run
end
