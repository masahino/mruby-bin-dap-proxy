class MockDAPClient
  def scopes(_args)
    response = {
      'seq' => 0,
      'type' => 'response',
      'request_seq' => 12,
      'success' => true,
      'command' => 'scopes'
    }
    block_given? ? yield(response) : response
  end

  def variables(_args)
    response = {
      'seq' => 0,
      'type' => 'response',
      'request_seq' => 12,
      'success' => true,
      'command' => 'variables',
      'body' => {
        'variables' => [
          { 'name' => 'filename', 'value' => '"/foo/bar/baz"', 'type' => 'Strings',
            'variablesReference' => 0 },
          { 'name' => 'line', 'value' => '11', 'type' => 'Integer',
            'variablesReference' => 1 },
          { 'name' => 'prev_ciidx', 'value' => '10', 'type' => 'Integer',
            'variablesReference' => 2 }
        ]
      }
    }
    block_given? ? yield(response) : response
  end
end

def build_mock_dap_proxy
  proxy = DapProxy.allocate
  proxy.instance_variable_set(:@debugger, MockDAPClient.new)
  proxy.instance_variable_set(:@debugger_config, DapProxy::DEFAULT_DEBUGGER_CONFIG.dup)
  proxy.instance_variable_set(:@logger, $stderr)
  proxy.instance_variable_set(:@mruby_code_fetch_source, nil)
  proxy.instance_variable_set(:@mruby_code_fetch_line, 0)
  proxy.instance_variable_set(:@mruby_code_fetch_bp, nil)
  proxy.instance_variable_set(:@last_filename, '')
  proxy.instance_variable_set(:@last_line, '')
  proxy.instance_variable_set(:@last_ciidx, 999)
  proxy.instance_variable_set(:@last_stack, nil)
  proxy.instance_variable_set(:@request_buffer, [])
  proxy
end
