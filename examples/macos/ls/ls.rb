# ls-like listing of the current directory. Exercised by `rake single` as a
# realistic coverage example over what the mruby-io / mruby-dir / core /
# stdlib gemboxes give you: Dir.entries, File class methods, sprintf,
# method definitions, while/if/case-like control flow, Array sort/reject,
# rescue.

def human_size(bytes)
  units = ["B", "K", "M", "G", "T"]
  i = 0
  size = bytes.to_f
  while size >= 1024 && i < units.size - 1
    size /= 1024
    i += 1
  end
  i == 0 ? "#{bytes}B" : sprintf("%.1f%s", size, units[i])
end

def kind(name)
  if File.symlink?(name)
    "l"
  elsif File.directory?(name)
    "d"
  elsif File.file?(name)
    "-"
  else
    "?"
  end
end

dir = "."
entries = Dir.entries(dir).reject { |n| n == "." || n == ".." }.sort

puts "Listing: #{File.expand_path(dir)}"
puts

files = 0
dirs  = 0
bytes = 0
entries.each do |name|
  k = kind(name)
  if k == "d"
    dirs += 1
    puts sprintf("%s %8s  %s/", k, "-", name)
  else
    sz = File.size(name) rescue 0
    files += 1
    bytes += sz
    puts sprintf("%s %8s  %s", k, human_size(sz), name)
  end
end

puts
puts sprintf("%d files (%s), %d directories", files, human_size(bytes), dirs)
