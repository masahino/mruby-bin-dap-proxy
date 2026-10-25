class DapProxy
  attr_accessor :mruby_code_fetch_bp
end

assert('parse_mruby_expr') do
  proxy = build_mock_dap_proxy
  local_variables = '(const char *) $0 = "["e", "current_pos", "x", "y", "readable", "_writable"]"'
  global_variables = '(const char *) $1 = "["$\'", "$stderr", "$:", "$\"", "$stdout", "$PROCESS_ID", "$&", "$`", "$1", "$PID", "$$", "$?", "$PROGRAM_NAME", "$mode_list", "$+", "$~", "$0", "$stdin", "$CHILD_STATUS"]"'
  locals = proxy.parse_mruby_expr(local_variables)
  assert_kind_of Array, locals
  assert_equal 6, locals.size
  globals = proxy.parse_mruby_expr(global_variables)
  assert_kind_of Array, globals
  assert_equal 19, globals.size
end

class RecordingDAPClient
  attr_reader :args

  def initialize(response)
    @response = response
  end

  def evaluate(args)
    @args = args
    yield @response
  end
end

def lldb_summary(text)
  escaped = ''
  text.each_char do |c|
    escaped << '\\' if c == '\\' || c == '"'
    escaped << c
  end
  "0x000000011802b704 \"#{escaped}\""
end

def build_evaluating_proxy(response, watch_evaluate)
  proxy = build_mock_dap_proxy
  proxy.instance_variable_set(:@debugger, RecordingDAPClient.new(response))
  config = proxy.instance_variable_get(:@debugger_config)
  config[:watch_evaluate] = watch_evaluate
  proxy.instance_variable_set(:@last_stack, { 'id' => 524287 })
  proxy
end

assert('parse_mruby_expr reads the lldb-dap string summary') do
  proxy = build_mock_dap_proxy
  assert_equal %w[dyn_args x], proxy.parse_mruby_expr(lldb_summary('["dyn_args", "x"]'))
  original = '{"name" => "s", "value" => "\"abc\"", "type" => "String"}'
  assert_equal({ 'name' => 's', 'value' => '"abc"', 'type' => 'String' },
               proxy.parse_mruby_expr(lldb_summary(original)))
end

assert('parse_mruby_expr rejects truncated and error results') do
  proxy = build_mock_dap_proxy
  assert_nil proxy.parse_mruby_expr("#{lldb_summary('["a", "b"]')}...")
  assert_nil proxy.parse_mruby_expr("error: <user expression 1>:1:31: use of undeclared identifier 'mrb'\n")
  assert_nil proxy.parse_mruby_expr(nil)
end

assert('mruby_variables_expr and mruby_variable_expr are plain C expressions') do
  proxy = build_mock_dap_proxy
  assert_equal 'mrb_debug_get_local_variables(mrb)', proxy.mruby_variables_expr(0)
  assert_equal 'mrb_debug_get_instance_variables(mrb)', proxy.mruby_variables_expr(2)
  assert_equal 'mrb_debug_get_global_variable(mrb, "$stdout")', proxy.mruby_variable_expr(1, '$stdout')
end

assert('mruby_evaluate uses the DAP evaluate path on the native frame') do
  proxy = build_evaluating_proxy({ 'success' => true, 'body' => { 'result' => '' } }, true)
  proxy.mruby_evaluate('mrb_debug_get_local_variables(mrb)')
  args = proxy.instance_variable_get(:@debugger).args
  assert_equal 'mrb_debug_get_local_variables(mrb)', args['expression']
  assert_equal 'watch', args['context']
  assert_equal 524288, args['frameId']
end

assert('mruby_evaluate keeps the command form for the other adapters') do
  proxy = build_evaluating_proxy({ 'success' => true, 'body' => { 'result' => '' } }, false)
  proxy.mruby_evaluate('mrb_debug_get_local_variables(mrb)')
  args = proxy.instance_variable_get(:@debugger).args
  assert_equal '`expr -R -f s -- mrb_debug_get_local_variables(mrb)', args['expression']
  assert_nil args['context']
  assert_equal 524287, args['frameId']
end

assert('mruby_break wraps the void call and reports failure') do
  proxy = build_evaluating_proxy({ 'success' => true, 'body' => { 'result' => '0' } }, true)
  assert_true proxy.mruby_break('test')
  args = proxy.instance_variable_get(:@debugger).args
  assert_equal '(int)(mrb_break(mrb), 0)', args['expression']
  assert_equal 'watch', args['context']
  assert_equal 524288, args['frameId']

  failing = build_evaluating_proxy({ 'success' => false, 'body' => { 'error' => { 'format' => 'unknown error' } } }, true)
  assert_false failing.mruby_break('test')
end

assert('stop_at_mruby_code? tolerates a frame without a source') do
  proxy = build_mock_dap_proxy
  proxy.instance_variable_set(:@last_stack, { 'id' => 1, 'name' => 'no_debug_info' })
  assert_false proxy.stop_at_mruby_code?
  proxy.instance_variable_set(:@last_stack, { 'id' => 1, 'source' => { 'path' => '/a/b.rb' } })
  assert_true proxy.stop_at_mruby_code?
end

assert('mruby_set_function_breakpoints') do
  proxy = build_mock_dap_proxy
  message = { 'command' => 'setFunctionBreakpoints',
              'arguments' => { 'breakpoints' => [] }, 'type' => 'request', 'seq' => 5 }
  ret = proxy.mruby_set_function_breakpoints(message)
  assert_equal 0, ret['arguments']['breakpoints'].size
end
