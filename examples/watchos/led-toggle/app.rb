# Watch LED Toggle — the LED state machine lives here, on the watch, in a
# persistent VM. Swift only hosts the VM and renders whatever colour this
# prints: vm_call(vm, "tick"/"toggle", "") invokes $app.tick / $app.toggle and
# the captured stdout ("red" / "blue") becomes the circle's colour.
#
# app.rb is compiled at runtime, in-app, by PicoRuby's prism compiler.
class LEDApp
  def initialize
    @state = "red"
  end

  def tick(_)
    print @state
  end

  def toggle(_)
    @state = @state == "red" ? "blue" : "red"
    print @state
  end
end

$app = LEDApp.new
puts "booted"
