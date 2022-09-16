class DapProxy
  attr_accessor :mruby_code_fetch_bp
end

assert('parse_mruby_expr') do
  proxy = DapProxy.new({ adapter: '' })
  local_variables = '(const char *) $0 = "["e", "current_pos", "x", "y", "readable", "_writable"]"'
  global_variables = '(const char *) $1 = "["$\'", "$stderr", "$:", "$\"", "$stdout", "$PROCESS_ID", "$&", "$`", "$1", "$PID", "$$", "$?", "$PROGRAM_NAME", "$mode_list", "$+", "$~", "$0", "$stdin", "$CHILD_STATUS"]"'
  locals = proxy.parse_mruby_expr(local_variables)
  assert_kind_of Array, locals
  assert_equal 6, locals.size
  globals = proxy.parse_mruby_expr(global_variables)
  assert_kind_of Array, globals
  assert_equal 19, globals.size
end

assert('mruby_set_function_breakpoints') do
  proxy = DapProxy.new({ adapter: '' })
  message = { 'command' => 'setFunctionBreakpoints',
              'arguments' => { 'breakpoints' => [] }, 'type' => 'request', 'seq' => 5 }
  ret = proxy.mruby_set_function_breakpoints(message)
  assert_equal 0, ret['arguments']['breakpoints'].size
end
