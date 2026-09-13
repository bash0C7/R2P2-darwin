# Ruby half of picoruby-iphone-torch. The Torch class itself is C
# (src/mruby/torch.c); this file adds what the Lチカ script needs on top of the
# reduced iOS gem set.
#
# Kernel#sleep: mruby-task ships only sleep_ms, so give app.rb the CRuby-style
# seconds form. Fractional seconds are fine (sleep 0.5). This is the example's
# own definition — no other gem in the torch build defines Kernel#sleep.
#
# It is also the script's only cooperative point, so Stop lives here: when the
# host has raised the stop flag (Torch.stop_requested?), put the light out and
# raise StopIteration, which Kernel#loop rescues — `loop do ... end` returns,
# app.rb finishes, and vm_open hands control back to the host. app.rb itself
# stays the plain ten-line Lチカ.
module Kernel
  def sleep(sec)
    sleep_ms((sec * 1000).to_i)
    if Torch.stop_requested?
      Torch.new.off
      raise StopIteration
    end
    sec
  end
end
