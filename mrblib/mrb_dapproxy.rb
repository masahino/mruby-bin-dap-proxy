# DAP proxy
class DapProxy
  MRUBY_CODE_FETCH_FUNC = 'mrb_debug_breakpoint_function'.freeze
  MRUBY_VARIABLE_TYPE = %w[local global instance].freeze

  DEFAULT_CONFIG = {
    adapter: 'lldb-vscode',
    adapter_type: 'lldb-vscode',
    adapter_port: nil,
    client_port: nil,
    mrb_debug_path: nil,
    mrb_debug_line: nil
  }.freeze
  DEFAULT_DEBUGGER_CONFIG = {
    variable_references: 2, # variableReferences for global variables
    condition_prefix: '',
    expression_prefix: '`'
  }.freeze

  def initialize(config = DEFAULT_CONFIG)
    setup_logfile(config)
    setup_debugger(config)
    @readings = [@debugger.io]
    setup_client_io(config[:port])
    setup_mruby_breakpoint(config)
    @last_filename = ''
    @last_line = ''
    @last_ciidx = 999
    @last_stack = nil
    @request_buffer = []
  end

  def setup_mruby_breakpoint(config)
    @mruby_code_fetch_source = nil
    unless config[:mrb_debug_path].nil?
      @mruby_code_fetch_source = DAP::Type::Source.new(config[:mrb_debug_path]).to_h
    end
    @mruby_code_fetch_line = 0
    unless config[:mrb_debug_line].nil?
      @mruby_code_fetch_line = config[:mrb_debug_line]
    end
    @mruby_code_fetch_bp = nil
    if !@mruby_code_fetch_source.nil? && !@mruby_code_fetch_line.nil?
      @mruby_code_fetch_bp = MrubyBreakpoint.new(@mruby_code_fetch_source['path'],
                                                 @mruby_code_fetch_line,
                                                 MRUBY_CODE_FETCH_FUNC,
                                                 @debugger_config[:condition_prefix])
    end
  end

  def setup_logfile(config)
    @logger = $stderr
    unless config[:logfile].nil?
      @logger = File.open(config[:logfile], 'w')
    end
    @logger.puts config
  end

  def setup_debugger(config)
    adapter_args = {}
    unless config[:adapter_port].nil?
      adapter_args = { 'args' => ["--port #{config[:adapter_port]}"], 'port' => config[:adapter_port] }
    end
    @debugger = DAP::Client.new(config[:adapter], adapter_args)
    @debugger.exec_debug_adapter
    @debugger_config = DEFAULT_DEBUGGER_CONFIG
    if config[:adapter_type] == 'lldb'
      @debugger_config[:variable_references] = 1003
      @debugger_config[:condition_prefix] = '/nat '
      @debugger_config[:expression_prefix] = ''
    end
  end

  def setup_client_io(port)
    if port.nil?
      @client_in = $stdin
      @client_out = $stdout
      @readings.push @client_in
      return
    end

    @client_in = nil
    @client_out = nil
    @acceptor = TCPServer.open(port)
    @readings.push @acceptor
  end

  def breakpoints_r2c(message)
    return message if File.extname(message['arguments']['source']['path']) != '.rb'

    mrb_filename = message['arguments']['source']['path']
    prepare_mruby_breakpoint if @mruby_code_fetch_bp.nil?
    return message if @mruby_code_fetch_bp.nil?

    @mruby_code_fetch_bp.clear_breakpoints(mrb_filename)
    @mruby_code_fetch_bp.set_breakpoints(mrb_filename, message['arguments']['breakpoints'])
    #    message['command'] = 'setFunctionBreakpoints'
    message['arguments'] = @mruby_code_fetch_bp.c_breakpoints_line
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
    # @mruby_code_fetch_bp = MrubyBreakpoint.new(MRUBY_CODE_FETCH_FUNC)
    bp = DAP::Type::FunctionBreakpoint.new(MRUBY_CODE_FETCH_FUNC)
    @debugger.setFunctionBreakpoints({ 'breakpoints' => [bp] }) do |res|
      @logger.puts res
      if res['success'] && !res['body']['breakpoints'][0]['source'].nil?
        @mruby_code_fetch_source = res['body']['breakpoints'][0]['source']
        @mruby_code_fetch_line = res['body']['breakpoints'][0]['line'].to_i
        @mruby_code_fetch_bp = MrubyBreakpoint.new(@mruby_code_fetch_source['path'],
                                                   @mruby_code_fetch_line, MRUBY_CODE_FETCH_FUNC)
      end
    end
    @debugger.setFunctionBreakpoints({ 'breakpoints' => [] }) do |res|
    end
  end

  def delete_temporary_breakpoint
    return message if @mruby_code_fetch_bp.nil?

    @mruby_code_fetch_bp.use_stepin_breakpoint = false
    @mruby_code_fetch_bp.use_next_breakpoint = false
    @mruby_code_fetch_bp.use_stepout_breakpoint = false
    @debugger.setBreakpoints(@mruby_code_fetch_bp.c_breakpoints_line) do |res|
    end
  end

  def stop_at_mruby_code?
    return false if @last_stack.nil?
    return true if File.extname(@last_stack['source']['path']) == '.rb'

    false
  end

  def process_client
    headers, message = recv_message(@client_in)
    return if headers == {}

    @logger.puts '---------->'
    @logger.puts message
    if message['type'] == 'request'
      @request_buffer.push message.dup
      case message['command']
        # when 'initialize'
        # message['arguments']['adapterID'] = 'lldb'
        # when 'attach'
        # message['arguments']['type'] = 'lldb'
      when 'setBreakpoints'
        message = breakpoints_r2c(message)
      when 'setFunctionBreakpoints'
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
    @logger.puts "\t==========>"
    @logger.puts message
    @debugger.send_message(message)
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
    @debugger.scopes({ 'frameId' => frame_id }) do |res|
      @logger.puts res
      return message if res['success'] == false
    end
    @debugger.variables({ 'variablesReference' => @debugger_config[:variable_references] }) do |res|
      @logger.puts res
      if res['success']
        res['body']['variables'].each do |var|
          if var['name'] == 'filename'
            mrb_stack['source'] = DAP::Type::Source.new(var['value'].split(' ')[-1].gsub('"', '')).to_h
          end
          mrb_stack['line'] = var['value'].to_i if var['name'] == 'line'
          @last_ciidx = var['value'].to_i if var['name'] == 'ciidx'
        end
        if mrb_stack['source'].nil? || mrb_stack['line'].nil?
          return message
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
    message = @debugger.wait_message
    @logger.puts "\t<----------"
    @logger.puts message
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
      when 'setBreakpoints', 'setFunctionBreakpoints'
        message = breakpoints_c2r(message) unless @mruby_code_fetch_bp.nil?
      when 'stackTrace'
        message = add_mruby_stack(message) unless @mruby_code_fetch_bp.nil?
      when 'stepIn', 'next'
        message = restore_response(message) unless @mruby_code_fetch_bp.nil?
      end
    end
    @request_buffer.delete_if { |request| request['seq'] == message['request_seq'] }
    @logger.puts '<=========='
    @logger.puts message
    send_message(@client_out, message)
  end

  def terminate(message)
    send_message(@client_out, message)
    exit
  end

  def run
    loop do
      readable, _writable = IO.select(@readings)
      readable.each do |ri|
        if ri == @acceptor
          @logger.puts 'accept'
          @client_in = @acceptor.accept
          @client_out = @client_in
          @readings.push @client_in
        end
        if ri == @client_in
          process_client
        elsif ri == @debugger.io
          process_adapter # unless @debugger.io.eof?
        end
      end
    end
  end
end

def __main__(argv)
  config = DapProxy::DEFAULT_CONFIG
  argv.each_with_index do |arg, i|
    case arg
    when '-l', '--lldb_vscode_path'
      config[:adapter] = argv[i + 1] unless argv[i + 1].nil?
    when '--adapter_port'
      config[:adapter_port] = argv[i + 1] unless argv[i + 1].nil?
    when '--adapter_type'
      config[:adapter_type] = argv[i + 1] unless argv[i + 1].nil?
    when '-p', '--port'
      config[:client_port] = argv[i + 1].to_i unless argv[i + 1].nil?
    when '--mrb_debug_path'
      config[:mrb_debug_path] = argv[i + 1] unless argv[i + 1].nil?
    when '--mrb_debug_line'
      config[:mrb_debug_line] = argv[i + 1].to_i unless argv[i + 1].nil?
    when '--logfile'
      config[:logfile] = argv[i + 1] unless argv[i + 1].nil?
    end
  end
  DapProxy.new(config).run
end
