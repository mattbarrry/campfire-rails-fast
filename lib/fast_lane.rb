# Whole-response cache in front of the Rails stack.
#
# A GET is replayed byte for byte when the same client (same cookies, user agent, accept headers)
# asks for the same URL and the database hasn't changed since. "Changed" is SQLite's
# PRAGMA data_version, which moves whenever any connection in any process commits. A response is
# only stored if data_version was the same before and after Rails rendered it, so a request that
# wrote (a session refresh, a read marker) or raced a writer is never cached.
#
# Bodies are stored gzipped once and served as-is to clients that accept gzip.
require "sqlite3"
require "zlib"
require "digest"

class FastLane
  VARY = %w[ HTTP_COOKIE HTTP_USER_AGENT HTTP_ACCEPT HTTP_TURBO_FRAME HTTP_X_REQUESTED_WITH HTTP_HOST HTTP_X_FORWARDED_PROTO ].freeze
  MAX_ENTRIES = 20_000
  MAX_AGE = 60 # seconds; bounds anything rendered from the clock
  SKIP_PREFIXES = %w[ /cable /up /assets/ /rails/ ].freeze

  Entry = Struct.new(:version, :expires_at, :status, :headers, :body, :gzipped)

  def initialize(app, database:)
    @app = app
    @database = database
    @entries = {}
    @lock = Mutex.new
    @pid = nil
  end

  def call(env)
    return @app.call(env) unless cacheable_request?(env)

    key = key_for(env)
    gzip = env["HTTP_ACCEPT_ENCODING"].to_s.include?("gzip")
    version = data_version

    if (entry = @entries[key]) && entry.version == version && entry.expires_at > now
      return replay(entry, gzip)
    end

    status, headers, body = @app.call(env)

    if storable?(status, headers) && data_version == version
      chunks = +""
      body.each { |chunk| chunks << chunk }
      body.close if body.respond_to?(:close)
      entry = store(key, version, status, headers, chunks)
      replay(entry, gzip)
    else
      [ status, headers, body ]
    end
  end

  private
    def cacheable_request?(env)
      env["REQUEST_METHOD"] == "GET" && env["HTTP_COOKIE"] &&
        SKIP_PREFIXES.none? { |prefix| env["PATH_INFO"].start_with?(prefix) }
    end

    def key_for(env)
      key = String.new(env["PATH_INFO"]) << "?" << env["QUERY_STRING"].to_s
      VARY.each { |name| key << "\0" << env[name].to_s }
      Digest::SHA256.digest(key)
    end

    def storable?(status, headers)
      status == 200 && !headers["content-encoding"] && !headers["x-sendfile"] &&
        headers["content-type"].to_s.start_with?("text/html", "text/vnd.turbo-stream", "application/json") &&
        !headers["cache-control"].to_s.include?("no-store")
    end

    def store(key, version, status, headers, body)
      headers = headers.to_h.except("content-length", "etag", "last-modified").freeze
      gzipped = Zlib.gzip(body, level: 6)
      entry = Entry.new(version, now + MAX_AGE, status, headers, body.freeze, gzipped.freeze)
      @lock.synchronize do
        @entries.clear if @entries.size >= MAX_ENTRIES
        @entries[key] = entry
      end
      entry
    end

    def replay(entry, gzip)
      headers = entry.headers.dup
      headers["vary"] = "accept-encoding"
      if gzip
        headers["content-encoding"] = "gzip"
        headers["content-length"] = entry.gzipped.bytesize.to_s
        [ entry.status, headers, [ entry.gzipped ] ]
      else
        headers["content-length"] = entry.body.bytesize.to_s
        [ entry.status, headers, [ entry.body ] ]
      end
    end

    # data_version values are only comparable on one connection, so each process (forked workers
    # each open their own) shares a single read-only connection.
    def data_version
      @lock.synchronize do
        if @pid != Process.pid
          @pid = Process.pid
          @db = SQLite3::Database.new(@database, readonly: true).tap { |db| db.busy_timeout = 1000 }
          @version_stmt = @db.prepare("PRAGMA data_version")
        end
        @version_stmt.execute.next.first
      end
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
end
