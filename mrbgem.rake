MRuby::Gem::Specification.new('mruby-bin-dap-proxy') do |spec|
  spec.bins = ['mruby-dap-proxy']
  spec.license = 'MIT'
  spec.authors = 'masahino'
  spec.add_dependency 'mruby-onig-regexp'
  spec.add_dependency 'mruby-dap-client', :github => 'masahino/mruby-dap-client', :branch => 'main'
end
