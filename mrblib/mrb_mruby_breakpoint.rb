class MrubyBreakpoint
  attr_accessor :use_stepin_breakpoint, :stepover_breakpoint

  def initialize(function_name)
    @code_fetch_hook = function_name
    @mruby_breakpoints = {}
    @use_stepin_breakpoint = false
    @stepover_breakpoint = 0
  end

  def use_temporary_breakpoint
    @use_stepin_breakpoint || @stepover_breakpoint > 0
  end

  def c_breakpoints
    bp_args = { 'breakpoints' => [] }
    @mruby_breakpoints.each do |filename, bps|
      bps.each do |bp|
        rbp = {}
        rbp['name'] = @code_fetch_hook
        rbp['condition'] = "md_strcmp(filename,\"#{filename}\")==0 && line==#{bp['line']}"
        bp_args['breakpoints'].push rbp
      end
    end
    bp_args['breakpoints'].push({ 'name' => @code_fetch_hook }) if @use_stepin_breakpoint
    if @stepover_breakpoint > 0

      bp_args['breakpoints'].push({
                                    'name' => @code_fetch_hook,
                                    'condition' => "mrb_gdb_get_callinfosize(mrb)<=#{@stepover_breakpoint}"
                                  })
    end
    bp_args
  end

  def add_breakpoint(filename, mrb_bp)
    if @mruby_breakpoints[filename].nil?
      @mruby_breakpoints[filename] = [mrb_bp]
    else
      @mruby_breakpoints[filename].push mrb_bp
    end
  end

  def del_breakpoint(filename, mrb_bp)
    return if @mruby_breakpoints[filename].nil?

    @mruby_breakpoints[filename].delete mrb_bp
    @mruby_breakpoints.delete filename if @mruby_breakpoints[filename].empty?
  end

  def clear_breakpoints(filename)
    @mruby_breakpoints[filename] = []
  end

  def set_breakpoints(filename, bps)
    @mruby_breakpoints[filename] = bps
  end
end
