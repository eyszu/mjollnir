require "uri"
require "http/params"

module Mjollnir
  enum SSLMode
    # Never use TLS (default).
    Disable
    # Use TLS when the server supports it, fall back to plaintext.
    Prefer
    # Require TLS, do not verify the certificate (libpq `sslmode=require`).
    Require
    # Require TLS and verify the certificate chain and host name.
    VerifyFull
  end

  # Connection parameters parsed from a URL.
  #
  # ```text
  # postgres://user:pass@host:5432/dbname?sslmode=require&application_name=app
  # postgres://user@%2Fvar%2Frun%2Fpostgresql/dbname      (unix socket directory)
  # postgres:///dbname?host=/var/run/postgresql&user=app   (same, via query)
  # ```
  struct ConnInfo
    getter host : String
    getter port : Int32
    getter user : String
    getter password : String?
    getter database : String
    getter sslmode : SSLMode
    getter application_name : String?
    getter connect_timeout : Time::Span?
    # Use named server-side prepared statements (default). When false every
    # execution uses the unnamed statement (safe behind transaction poolers).
    getter prepared : Bool
    # Maximum number of prepared statements kept per connection.
    getter statement_cache_size : Int32
    # Extra run-time parameters sent in the startup packet (e.g. `search_path`).
    getter options : Hash(String, String)

    # Query parameters handled by the driver; everything else in the query
    # string is forwarded to the server as a run-time parameter.
    RESERVED = %w(host port user password dbname sslmode application_name connect_timeout
      prepared_statements statement_cache_size
      max_pool_size initial_pool_size max_idle_pool_size checkout_timeout)

    def initialize(@host, @port, @user, @password, @database, @sslmode,
                   @application_name, @connect_timeout, @prepared, @statement_cache_size, @options)
    end

    def self.from_url(url : String) : ConnInfo
      from_uri(URI.parse(url))
    end

    def self.from_uri(uri : URI) : ConnInfo
      params = HTTP::Params.parse(uri.query || "")
      host = params["host"]? || uri.host.presence || ENV["PGHOST"]? || "localhost"
      host = URI.decode(host) if host.includes?('%')
      port = (params["port"]? || uri.port || ENV["PGPORT"]?).try(&.to_i) || 5432
      user = params["user"]? || uri.user.presence || ENV["PGUSER"]? || ENV["USER"]? || "postgres"
      password = params["password"]? || uri.password.presence || ENV["PGPASSWORD"]?
      database = params["dbname"]? || uri.path.lstrip('/').presence || ENV["PGDATABASE"]? || user
      sslmode = case mode = params["sslmode"]?
                when nil, "disable"             then SSLMode::Disable
                when "prefer", "allow"          then SSLMode::Prefer
                when "require"                  then SSLMode::Require
                when "verify-full", "verify-ca" then SSLMode::VerifyFull
                else
                  raise ArgumentError.new("unknown sslmode #{mode.inspect}")
                end
      timeout = params["connect_timeout"]?.try { |s| s.to_f.seconds }
      prepared = ConnInfo.bool(params["prepared_statements"]?, true)
      cache_size = (params["statement_cache_size"]? || "256").to_i
      options = {} of String => String
      params.each do |key, value|
        options[key] = value unless RESERVED.includes?(key)
      end
      new(host, port, user, password, database, sslmode, params["application_name"]?,
        timeout, prepared, cache_size, options)
    end

    protected def self.bool(value : String?, default : Bool) : Bool
      case value
      when nil                              then default
      when "true", "1", "yes", "on", "t"    then true
      when "false", "0", "no", "off", "f"   then false
      else
        raise ArgumentError.new("invalid boolean #{value.inspect}")
      end
    end

    def unix_socket? : Bool
      host.starts_with?('/')
    end
  end
end
