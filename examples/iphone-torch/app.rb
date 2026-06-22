# iPhone Torch — the whole behaviour is Ruby. The `Torch` class comes from the
# linked picoruby-iphone-torch gem; its on/off/available? drive AVCaptureDevice
# through the gem's Darwin port. This app owns the dispatch the Swift buttons call.
#
# vm_call(vm, "on"/"off", "") invokes $app.on / $app.off and returns whatever this
# prints (captured stdout), which the UI appends to its log.
#
# WHY THIS PROVES IT IS RUBY: app.rb is compiled at runtime, in-app, by PicoRuby's
# prism compiler (VMExecutor.start -> vm_open). The behaviour below can be changed
# with NO rebuild of the C gem or the Swift backend — only this resource file. ON
# runs a Ruby-defined BLINK (flash N times via a `while` loop + sleep_ms, then stay
# lit) and counts presses in Ruby; OFF turns the torch off. The flashing pattern,
# the count, the timing — all of it lives here in Ruby, not in C and not in Swift.
BLINK_COUNT = 3     # change this, reinstall, and the torch flashes that many times
BLINK_MS    = 120   # flash on/off duration in milliseconds

class TorchApp
  def initialize
    @torch = Torch.new
    @presses = 0
    @log = []
    if @torch.available?
      log "ready: torch available — ON flashes #{BLINK_COUNT}x then stays lit"
    else
      log "ready: no torch on this device (Simulator?) — on/off will be no-ops"
    end
  end

  def on(arg = nil)
    @presses += 1
    if @torch.available?
      blink(BLINK_COUNT)
      @torch.on            # leave it lit after the flashes
      log "ON ##{@presses}: blinked #{BLINK_COUNT}x in Ruby, now lit"
    else
      log "ON ##{@presses}: torch unavailable (no actuation)"
    end
    flush_log
  end

  def off(arg = nil)
    @torch.off
    log "OFF: torch off"
    flush_log
  end

  private

  # Pure-Ruby blink: drive the gem primitive on/off in a loop, pausing with
  # sleep_ms (Kernel function from mruby-task; on iOS it real-time blocks via the
  # bridge HAL). This is the "L チカ" — the loop is Ruby, the light is the hardware.
  def blink(times)
    i = 0
    while i < times
      @torch.on
      sleep_ms(BLINK_MS)
      @torch.off
      sleep_ms(BLINK_MS)
      i += 1
    end
  end

  def log(msg)
    @log.push(msg)
  end

  def flush_log
    return nil if @log.empty?
    out = @log.join("\n")
    @log = []
    print out
    nil
  end
end

$app = TorchApp.new
