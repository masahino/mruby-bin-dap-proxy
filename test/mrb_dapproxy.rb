##
## DapProxy Test
##
class DapProxy
  attr_accessor :request_buffer, :mruby_code_fetch_source
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

assert('mruby_parse_locals') do
  proxy = DapProxy.new('')
  res = {
    'body' => {
      'result' => "(lldb) expr mrb_gdb_get_locals(mrb)\n(char *) $22 = 0x00000000008188e8 \"locals=[{name=\"&\",value=\"nil\",type=\"NilClass\"},{name=\"ev\",value=\"#<Termbox::Event:0x328a9de0>\",type=\"Termbox::Event\"},{name=\"key_str\",value=\"nil\",type=\"NilClass\"},{name=\"command\",value=\"nil\",type=\"NilClass\"}\"\n", 'variablesReference' => 0
    }, 'command' => 'evaluate', 'request_seq' => 6, 'seq' => 0, 'success' => true, 'type' => 'response'
  }
  locals = proxy.mruby_parse_locals(res['body']['result'])
  assert_kind_of Array, locals
  assert_equal 4, locals.size
  assert_equal '&', locals[0]['name']
  assert_equal 'nil', locals[0]['value']
  assert_equal 'NilClass', locals[0]['type']

  res2 = {
    'body' => {
      'result' => "(lldb) expr mrb_gdb_get_locals(mrb)\n(char *) $1 = 0x00000001000e5a84 \"locals=[{name=\\\"a\\\",value=\\\"0\\\",type=\\\"Integer\\\"},{name=\\\"b\\\",value=\\\"0\\\",type=\\\"Integer\\\"},{name=\\\"&\\\",value=\\\"nil\\\",type=\\\"NilClass\\\"},{name=\\\"test1\\\",value=\\\"\\\"aaaa\\\"\\\",type=\\\"String\\\"},{name=\\\"test2\\\",value=\\\"\\\"bbbb\\\"\\\",type=\\\"String\\\"},{name=\\\"test3\\\",value=\\\"3\\\",type=\\\"Integer\\\"}\"\n", 'variablesReference' => 0
    }, 'command' => 'evaluate', 'request_seq' => 6, 'seq' => 0, 'success' => true, 'type' => 'response'
  }
  locals2 = proxy.mruby_parse_locals(res2['body']['result'])
  assert_kind_of Array, locals2
  assert_equal 6, locals2.size
  assert_equal 'a', locals2[0]['name']
  assert_equal '0', locals2[0]['value']
  assert_equal 'Integer', locals2[0]['type']
  assert_equal 'test1', locals2[3]['name']
  assert_equal '"aaaa"', locals2[3]['value']
  assert_equal 'String', locals2[3]['type']
end

assert('restore_response') do
  proxy = DapProxy.new('')
  proxy.request_buffer = [{ 'seq' => 1, 'command' => 'next' }, { 'seq' => 3, 'command' => 'stepIn' },
                          { 'command' => 'next', 'arguments' => { 'threadId' => 38 },
                            'type' => 'request', 'seq' => 152 }]
  ret = proxy.restore_response({ 'body' => { 'allThreadsContinued' => true },
                                 'command' => 'continue', 'request_seq' => 152, 'seq' => 0,
                                 'success' => true, 'type' => 'response' })
  assert_equal 'next', ret['command']
end

assert('add_mruby_stack levels == 1') do
  proxy = DapProxy.new('')
  proxy.mruby_code_fetch_source = DAP::Type::Source.new('/home/mruby-gdb/src/mruby_gdb.c').to_h
  proxy.request_buffer = [{ 'seq' => 1, 'command' => 'next' }, { 'seq' => 3, 'command' => 'stepIn' },
                          { 'command' => 'next', 'arguments' => { 'threadId' => 38 },
                            'type' => 'request', 'seq' => 152 },
                          { 'command' => 'stackTrace',
                            'arguments' => { 'threadId' => 871, 'startFrame' => 0, 'levels' => 1 },
                            'type' => 'request', 'seq' => 9 }]
  ret = proxy.add_mruby_stack({ 'body' => {
                                  'stackFrames' => [{ 'column' => 22, 'id' => 288, 'line' => 100,
                                                      'name' => 'mrb_gdb_code_fetch',
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
