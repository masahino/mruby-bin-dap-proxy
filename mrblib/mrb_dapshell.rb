class DapShell < DapProxy
  DAPSHELL_COMMAND_MAP = [
    ['attach', 'a', :dapshell_attach, 'Attach to process.'],
    ['break', 'b', :dapshell_breakpoint, 'Set a breakpoint.'],
    ['continue', 'c', :dapshell_continue, ''],
    ['help', 'h', :dapshell_help, ''],
    ['launch', 'l', :dapshell_launch, ''],
    ['print', 'p', :dapshell_none, ''],
    ['quit', 'q', :dapshell_quit, ''],
    ['run', 'r', :dapshell_run, ''],
    ['bt', 'bt', :dapshell_stack_trace, ''],
    ['step', 's', :dapshell_step_in, ''],
    ['next', 'n', :dapshell_next, '']
  ].freeze

  def initialize(config)
    tmpdir = ENV['TMPDIR'] || ENV['TMP'] || ENV['TEMP'] || ENV['USERPROFILE'] || '/tmp'
    config[:logfile] = "#{tmpdir}/mruby_dap_proxy_#{$PID}.log"
    setup_logfile(config)
    # setup_debugger(config)

    adapter_args = {}
    unless config[:adapter_port].nil?
      adapter_args = { 'args' => ["--port #{config[:adapter_port]}"], 'port' => config[:adapter_port] }
    end
    @debugger = DAP::Client.new(config[:adapter], adapter_args)
    @debugger.start_debug_adapter({ 'adapterID' => config[:adapter_type] })
    @debugger_config = DEFAULT_DEBUGGER_CONFIG

    @readings = [@debugger.io, $stdin]
    $stderr.puts @readings
    setup_mruby_breakpoint(config)
    @dap_config = config
    @last_filename = ''
    @last_line = ''
    @last_ciidx = 999
    @last_stack = nil
    @request_buffer = []

    # 
    @thread_id = 0
    @process = { name: '', pid: 0 }
  end

  def dapshell_launch(program)
    args = program[1..-1]
    @debugger.launch({ 'name' => 'mruby-dap', 'type' => @dap_config[:adapter_type], 'program' => program[0],
                       'args' => args, 'cwd' => File.dirname(__FILE__) })
  end

  def dapshell_attach(args)
    program = args[0]
    params = { 'name' => 'mruby-dap', 'type' => @dap_config[:adapter_type], 'program' => program }
    params['pid'] = args[1].to_i unless args[1].nil?
    @debugger.attach(params)
  end

  def dapshell_breakpoint(args)
    bp_arg = args[0]
    if bp_arg.nil?
      puts '??'
      return
    end

    if bp_arg.index(':').nil?
      bp = DAP::Type::FunctionBreakpoint.new(bp_arg)
      @debugger.setFunctionBreakpoints({ 'breakpoints' => [bp] })
    else
      source = DAP::Type::Source.new(bp_arg.split(':')[0])
      bp = DAP::Type::SourceBreakpoint.new(bp_arg.split(':')[1].to_i)
      @debugger.setBreakpoints({ 'source' => source, 'breakpoints' => [bp] })
    end
  end

  def dapshell_breakpoint_locations(_args)
    @debugger.breakpointLocations
  end

  def dapshell_step_in(_args)
    @debugger.stepIn({ 'threadId' => @thread_id })
  end

  def dapshell_next(_args)
    @debugger.next({ 'threadId' => @thread_id })
  end

  def dapshell_continue(_args)
    @debugger.continue({ 'threadId' => @thread_id })
  end

  def dapshell_stack_trace(_args)
    @debugger.stackTrace({ 'threadId' => @thread_id })
  end

  def dapshell_quit(_args)
    @debugger.disconnect
    exit
  end

  def dapshell_run(_args)
    @debugger.configurationDone
  end

  def dapshell_none(_args)
    puts 'not yet implemented'
  end

  def dapshell_help(_args)
    help_list = []
    maxlen = DAPSHELL_COMMAND_MAP.map { |c| c[0] }.max_by(&:length).length + 1
    DAPSHELL_COMMAND_MAP.each do |command|
      help_list.push "#{command[0].ljust(maxlen)} -- #{command[3]}"
      help_list.push "#{command[1].ljust(maxlen)} -- #{command[3]}"
    end
    help_list.uniq!
    help_list.sort!
    help_list.each do |h|
      puts h
    end
    dapshell_prompt
  end

  def dapshell_method(input)
    DAPSHELL_COMMAND_MAP.each do |command|
      return command[2] if command[0..1].include?(input)
    end
    nil
  end

  def dapshell_prompt
      print '> '
  end

  def process_command
    line = gets.chomp
    if line == ''
      dapshell_prompt
      return 
    end

    command = line.split[0]
    method = dapshell_method(command)
    if !method.nil?
      send(method, line.split[1..])
    else
      if @debugger.respond_to?(command)
        seq = @debugger.send('send_request', command)
      else
        puts 'unknown command'
        dapshell_prompt
        seq = nil
      end
    end

    seq
  end

  def process_event(event, body)
    case event
    when 'stopped'
      @thread_id = body['threadId'].to_i
      puts
      puts '[stopped]'
      puts body
    when 'process'
      @process[:name] = body['name']
      @process[:pid] = body['systemProcessId'] unless body['systemProcessId'].nil?
      puts
      puts '[process]'
      puts JSON.pretty_generate(body)
    when 'initialized'
      #      @debugger.threads do |res|
      #        @thread_id = res['body']['threads'][0]['id'] if res['body']['threads'].size > 0
      #      end
      puts
      puts '[initialized]'
      puts JSON.pretty_generate(body)
    else
      puts
      puts event
      puts body
    end
  end

  def process_message
    res = @debugger.wait_message

    case res['type']
    when 'response'
      # puts
      puts JSON.pretty_generate(res)
      puts res['message'] unless res['message'].nil?
    when 'event'
      process_event(res['event'], res['body'])
    else
      puts
      puts 'unknown message'
    end
  end

  def run
    dapshell_prompt
    loop do
      readable, _writable = IO.select(@readings)
      readable.each do |ri|
        if ri == $stdin
          process_command
          # print '> '
        elsif ri == @debugger.io
          unless @debugger.io.eof?
            process_message
            dapshell_prompt
          end
        end
      end
    end
    exit
  end
end
