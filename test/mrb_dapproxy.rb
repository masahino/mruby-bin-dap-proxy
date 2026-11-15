##
## DapProxy Test
##
class DapProxy
  attr_accessor :request_buffer, :mruby_code_fetch_source, :mruby_code_fetch_line
end

assert('initialize') do
  proxy = build_mock_dap_proxy
  assert_equal 0, proxy.mruby_code_fetch_line
end

assert('restore_response') do
  proxy = build_mock_dap_proxy
  proxy.request_buffer = [{ 'seq' => 1, 'command' => 'next' }, { 'seq' => 3, 'command' => 'stepIn' },
                          { 'command' => 'next', 'arguments' => { 'threadId' => 38 },
                            'type' => 'request', 'seq' => 152 }]
  ret = proxy.restore_response({ 'body' => { 'allThreadsContinued' => true },
                                 'command' => 'continue', 'request_seq' => 152, 'seq' => 0,
                                 'success' => true, 'type' => 'response' })
  assert_equal 'next', ret['command']
end

assert('add_mruby_stack levels == 1') do
  proxy = build_mock_dap_proxy
  proxy.request_buffer = [{ 'seq' => 1, 'command' => 'next' }, { 'seq' => 3, 'command' => 'stepIn' },
                          { 'command' => 'next', 'arguments' => { 'threadId' => 38 },
                            'type' => 'request', 'seq' => 152 },
                          { 'command' => 'stackTrace',
                            'arguments' => { 'threadId' => 871, 'startFrame' => 0, 'levels' => 1 },
                            'type' => 'request', 'seq' => 9 }]
  ret = proxy.add_mruby_stack({ 'body' => {
                                  'stackFrames' => [{ 'column' => 22, 'id' => 288, 'line' => 100,
                                                      'name' => 'mrb_debug_breakpoint_function',
                                                      'source' => { 'name' => 'mruby_gdb.c',
                                                       'path' => '/home/mruby-gdb/src/mruby_gdb.c' } }],
                                   'totalFrames' => 11 },
                                'command' => 'stackTrace', 'request_seq' => 9, 'seq' => 0,
                                'success' => true, 'type' => 'response' })
  assert_kind_of Hash, ret
  assert_equal 1, ret['body']['stackFrames'].size
  assert_equal '/foo/bar/baz', ret['body']['stackFrames'][0]['source']['path']
  assert_equal 12, ret['body']['totalFrames']
end

class PollingDAPClient
  attr_accessor :message, :on_pending, :on_timeout

  def poll_message
    @message
  end
end

assert('process_adapter does nothing while a message is still arriving') do
  proxy = build_mock_dap_proxy
  client = PollingDAPClient.new
  proxy.instance_variable_set(:@debugger, client)
  reader, writer = IO.pipe
  proxy.instance_variable_set(:@client_out, writer)

  proxy.process_adapter

  assert_nil IO.select([reader], nil, nil, 0)
ensure
  reader.close unless reader.nil? || reader.closed?
  writer.close unless writer.nil? || writer.closed?
end

assert('handle_adapter_message forwards an event to the client') do
  proxy = build_mock_dap_proxy
  proxy.instance_variable_set(:@debugger, PollingDAPClient.new)
  reader, writer = IO.pipe
  proxy.instance_variable_set(:@client_out, writer)
  event = { 'seq' => 5, 'type' => 'event', 'event' => 'output', 'body' => { 'output' => 'hi' } }

  proxy.handle_adapter_message(event)

  _headers, forwarded = proxy.recv_message(reader)
  assert_equal event, forwarded
ensure
  reader.close unless reader.nil? || reader.closed?
  writer.close unless writer.nil? || writer.closed?
end

assert('process_adapter forwards the message that has arrived') do
  proxy = build_mock_dap_proxy
  client = PollingDAPClient.new
  client.message = { 'seq' => 6, 'type' => 'event', 'event' => 'continued', 'body' => {} }
  proxy.instance_variable_set(:@debugger, client)
  reader, writer = IO.pipe
  proxy.instance_variable_set(:@client_out, writer)

  proxy.process_adapter

  _headers, forwarded = proxy.recv_message(reader)
  assert_equal 'continued', forwarded['event']
ensure
  reader.close unless reader.nil? || reader.closed?
  writer.close unless writer.nil? || writer.closed?
end

class DapProxyForDisconnectTest < DapProxy
  attr_reader :shutdown_count

  def shutdown_adapter
    @shutdown_count = (@shutdown_count || 0) + 1
  end
end

def build_disconnect_test_proxy(writer)
  proxy = DapProxyForDisconnectTest.allocate
  proxy.instance_variable_set(:@debugger, PollingDAPClient.new)
  proxy.instance_variable_set(:@debugger_config, DapProxy::DEFAULT_DEBUGGER_CONFIG.dup)
  proxy.instance_variable_set(:@logger, $stderr)
  proxy.instance_variable_set(:@mruby_code_fetch_bp, nil)
  proxy.instance_variable_set(:@request_buffer, [])
  proxy.instance_variable_set(:@client_out, writer)
  proxy
end

assert('disconnect_response? recognizes the response to a disconnect request') do
  proxy = build_mock_dap_proxy

  assert_true proxy.disconnect_response?({ 'type' => 'response', 'command' => 'disconnect', 'success' => true })
  assert_false proxy.disconnect_response?({ 'type' => 'response', 'command' => 'next' })
  assert_false proxy.disconnect_response?({ 'type' => 'event', 'event' => 'terminated' })
  assert_false proxy.disconnect_response?({ 'type' => 'request', 'command' => 'disconnect' })
end

assert('handle_adapter_message forwards the disconnect response and then shuts the adapter down') do
  reader, writer = IO.pipe
  proxy = build_disconnect_test_proxy(writer)
  response = { 'seq' => 9, 'type' => 'response', 'request_seq' => 4, 'command' => 'disconnect', 'success' => true }

  proxy.handle_adapter_message(response)

  _headers, forwarded = proxy.recv_message(reader)
  assert_equal response, forwarded
  assert_equal 1, proxy.shutdown_count
ensure
  reader.close unless reader.nil? || reader.closed?
  writer.close unless writer.nil? || writer.closed?
end

assert('handle_adapter_message keeps the adapter for other responses') do
  reader, writer = IO.pipe
  proxy = build_disconnect_test_proxy(writer)

  proxy.handle_adapter_message({ 'seq' => 9, 'type' => 'response', 'request_seq' => 4, 'command' => 'next', 'success' => true })

  assert_nil proxy.shutdown_count
ensure
  reader.close unless reader.nil? || reader.closed?
  writer.close unless writer.nil? || writer.closed?
end

assert('the proxy can exit: Kernel#exit comes from the mruby-exit gem') do
  assert_true Object.new.respond_to?(:exit, true)
end
