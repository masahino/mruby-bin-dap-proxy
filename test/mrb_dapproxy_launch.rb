assert('launch_r2c expands Ruby source arguments from cwd') do
  proxy = DapProxy.allocate
  message = {
    'command' => 'launch',
    'arguments' => {
      'program' => 'foo/bar/mruby',
      'args' => ['test/example.rb', '--verbose'],
      'cwd' => '/work/project'
    }
  }

  result = proxy.launch_r2c(message)

  assert_equal 'foo/bar/mruby', result['arguments']['program']
  assert_equal ['/work/project/test/example.rb', '--verbose'], result['arguments']['args']
end

assert('launch_r2c expands Ruby source arguments from the process cwd') do
  proxy = DapProxy.allocate
  message = {
    'command' => 'launch',
    'arguments' => {
      'program' => 'mruby',
      'args' => ['test/example.rb']
    }
  }

  result = proxy.launch_r2c(message)

  assert_equal [File.expand_path('test/example.rb')], result['arguments']['args']
end

assert('launch_r2c preserves absolute Ruby source arguments') do
  proxy = DapProxy.allocate
  message = {
    'command' => 'launch',
    'arguments' => {
      'program' => 'mruby',
      'args' => ['/work/project/test/example.rb'],
      'cwd' => '/another/directory'
    }
  }

  result = proxy.launch_r2c(message)

  assert_equal ['/work/project/test/example.rb'], result['arguments']['args']
end

assert('launch_r2c preserves non-Ruby arguments') do
  proxy = DapProxy.allocate
  message = {
    'command' => 'launch',
    'arguments' => {
      'program' => 'embedded-mruby',
      'args' => ['config.yml', '--verbose'],
      'cwd' => '/work/project'
    }
  }

  result = proxy.launch_r2c(message)

  assert_equal ['config.yml', '--verbose'], result['arguments']['args']
end

assert('launch_r2c accepts a launch request without args') do
  proxy = DapProxy.allocate
  message = {
    'command' => 'launch',
    'arguments' => { 'program' => 'embedded-mruby' }
  }

  assert_same message, proxy.launch_r2c(message)
end
