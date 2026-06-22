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
