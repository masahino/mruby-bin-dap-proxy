class DapProxy
  MRUBY_CODE_FETCH_FUNC = 'mrb_gdb_code_fetch'.freeze

  def initialize
    @client = DAP::Client.new('lldb-vscode', {})
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

  def breakpoints_c2r(message)
    mrb_filename = message['arguments']['source']['path']
    prepare_mruby_breakpoint if @mruby_code_fetch_source.nil?
    return message if @mruby_code_fetch_bp.nil?

    @mruby_code_fetch_bp.clear_breakpoints(mrb_filename)
    @mruby_code_fetch_bp.set_breakpoints(mrb_filename, message['arguments']['breakpoints'])
    message['arguments'] = @mruby_code_fetch_bp.c_breakpoints
    message
  end

  def mruby_step_in(message)
    return message if @mruby_code_fetch_bp.nil?

    @mruby_code_fetch_bp.use_stepin_breakpoint = true
    @client.setBreakpoints(@mruby_code_fetch_bp.c_breakpoints) do |res|
      return message if res['sucess'] == false
    end
    message['command'] = 'continue'
    message
  end

  def mruby_next(message)
    return message if @mruby_code_fetch_bp.nil?

    @mruby_code_fetch_bp.stepover_breakpoint = @last_ciidx
    @client.setBreakpoints(@mruby_code_fetch_bp.c_breakpoints) do |res|
      return message if res['sucess'] == false
    end
    message['command'] = 'continue'
    message
  end

  def process_client
    headers, message = recv_message($stdin)
    return if headers == {}

    if message['type'] == 'request'
      case message['command']
      when 'setBreakpoints'
        if File.extname(message['arguments']['source']['path']) == '.rb'
          message = breakpoints_c2r(message)
        end
      when 'stepIn'
        if !@last_stack.nil? && File.extname(@last_stack['source']['path']) == '.rb'
          message = mruby_step_in(message)
        end
      when 'next'
        if !@last_stack.nil? && File.extname(@last_stack['source']['path']) == '.rb'
          message = mruby_next(message)
        end
      end
    end
    @request_buffer.push message
    @client.send_message(message)
  end

  def add_mruby_stack(message)
    @last_stack = message['body']['stackFrames'][0]
    frame_id = @last_stack['id'].to_i

    return message if @last_stack['source']['path'] != @mruby_code_fetch_source['path']

    mrb_stack = { 'column' => 1, 'id' => 0, 'name' => MRUBY_CODE_FETCH_FUNC }
    @client.scopes({ 'frameId' => frame_id }) do |res|
      return message if res['sucess'] == false
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
        message['body']['stackFrames'].unshift mrb_stack
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

  def process_adapter
    message = @client.wait_message
    if message['type'] == 'event'
      case message['event']
      when 'stopped'
        if !@mruby_code_fetch_bp.nil? && @mruby_code_fetch_bp.use_temporary_breakpoint
          delete_temporary_breakpoint
        end
      end
    end
    if message['type'] == 'response'
      case message['command']
      when 'stackTrace'
        message = add_mruby_stack(message) unless @mruby_code_fetch_source.nil?
      end
    end
    send_message($stdout, message)
  end

  def run
    loop do
      readable, _writable = IO.select(@readings)
      readable.each do |ri|
        if ri == $stdin
          process_client
        elsif ri == @client.io
          process_adapter unless @client.io.eof?
        end
      end
    end
  end
end

def __main__(_argv)
  DapProxy.new.run
end
