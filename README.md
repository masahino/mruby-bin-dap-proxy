# mruby-bin-dap-proxy

[![build](https://github.com/masahino/mruby-bin-dap-proxy/actions/workflows/ci.yml/badge.svg)](https://github.com/masahino/mruby-bin-dap-proxy/actions/workflows/ci.yml)

A DAP proxy that presents mruby source-level debugging through a native debug
adapter.

## Responsibility

The generated executable is named `mruby-dap-proxy`. It sits between a DAP
client and a native debug adapter:

```text
DAP client
  -> mruby-dap-proxy
  -> native debug adapter
  -> an mruby executable built with mruby-debug
```

The proxy uses [`mruby-dap-client`](https://github.com/masahino/mruby-dap-client)
for its connection to the native adapter. It translates:

- Ruby source breakpoints into conditional native breakpoints at
  `mrb_debug_breakpoint_function`;
- native stack information into mruby source filenames and line numbers;
- scopes and variables into values obtained from `mruby-debug` helpers;
- `stepIn`, `next`, and `stepOut` into temporary native breakpoints.

The target executable must contain
[`mruby-debug`](https://github.com/masahino/mruby-debug) and native debug
information. The proxy does not instrument a target that was built without
these facilities.

## Native debug adapter

The default adapter command and type are both `lldb-vscode`. The proxy starts
the adapter as an external process. An alternative adapter path, adapter port,
and adapter type can be supplied on the command line.

The client-facing connection normally uses standard input and output. The
implementation also contains support for accepting a TCP connection.

## Options

```text
-l, --lldb_vscode_path PATH  Native debug adapter command
    --adapter_port PORT      Port used to connect to the native adapter
    --adapter_type TYPE      Native adapter type
-p, --port PORT              Client-facing TCP port
    --mrb_debug_path PATH    Source path containing the mruby debug hook
    --mrb_debug_line LINE    Line of the mruby debug hook
    --logfile FILE           Proxy log file
-i                           Start the interactive DAP shell
-h, --help                   Show help
```

If `--mrb_debug_path` and `--mrb_debug_line` are not supplied, the proxy tries
to locate `mrb_debug_breakpoint_function` with a temporary function breakpoint.

## Installation

Add the gem to `build_config.rb`:

```ruby
MRuby::Build.new do |conf|
  conf.gem github: 'masahino/mruby-bin-dap-proxy'
end
```

The resulting executable is:

```text
mruby/bin/mruby-dap-proxy
```

## Relationship to mrbmacs

[`mruby-mrbmacs-dap`](https://github.com/masahino/mruby-mrbmacs-dap) uses this
proxy for its default mruby debugging configuration. The executable is found
through `PATH`; an older installed copy may therefore be selected instead of a
recent local build.

## License

MIT. See `LICENSE`.
