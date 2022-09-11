class MrubyBreakpoint
  attr_accessor :use_stepin_breakpoint, :use_next_breakpoint, :use_stepout_breakpoint

  def initialize(function_name)
    @code_fetch_hook = function_name
    @mruby_breakpoints = {}
    @use_stepin_breakpoint = false
    @use_next_breakpoint = false
    @use_stepout_breakpoint = false
  end

  def use_temporary_breakpoint
    @use_stepin_breakpoint || @use_next_breakpoint || @use_stepout_breakpoint
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
    if @use_next_breakpoint
      bp_args['breakpoints'].push({
                                    'name' => @code_fetch_hook,
                                    'condition' => 'mrb_check_next(mrb) == 1'
                                    # 'condition' => "ciidx<=#{@stepover_breakpoint}"
                                  })
    end
    if @use_stepout_breakpoint
      bp_args['breakpoints'].push({
                                    'name' => @code_fetch_hook,
                                    'condition' => 'mrb_check_stepout(mrb) == 1'
                                    # 'condition' => "ciidx<=#{@stepover_breakpoint}"
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
