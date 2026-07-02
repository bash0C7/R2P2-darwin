# Networking — the whole HTTP/TLS round-trip is Ruby. `Net::HTTPSClient` comes from
# the linked picoruby-net gem; on iOS it dials a raw BSD socket and runs the TLS
# handshake through mbedTLS (picoruby-net's ports/posix/tls_client.c), seeded by the
# picoruby-mbedtls/rng DARWIN entropy ports (SecRandomCopyBytes via -framework
# Security). NO OpenSSL, and NO Apple URL-loading API — so App Transport Security
# (which only governs NSURLSession/CFNetwork) is bypassed entirely.
#
# vm_call(vm, "fetch", "") invokes $app.fetch and returns whatever this prints
# (captured stdout), which the UI appends to its log.
#
# WHY THIS PROVES IT IS RUBY + iOS TLS: app.rb is compiled at runtime, in-app, by
# PicoRuby's prism compiler. Change the host/path below, reinstall, and the request
# changes with NO rebuild of libmruby.a or the Swift layer. A successful response
# means the mbedTLS handshake completed on iOS using the Darwin entropy port.
#
# NOTE: picoruby-net's posix TLS port sets MBEDTLS_SSL_VERIFY_NONE — it completes the
# handshake but does NOT validate the server certificate. This example demonstrates
# connectivity + handshake, not a trust decision.
HOST = "example.com"
PATH = "/"

class NetApp
  def initialize
    @fetches = 0
    log "ready: HTTPS GET https://#{HOST}#{PATH} on tap (mbedTLS over BSD socket)"
    flush_log
  end

  def fetch(arg = nil)
    @fetches += 1
    log "FETCH ##{@fetches}: connecting to #{HOST}:443 …"
    begin
      response = Net::HTTPSClient.new(HOST).get(PATH)
      head = response.to_s.split("\r\n\r\n", 2).first.to_s
      status = head.split("\r\n").first.to_s
      log "  handshake OK, response received (#{response.to_s.bytesize} bytes)"
      log "  status: #{status}"
    rescue => e
      log "  error: #{e.class}: #{e.message}"
    end
    flush_log
  end

  private

  def log(msg)
    (@log ||= []).push(msg)
  end

  def flush_log
    return nil if @log.nil? || @log.empty?
    out = @log.join("\n")
    @log = []
    print out
    nil
  end
end

$app = NetApp.new
