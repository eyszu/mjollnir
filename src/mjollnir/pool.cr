module Mjollnir
  # A fiber-safe connection pool.
  #
  # Connections are created lazily up to `max_pool_size`. A call that finds
  # none free waits up to `checkout_timeout`, then raises `PoolTimeout`.
  # Connections that failed, are still inside a transaction, or still have an
  # open result set when returned are closed and replaced rather than reused.
  # A failed query is not retried: re-running a statement whose outcome is
  # unknown is the caller's decision.
  #
  # URL parameters: `max_pool_size` (default 10), `initial_pool_size` (default 0,
  # connections opened eagerly), `max_idle_pool_size` (default = max),
  # `checkout_timeout` (seconds, default 5).
  class Pool
    include Queries

    struct Options
      getter max_size : Int32
      getter initial_size : Int32
      getter max_idle : Int32
      getter checkout_timeout : Time::Span

      def initialize(@max_size = 10, @initial_size = 0, max_idle : Int32? = nil, @checkout_timeout = 5.seconds)
        @max_idle = max_idle || @max_size
      end

      def self.from_url(url : String) : Options
        params = HTTP::Params.parse(URI.parse(url).query || "")
        max_size = (params["max_pool_size"]? || "10").to_i
        new(
          max_size: max_size,
          initial_size: (params["initial_pool_size"]? || "0").to_i,
          max_idle: (params["max_idle_pool_size"]? || max_size.to_s).to_i,
          checkout_timeout: (params["checkout_timeout"]? || "5").to_f.seconds)
      end
    end

    getter info : ConnInfo
    getter options : Options

    @idle : Array(Connection) = [] of Connection
    @total : Int32 = 0
    @closed : Bool = false
    @mutex : Mutex = Mutex.new
    @available : Channel(Nil)

    def self.new(url : String) : Pool
      new(ConnInfo.from_url(url), Options.from_url(url))
    end

    def initialize(@info : ConnInfo, @options : Options = Options.new)
      raise ArgumentError.new("max_pool_size must be at least 1") if @options.max_size < 1
      @available = Channel(Nil).new(@options.max_size)
      @options.initial_size.clamp(0, @options.max_size).times do
        @idle << Connection.new(@info)
        @total += 1
      end
    end

    # Yields a connection checked out for the duration of the block.
    def with_connection(&)
      conn = checkout
      begin
        yield conn
      ensure
        release(conn)
      end
    end

    # Number of connections currently open (idle plus in use).
    def size : Int32
      @mutex.synchronize { @total }
    end

    def idle_size : Int32
      @mutex.synchronize { @idle.size }
    end

    def closed? : Bool
      @closed
    end

    # Closes idle connections now and in-use ones as they are returned.
    def close : Nil
      @closed = true
      idle = @mutex.synchronize do
        list = @idle.dup
        @idle.clear
        @total -= list.size
        list
      end
      idle.each(&.close)
    end

    private def checkout : Connection
      raise Error.new("pool is closed") if @closed
      deadline = Time.monotonic + @options.checkout_timeout
      loop do
        create = false
        @mutex.synchronize do
          while conn = @idle.pop?
            if conn.closed?
              @total -= 1
            else
              return conn
            end
          end
          if @total < @options.max_size
            @total += 1
            create = true
          end
        end

        if create
          begin
            return Connection.new(@info)
          rescue ex
            @mutex.synchronize { @total -= 1 }
            signal
            raise ex
          end
        end

        remaining = deadline - Time.monotonic
        if remaining <= Time::Span.zero
          raise PoolTimeout.new("no connection available within #{@options.checkout_timeout.total_seconds}s (max_pool_size=#{@options.max_size})")
        end
        select
        when @available.receive
        when timeout(remaining)
        end
      end
    end

    private def release(conn : Connection) : Nil
      discard = @closed || conn.closed? || conn.in_transaction? || conn.busy?
      @mutex.synchronize do
        if !discard && @idle.size < @options.max_idle
          @idle << conn
        else
          @total -= 1
          discard = true
        end
      end
      conn.close if discard
      signal
    end

    # Wakes one waiting checkout, without blocking if nobody waits.
    private def signal : Nil
      select
      when @available.send(nil)
      else
      end
    end
  end
end
