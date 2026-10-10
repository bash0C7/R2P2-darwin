# Row picking for `xcrun devicectl list devices`, kept free of the Rakefile so
# rakelib/test_devicectl.rb can feed it listing text without a device.
module Devicectl
  UDID = /\h{8}-\h{16}|\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/
  ROW  = /\A(?<name>\S.*?)\s{2,}.*?(?<udid>#{UDID})(?: \(UDID\))?\s+(?<state>\S.*?)(?=\s{2,}|\s*\z)/

  Row = Struct.new(:line, :name, :udid, :state, :simulated) do
    def reachable? = state.match?(/\A(connected|available)\b/)
    def connected? = state.match?(/\Aconnected\b/)
  end

  # Rows of the listing. Xcode versions that print a Reality column mark
  # Simulators `simulated`; rows without the column are physical.
  def self.rows(text)
    text.lines.filter_map do |line|
      m = ROW.match(line) or next
      Row.new(line, m[:name].strip, m[:udid], m[:state], line.match?(/\ssimulated\s*\z/))
    end
  end

  def self.physical_rows(text)
    rows(text).reject(&:simulated)
  end

  def self.connected_names(text)
    physical_rows(text).select(&:connected?).map(&:name)
  end

  # Apple names a device "<owner>\u00A0Apple\u00A0Watch", with NO-BREAK SPACE
  # between the words; both sides are flattened before comparison.
  def self.normalize(str)
    str.tr("\u00A0", " ")
  end

  # Keep the rows (strings) containing `want`; no filter when `want` is empty.
  def self.filter_by_name(rows, want)
    return rows if want.nil? || want.empty?
    needle = normalize(want)
    picked = rows.select { |row| normalize(row).include?(needle) }
    raise "DEVICE_NAME=#{want.inspect} matches none of:\n#{rows.join}" if picked.empty?
    picked
  end

  # UDID of the reachable physical device whose row matches `pattern`,
  # preferring one that reports `connected`; nil when there is none.
  def self.pick_udid(text, pattern, name: nil)
    rows = physical_rows(text).select { |r| r.line.match?(pattern) }
    rows = filter_by_name(rows.map(&:line), name).map { |l| rows.find { |r| r.line == l } }
    rows = rows.select(&:reachable?)
    (rows.find(&:connected?) || rows.first)&.udid
  end
end
