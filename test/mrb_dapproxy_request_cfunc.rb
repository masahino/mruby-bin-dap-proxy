# Step from a Ruby line into the C function it calls (mrblib/mrb_dapproxy_cfunc.rb)

# Answers the requests of the proxy from a table and records them.
class ScriptedDAPClient
  attr_reader :requests

  def initialize(responses)
    @responses = responses # command => response (or an Array of them, used one after the other)
    @requests = []
  end

  def send_request(command, arguments = {})
    @requests.push [command, arguments]
    yield response_for(command)
  end

  def evaluate(arguments)
    @requests.push ['evaluate', arguments]
    yield response_for('evaluate')
  end

  def commands
    @requests.map { |request| request[0] }
  end

  def arguments_of(command)
    found = @requests.select { |request| request[0] == command }
    found.map { |request| request[1] }
  end

  private

  def response_for(command)
    response = @responses[command]
    response = response.shift if response.is_a?(Array)
    response || { 'success' => true }
  end
end

def cfunc_ok(body = nil)
  response = { 'success' => true }
  response['body'] = body unless body.nil?
  response
end

def cfunc_summary(text)
  escaped = ''
  text.each_char do |c|
    escaped << '\\' if c == '\\' || c == '"'
    escaped << c
  end
  "0x000000011802b704 \"#{escaped}\""
end

def cfunc_frame_response(frame)
  cfunc_ok({ 'stackFrames' => [frame], 'totalFrames' => 1 })
end

def cfunc_stopped(reason = 'breakpoint')
  { 'type' => 'event', 'event' => 'stopped', 'body' => { 'reason' => reason, 'threadId' => 1 } }
end

def build_cfunc_proxy(responses, state = nil)
  proxy = build_mock_dap_proxy
  proxy.instance_variable_set(:@debugger, ScriptedDAPClient.new(responses))
  proxy.instance_variable_set(:@last_stack, { 'id' => 524287, 'source' => { 'path' => '/work/a.rb' } })
  proxy.instance_variable_set(:@cfunc_step, state)
  proxy
end

TARGET_SUMMARY = cfunc_summary('["String#length","0x100003f10"]')

assert('mruby_step_in arms mruby-debug and sets one one-shot breakpoint on both marker functions') do
  proxy = build_cfunc_proxy({})
  message = proxy.mruby_step_in({ 'seq' => 5, 'command' => 'stepIn', 'arguments' => { 'threadId' => 1 } })

  evaluated = proxy.instance_variable_get(:@debugger).arguments_of('evaluate')
  assert_include evaluated[0]['expression'], 'mrb_debug_arm_cfunc_step(mrb)'
  assert_include evaluated[1]['expression'], "breakpoint set -r '^mrb_debug_(breakpoint|cfunc)_function$' -o true"
  assert_equal 'continue', message['command']
  assert_equal :waiting, proxy.instance_variable_get(:@cfunc_step)
end

assert('mruby_step_in falls back to the old breakpoint when mruby-debug cannot be armed') do
  proxy = build_cfunc_proxy({ 'evaluate' => [{ 'success' => false }, { 'success' => true }] })
  message = proxy.mruby_step_in({ 'seq' => 5, 'command' => 'stepIn', 'arguments' => { 'threadId' => 1 } })

  evaluated = proxy.instance_variable_get(:@debugger).arguments_of('evaluate')
  assert_include evaluated[1]['expression'], 'tbreak mrb_debug_breakpoint_function'
  assert_equal 'continue', message['command']
  assert_nil proxy.instance_variable_get(:@cfunc_step)
end

assert('cfunc_step_stopped leaves an ordinary stop at the next Ruby line to the client') do
  frame = { 'id' => 524287, 'name' => 'mrb_debug_breakpoint_function' }
  proxy = build_cfunc_proxy({ 'stackTrace' => cfunc_frame_response(frame) }, :waiting)

  assert_false proxy.cfunc_step_stopped(cfunc_stopped)
  assert_nil proxy.instance_variable_get(:@cfunc_step)
  assert_equal ['stackTrace'], proxy.instance_variable_get(:@debugger).commands
end

assert('cfunc_step_stopped runs on from mrb_debug_cfunc_function to the C function') do
  frame = { 'id' => 7, 'name' => 'mrb_debug_cfunc_function' }
  responses = { 'stackTrace' => cfunc_frame_response(frame),
                'evaluate' => cfunc_ok({ 'result' => TARGET_SUMMARY }) }
  proxy = build_cfunc_proxy(responses, :waiting)

  assert_true proxy.cfunc_step_stopped(cfunc_stopped)

  client = proxy.instance_variable_get(:@debugger)
  assert_equal %w[stackTrace evaluate setInstructionBreakpoints continue], client.commands
  assert_equal 7, client.arguments_of('evaluate')[0]['frameId']
  assert_equal [{ 'instructionReference' => '0x100003f10' }],
               client.arguments_of('setInstructionBreakpoints')[0]['breakpoints']
  assert_equal({ 'threadId' => 1 }, client.arguments_of('continue')[0])
  assert_equal :running, proxy.instance_variable_get(:@cfunc_step)
end

assert('cfunc_step_stopped forwards the stop when the target cannot be read') do
  frame = { 'id' => 7, 'name' => 'mrb_debug_cfunc_function' }
  proxy = build_cfunc_proxy({ 'stackTrace' => cfunc_frame_response(frame),
                              'evaluate' => cfunc_ok({ 'result' => cfunc_summary('[]') }) }, :waiting)

  assert_false proxy.cfunc_step_stopped(cfunc_stopped)
  assert_nil proxy.instance_variable_get(:@cfunc_step)
  assert_false proxy.instance_variable_get(:@debugger).commands.include?('continue')
end

assert('cfunc_step_stopped steps past the first line of a C function that has source') do
  frame = { 'id' => 9, 'name' => 'mrb_str_size', 'instructionPointerReference' => '0x0000000100003f10',
            'source' => { 'path' => '/mruby/src/string.c' }, 'line' => 1200 }
  proxy = build_cfunc_proxy({ 'stackTrace' => cfunc_frame_response(frame) }, :running)
  proxy.instance_variable_set(:@cfunc_target, ['String#length', '0x100003f10'])

  assert_true proxy.cfunc_step_stopped(cfunc_stopped)

  client = proxy.instance_variable_get(:@debugger)
  assert_equal %w[stackTrace setInstructionBreakpoints next], client.commands
  assert_equal [], client.arguments_of('setInstructionBreakpoints')[0]['breakpoints']
  assert_equal :entering, proxy.instance_variable_get(:@cfunc_step)
end

assert('cfunc_step_stopped accepts the reason lldb-dap gives an instruction breakpoint') do
  frame = { 'id' => 9, 'name' => 'mrb_str_size', 'instructionPointerReference' => '0x0000000100003f10',
            'source' => { 'path' => '/mruby/src/string.c' }, 'line' => 1200 }
  proxy = build_cfunc_proxy({ 'stackTrace' => cfunc_frame_response(frame) }, :running)
  proxy.instance_variable_set(:@cfunc_target, ['String#length', '0x100003f10'])

  assert_true proxy.cfunc_step_stopped(cfunc_stopped('instruction breakpoint'))

  assert_equal :entering, proxy.instance_variable_get(:@cfunc_step)
  assert_true proxy.instance_variable_get(:@in_cfunc)
end

assert('cfunc_step_stopped forwards the stop in a C function that has no source') do
  frame = { 'id' => 9, 'name' => 'mrb_str_size', 'instructionPointerReference' => '0x0000000100003f10' }
  proxy = build_cfunc_proxy({ 'stackTrace' => cfunc_frame_response(frame) }, :running)
  proxy.instance_variable_set(:@cfunc_target, ['String#length', '0x100003f10'])

  assert_false proxy.cfunc_step_stopped(cfunc_stopped)

  client = proxy.instance_variable_get(:@debugger)
  assert_equal %w[stackTrace setInstructionBreakpoints], client.commands
  assert_nil proxy.instance_variable_get(:@cfunc_step)
end

assert('cfunc_step_stopped forwards a stop that is not at the C function') do
  frame = { 'id' => 9, 'name' => 'other', 'instructionPointerReference' => '0x0000000100009999',
            'source' => { 'path' => '/mruby/src/string.c' } }
  proxy = build_cfunc_proxy({ 'stackTrace' => cfunc_frame_response(frame) }, :running)
  proxy.instance_variable_set(:@cfunc_target, ['String#length', '0x100003f10'])

  assert_false proxy.cfunc_step_stopped(cfunc_stopped)
  assert_false proxy.instance_variable_get(:@debugger).commands.include?('next')
end

assert('cfunc_step_stopped forwards the stop of the step over the first line') do
  proxy = build_cfunc_proxy({}, :entering)

  assert_false proxy.cfunc_step_stopped(cfunc_stopped('step'))
  assert_nil proxy.instance_variable_get(:@cfunc_step)
  assert_equal [], proxy.instance_variable_get(:@debugger).commands
end

assert('cfunc_step_stopped does nothing when no step into C is under way') do
  proxy = build_cfunc_proxy({}, nil)

  assert_false proxy.cfunc_step_stopped(cfunc_stopped)
  assert_equal [], proxy.instance_variable_get(:@debugger).commands
end

assert('handle_adapter_message does not forward the stop it consumed') do
  reader, writer = IO.pipe
  frame = { 'id' => 7, 'name' => 'mrb_debug_cfunc_function' }
  proxy = build_cfunc_proxy({ 'stackTrace' => cfunc_frame_response(frame),
                              'evaluate' => cfunc_ok({ 'result' => TARGET_SUMMARY }) }, :waiting)
  proxy.instance_variable_set(:@client_out, writer)

  proxy.handle_adapter_message(cfunc_stopped)

  assert_nil IO.select([reader], nil, nil, 0)
ensure
  reader.close unless reader.nil? || reader.closed?
  writer.close unless writer.nil? || writer.closed?
end

assert('stop_at_mruby_code? is false for a frame whose source has no path') do
  proxy = build_mock_dap_proxy
  proxy.instance_variable_set(:@last_stack, { 'id' => 3, 'source' => { 'sourceReference' => 4 } })

  assert_false proxy.stop_at_mruby_code?
end

##
## The C mode: a step that leaves a C function ends in the VM (src/vm.c); the proxy runs on to the
## next Ruby line instead of showing the VM.
##

def cfunc_vm_frame(name = 'send_method')
  { 'id' => 524288, 'name' => name, 'source' => { 'name' => 'vm.c', 'path' => 'src/vm.c' }, 'line' => 1760 }
end

def build_cfunc_mode_proxy(responses, in_cfunc = true)
  proxy = build_cfunc_proxy(responses, nil)
  proxy.instance_variable_set(:@in_cfunc, in_cfunc)
  proxy
end

assert('the C mode starts when the step arrives in the C function') do
  frame = { 'id' => 9, 'name' => 'mrb_str_size', 'instructionPointerReference' => '0x0000000100003f10' }
  proxy = build_cfunc_proxy({ 'stackTrace' => cfunc_frame_response(frame) }, :running)
  proxy.instance_variable_set(:@cfunc_target, ['String#length', '0x100003f10'])

  proxy.cfunc_step_stopped(cfunc_stopped)

  assert_true proxy.instance_variable_get(:@in_cfunc)
end

assert('the C mode does not start at a stop that is not at the C function') do
  frame = { 'id' => 9, 'name' => 'other', 'instructionPointerReference' => '0x0000000100009999' }
  proxy = build_cfunc_proxy({ 'stackTrace' => cfunc_frame_response(frame) }, :running)
  proxy.instance_variable_set(:@cfunc_target, ['String#length', '0x100003f10'])

  proxy.cfunc_step_stopped(cfunc_stopped)

  assert_false proxy.instance_variable_get(:@in_cfunc)
end

assert('a step that ends in src/vm.c runs on to the next Ruby line in the C mode') do
  proxy = build_cfunc_mode_proxy({ 'stackTrace' => cfunc_frame_response(cfunc_vm_frame) })

  assert_true proxy.cfunc_step_stopped(cfunc_stopped('step'))

  client = proxy.instance_variable_get(:@debugger)
  assert_equal %w[stackTrace evaluate continue], client.commands
  assert_include client.arguments_of('evaluate')[0]['expression'], 'tbreak mrb_debug_breakpoint_function'
  assert_equal({ 'threadId' => 1 }, client.arguments_of('continue')[0])
  assert_equal :returning, proxy.instance_variable_get(:@cfunc_step)
  assert_true proxy.instance_variable_get(:@in_cfunc)
end

assert('the stop at the next Ruby line is forwarded and ends the C mode') do
  frame = { 'id' => 524287, 'name' => 'mrb_debug_breakpoint_function' }
  proxy = build_cfunc_mode_proxy({ 'stackTrace' => cfunc_frame_response(frame) })
  proxy.instance_variable_set(:@cfunc_step, :returning)

  assert_false proxy.cfunc_step_stopped(cfunc_stopped)

  assert_nil proxy.instance_variable_get(:@cfunc_step)
  assert_false proxy.instance_variable_get(:@in_cfunc)
  assert_equal [], proxy.instance_variable_get(:@debugger).commands
end

assert('a step that stays in a C function is forwarded in the C mode') do
  frame = { 'id' => 9, 'name' => 'mrb_str_size', 'source' => { 'path' => '/mruby/src/string.c' }, 'line' => 1201 }
  proxy = build_cfunc_mode_proxy({ 'stackTrace' => cfunc_frame_response(frame) })

  assert_false proxy.cfunc_step_stopped(cfunc_stopped('step'))

  assert_equal ['stackTrace'], proxy.instance_variable_get(:@debugger).commands
  assert_true proxy.instance_variable_get(:@in_cfunc)
end

assert('a breakpoint in src/vm.c is forwarded in the C mode') do
  proxy = build_cfunc_mode_proxy({ 'stackTrace' => cfunc_frame_response(cfunc_vm_frame('mrb_vm_exec')) })

  assert_false proxy.cfunc_step_stopped(cfunc_stopped('breakpoint'))

  assert_equal ['stackTrace'], proxy.instance_variable_get(:@debugger).commands
end

assert('a stop in src/vm.c is forwarded outside of the C mode') do
  proxy = build_cfunc_mode_proxy({}, false)

  assert_false proxy.cfunc_step_stopped(cfunc_stopped('step'))

  assert_equal [], proxy.instance_variable_get(:@debugger).commands
end

assert('a Ruby line stop ends the C mode') do
  frame = { 'id' => 524287, 'name' => 'mrb_debug_breakpoint_function' }
  proxy = build_cfunc_mode_proxy({ 'stackTrace' => cfunc_frame_response(frame) })

  assert_false proxy.cfunc_step_stopped(cfunc_stopped('breakpoint'))

  assert_false proxy.instance_variable_get(:@in_cfunc)
end

assert('the C mode goes on when the one-shot breakpoint cannot be set') do
  proxy = build_cfunc_mode_proxy({ 'stackTrace' => cfunc_frame_response(cfunc_vm_frame),
                                   'evaluate' => { 'success' => false } })

  assert_false proxy.cfunc_step_stopped(cfunc_stopped('step'))

  assert_false proxy.instance_variable_get(:@debugger).commands.include?('continue')
  assert_nil proxy.instance_variable_get(:@cfunc_step)
end

assert('a Ruby step in ends the C mode') do
  proxy = build_cfunc_mode_proxy({})
  proxy.mruby_step_in({ 'seq' => 5, 'command' => 'stepIn', 'arguments' => { 'threadId' => 1 } })

  assert_false proxy.instance_variable_get(:@in_cfunc)
end

assert('the process ending ends the C mode') do
  reader, writer = IO.pipe
  proxy = build_cfunc_mode_proxy({})
  proxy.instance_variable_set(:@client_out, writer)

  proxy.handle_adapter_message({ 'type' => 'event', 'event' => 'exited', 'body' => { 'exitCode' => 0 } })

  assert_false proxy.instance_variable_get(:@in_cfunc)
ensure
  reader.close unless reader.nil? || reader.closed?
  writer.close unless writer.nil? || writer.closed?
end
