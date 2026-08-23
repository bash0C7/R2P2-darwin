# Networking — the whole HTTP/TLS round-trip is Ruby. `Net::HTTP` comes from the
# linked picoruby-net-http gem on top of picoruby-socket; on iOS the socket gem's
# darwin port (fork port-darwin) dials a raw BSD socket and runs the TLS
# handshake through mbedTLS, seeded by the picoruby-mbedtls/rng DARWIN entropy
# ports (SecRandomCopyBytes via -framework Security). No OpenSSL and no Apple
# URL-loading API, so App Transport Security (which only governs
# NSURLSession/CFNetwork) does not apply.
#
# vm_call(vm, "fetch", "") invokes $app.fetch and returns whatever this prints
# (captured stdout), which the UI appends to its log.
#
# app.rb is compiled at runtime, in-app, by PicoRuby's prism compiler: change the
# host/path below, reinstall, and the request changes with no rebuild of
# libmruby.a or the Swift layer. A successful response means the mbedTLS
# handshake completed on iOS using the Darwin entropy port.
#
# The demo sets verify_mode = SSLContext::VERIFY_NONE (see fetch): iOS ships no PEM
# CA bundle for mbedTLS, so the handshake completes but the server certificate is
# not validated. This example demonstrates connectivity + handshake, not a trust
# decision; bundle a CA PEM and pass it to SSLContext#set_ca_pem to verify.
HOST = "example.com"
PATH = "/"

class NetApp
  def initialize
    @fetches = 0
    @log = []
    log "ready: HTTPS GET https://#{HOST}#{PATH} on tap (mbedTLS over BSD socket)"
    flush_log
  end

  def fetch(arg = nil)
    @fetches += 1
    log "FETCH ##{@fetches}: connecting to #{HOST}:443 …"
    begin
      http = Net::HTTP.new(HOST, 443)
      http.use_ssl = true
      # Demo setting: iOS ships no PEM CA bundle for mbedTLS to verify against,
      # so the certificate chain is not verified here (see the example README).
      http.verify_mode = SSLContext::VERIFY_NONE
      response = http.get(PATH)
      http.finish
      log "  handshake OK, response received (#{response.body.to_s.bytesize} bytes)"
      log "  status: HTTP/#{response.http_version} #{response.code} #{response.message}"
    rescue => e
      log "  error: #{e.class}: #{e.message}"
    end
    flush_log
  end

  private

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

$app = NetApp.new
