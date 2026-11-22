# DAP Proxy: step from a Ruby line into the C function it calls
#
# mruby_step_in arms mruby-debug (mrb_debug_arm_cfunc_step) and sets a one-shot breakpoint on both
# marker functions. The debuggee then stops at
#   mrb_debug_breakpoint_function  the next Ruby line: an ordinary stop, forwarded to the client
#   mrb_debug_cfunc_function       the line calls a C function: handled here, not forwarded
# In the second case the proxy reads the address of that C function from mruby-debug, puts an
# instruction breakpoint there, continues, and forwards the stop in the C function. When the C
# function has source, one `next` moves past its first line.
#
# From then on @in_cfunc is true (the C mode). Leaving a C function by next, step or finish lands in
# the VM (src/vm.c: send_method, mrb_f_send, mrb_vm_exec ...), which says nothing about the Ruby
# program. In the C mode such a stop is not forwarded: the proxy runs on to the next Ruby line (the
# one-shot breakpoint on the marker, as the step in Ruby does). That stop ends the C mode. The same
# happens when a C function calls Ruby code (mrb_yield, mrb_funcall): the stop is the first line of
# the Ruby code. A breakpoint set in src/vm.c itself still stops there (only a step is passed over).
#
# @cfunc_step: nil (nothing under way) -> :waiting (for a marker) -> :running (to the C function)
# -> :entering (the step over its first line); :returning (from the VM to the next Ruby line). The
# state is set before the request that causes the next stop: events that arrive during a request are
# handled when it returns.
class DapProxy
  # Called for every stopped event. Returns true when the event was consumed.
  def cfunc_step_stopped(message)
    return cfunc_mode_stopped(message) if @cfunc_step.nil?

    state = @cfunc_step
    @cfunc_step = nil
    if state == :returning # the next Ruby line (or any other stop): the C mode is over
      @in_cfunc = false
      return false
    end
    return false if state == :entering # the step over the first line: the stop the user waits for

    thread_id = message['body']['threadId']
    top = cfunc_top_frame(thread_id)
    return false if top.nil?

    if state == :waiting
      cfunc_step_to_function(top, thread_id)
    else
      cfunc_step_arrived(message, top, thread_id)
    end
  end

  def cfunc_step_arm
    res = mruby_evaluate('(int)(mrb_debug_arm_cfunc_step(mrb), 0)')
    return false if res.nil? || !res['success']

    true
  end

  # At mrb_debug_cfunc_function: run on to the C function the line calls.
  def cfunc_step_to_function(top, thread_id)
    return false unless top['name'] == MRUBY_CFUNC_FUNC

    @cfunc_target = cfunc_read_target(top)
    return false if @cfunc_target.nil?

    return false unless cfunc_request('setInstructionBreakpoints',
                                      { 'breakpoints' => [{ 'instructionReference' => @cfunc_target[1] }] })

    @cfunc_step = :running
    return true if cfunc_request('continue', { 'threadId' => thread_id })

    @cfunc_step = nil
    false
  end

  # The stop after the instruction breakpoint was set.
  def cfunc_step_arrived(message, top, thread_id)
    cfunc_request('setInstructionBreakpoints', { 'breakpoints' => [] })
    return false unless cfunc_at_target?(message, top)

    @in_cfunc = true
    source = top['source']
    return false if source.nil? || source['path'].nil? # no source: the client shows where it stopped

    @cfunc_step = :entering
    return true if cfunc_request('next', { 'threadId' => thread_id })

    @cfunc_step = nil
    false
  end

  # A stop while no step into C is under way. In the C mode a step that ended in the VM is passed over.
  def cfunc_mode_stopped(message)
    return false unless @in_cfunc

    thread_id = message['body']['threadId']
    top = cfunc_top_frame(thread_id)
    return false if top.nil?

    if top['name'] == MRUBY_CODE_FETCH_FUNC # a Ruby line: back in Ruby
      @in_cfunc = false
      return false
    end
    return false unless message['body']['reason'] == 'step' && cfunc_vm_frame?(top)

    cfunc_return_to_ruby(thread_id)
  end

  def cfunc_vm_frame?(frame)
    source = frame['source']
    path = source.nil? ? nil : source['path']
    return false if path.nil?

    path == 'src/vm.c' || path[-9, 9] == '/src/vm.c'
  end

  # Run on to the next Ruby line.
  def cfunc_return_to_ruby(thread_id)
    ok = false
    @debugger.evaluate({ 'expression' => "#{@debugger_config[:expression_prefix]}tbreak #{MRUBY_CODE_FETCH_FUNC}",
                         'context' => 'repl' }) do |res|
      @logger.puts res
      ok = res['success'] == false ? false : true
    end
    return false unless ok

    @cfunc_step = :returning
    return true if cfunc_request('continue', { 'threadId' => thread_id })

    @cfunc_step = nil
    false
  end

  def cfunc_at_target?(message, top)
    # lldb-dap reports an instruction breakpoint as 'instruction breakpoint'
    return false unless ['breakpoint', 'instruction breakpoint'].include?(message['body']['reason'])
    return false if top['name'] == MRUBY_CODE_FETCH_FUNC || top['name'] == MRUBY_CFUNC_FUNC

    reference = top['instructionPointerReference']
    return true if reference.nil? || @cfunc_target.nil?

    cfunc_address(reference) == cfunc_address(@cfunc_target[1])
  end

  def cfunc_address(text)
    text.to_s.sub(/\A0x/, '').to_i(16)
  end

  # [label, "0xADDRESS"] of the C function mruby-debug found, or nil
  def cfunc_read_target(top)
    res = mruby_evaluate('mrb_debug_get_cfunc_target(mrb)', top['id'])
    return nil if res.nil? || !res['success']

    target = parse_mruby_expr(res['body']['result'])
    return nil unless target.is_a?(Array) && target.size == 2

    target
  end

  def cfunc_top_frame(thread_id)
    frame = nil
    @debugger.send_request('stackTrace', { 'threadId' => thread_id, 'startFrame' => 0, 'levels' => 1 }) do |res|
      @logger.puts res
      frames = res['success'] ? res['body']['stackFrames'] : nil
      frame = frames[0] unless frames.nil?
    end
    frame
  end

  def cfunc_request(command, arguments)
    ok = false
    @debugger.send_request(command, arguments) do |res|
      @logger.puts res
      ok = res['success'] ? true : false
    end
    ok
  end
end
