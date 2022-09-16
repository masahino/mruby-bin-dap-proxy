##
## DapProxy Test
##
class DapProxy
  attr_accessor :request_buffer, :mruby_code_fetch_source, :mruby_code_fetch_line
end

module DAP
  class Client
    def variables(_args, &block)
      res = { 'seq' => 0, 'type' => 'response', 'request_seq' => 12, 'success' => true, 'command' => 'variables',
        'body' => { 'variables' => [{ 'name' => 'filename', 'value' => '"/foo/bar/baz"', 'type' => 'Strings', 'variablesReference' => 0 }, { 'name' => 'line', 'value' => '11', 'type' => 'Integer', 'variablesReference' => 1 },
            { 'name' => 'prev_ciidx', 'value' => '10', 'type' => 'Integer', 'variablesReference' => 2 } ] } }
      if block_given?
        block.call(res)
      else
        res
      end
    end

    def scopes(_args, &block)
      res = { 'seq' => 0, 'type' => 'response', 'request_seq' => 12, 'success' => true, 'command' => 'scopes' }
      if block_given?
        block.call(res)
      else
        res
      end
    end
  end
end

assert('initialize') do
  proxy = DapProxy.new
  assert_equal 0, proxy.mruby_code_fetch_line
end

assert('restore_response') do
  proxy = DapProxy.new({ adapter: '' })
  proxy.request_buffer = [{ 'seq' => 1, 'command' => 'next' }, { 'seq' => 3, 'command' => 'stepIn' },
                          { 'command' => 'next', 'arguments' => { 'threadId' => 38 },
                            'type' => 'request', 'seq' => 152 }]
  ret = proxy.restore_response({ 'body' => { 'allThreadsContinued' => true },
                                 'command' => 'continue', 'request_seq' => 152, 'seq' => 0,
                                 'success' => true, 'type' => 'response' })
  assert_equal 'next', ret['command']
end

assert('add_mruby_stack levels == 1') do
  proxy = DapProxy.new({ adapter: '' })
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
