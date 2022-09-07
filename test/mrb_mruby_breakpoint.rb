assert('add_breakpoint') do
  mrb_bp = MrubyBreakpoint.new('mrb_debug_breakpoint_function')
  mrb_bp.add_breakpoint('foo.rb', { 'line' => 10 })
  assert_equal 1, mrb_bp.c_breakpoints['breakpoints'].size
  assert_equal 'mrb_debug_breakpoint_function', mrb_bp.c_breakpoints['breakpoints'][0]['name']
  assert_equal 'md_strcmp(filename,"foo.rb")==0 && line==10', mrb_bp.c_breakpoints['breakpoints'][0]['condition']

  mrb_bp.add_breakpoint('foo.rb', { 'line' => 20 })
  assert_equal 2, mrb_bp.c_breakpoints['breakpoints'].size
  assert_equal 'mrb_debug_breakpoint_function', mrb_bp.c_breakpoints['breakpoints'][1]['name']
  assert_equal 'md_strcmp(filename,"foo.rb")==0 && line==20',
               mrb_bp.c_breakpoints['breakpoints'][1]['condition']

  mrb_bp.add_breakpoint('bar.rb', { 'line' => 30 })
  assert_equal 3, mrb_bp.c_breakpoints['breakpoints'].size
  assert_equal 'mrb_debug_breakpoint_function', mrb_bp.c_breakpoints['breakpoints'][2]['name']
  assert_equal 'md_strcmp(filename,"bar.rb")==0 && line==30',
               mrb_bp.c_breakpoints['breakpoints'][2]['condition']
end

assert('del_breakpoint') do
  mrb_bp = MrubyBreakpoint.new('mrb_debug_breakpoint_function')
  mrb_bp.add_breakpoint('foo.rb', { 'line' => 10 })
  mrb_bp.add_breakpoint('foo.rb', { 'line' => 20 })
  mrb_bp.add_breakpoint('bar.rb', { 'line' => 30 })

  mrb_bp.del_breakpoint('baz.rb', { 'line' => 40 })
  assert_equal 3, mrb_bp.c_breakpoints['breakpoints'].size

  mrb_bp.del_breakpoint('foo.rb', { 'line' => 50 })
  assert_equal 3, mrb_bp.c_breakpoints['breakpoints'].size

  mrb_bp.del_breakpoint('foo.rb', { 'line' => 20 })
  assert_equal 2, mrb_bp.c_breakpoints['breakpoints'].size

  mrb_bp.del_breakpoint('bar.rb', { 'line' => 30 })
  assert_equal 1, mrb_bp.c_breakpoints['breakpoints'].size
end

assert('use_temporary_breakpoint') do
  mrb_bp = MrubyBreakpoint.new('mrb_debug_breakpoint_function')
  mrb_bp.add_breakpoint('foo.rb', { 'line' => 10 })
  mrb_bp.add_breakpoint('foo.rb', { 'line' => 20 })
  mrb_bp.add_breakpoint('bar.rb', { 'line' => 30 })
  assert_equal 3, mrb_bp.c_breakpoints['breakpoints'].size

#  mrb_bp.use_temporary_breakpoint = true
#  assert_equal 4, mrb_bp.c_breakpoints['breakpoints'].size
end
