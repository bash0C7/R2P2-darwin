require "torch"

torch = Torch.new

loop do
  torch.on
  sleep 0.5
  torch.off
  sleep 0.5
end
