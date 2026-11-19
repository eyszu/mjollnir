module Mjollnir
  # One PostgreSQL session. A connection serves one fiber at a time; for
  # concurrency use a `Pool`.
  class Connection
    include Queries

    getter wire : Wire
    getter info : ConnInfo

    # Aliases from a String object's address to its statement. A hit needs no
    # hashing at all: SQL passed as a string literal is the same object on
    # every call, so the integer-keyed lookup finds it directly. The entry
    # keeps the string alive, so an address can never be reused by another
    # string while it is in the table.
    @by_address : Hash(UInt64, {String, Statement}) = {} of UInt64 => {String, Statement}
    # Fallback for SQL built at run time: lookup by content.
    @by_sql : Hash(String, Statement) = {} of String => Statement
    @prepared : Bool
    @cache_size : Int32
    @active : ResultSet? = nil
    @tx_depth : Int32 = 0

    ALIAS_LIMIT = 256

    def self.new(url : String) : Connection
      new(ConnInfo.from_url(url))
    end

    def initialize(@info : ConnInfo)
      @prepared = @info.prepared && @info.statement_cache_size > 0
      @cache_size = @info.statement_cache_size
      @wire = begin
        Wire.new(@info)
      rescue ex : IO::Error | Socket::Error | OpenSSL::SSL::Error
        raise ConnectionRefused.new(ex.message, cause: ex)
      end
    end

    def with_connection(&)
      yield self
    end

    def server_version : String?
      @wire.params["server_version"]?
    end

    # Server run-time parameter reported at startup or after a SET (e.g. "TimeZone").
    def server_parameter(name : String) : String?
      @wire.params[name]?
    end

    # Process id of the backend serving this connection.
    def backend_pid : Int32
      @wire.backend_pid
    end

    # True inside BEGIN ... COMMIT (also true in a failed transaction).
    def in_transaction? : Bool
      @wire.in_transaction?
    end

    # True while a `ResultSet` from this connection is still open.
    def busy? : Bool
      !@active.nil?
    end

    def closed? : Bool
      @wire.closed?
    end

    # Callback for server notices and warnings.
    def on_notice(&block : PGError ->) : Nil
      @wire.notice_handler = block
    end

    def close : Nil
      @by_address.clear
      @by_sql.clear
      @wire.close
    end

    # --- internals used by Queries, ResultSet and Pool ------------------------------

    # :nodoc:
    def broken! : Nil
      @wire.close
    end

    # :nodoc:
    def result_done(rs : ResultSet) : Nil
      @active = nil if @active.same?(rs)
    end

    # :nodoc:
    def run_exec(sql : String, params) : ExecResult
      guard do
        stmt = statement(sql)
        stmt.run(@wire, params)
        ExecResult.new(stmt.drain(@wire))
      end
    end

    # :nodoc:
    def run_query(sql : String, params) : ResultSet
      guard do
        stmt = statement(sql)
        stmt.run(@wire, params)
        rs = ResultSet.new(self, @wire, stmt.fields)
        @active = rs
        rs
      end
    end

    # :nodoc:
    def run_exec_all(sql : String) : Nil
      guard { @wire.simple_query(sql) }
    end

    # :nodoc:
    def run_exec_many(sql : String, rows : Enumerable, chunk_size : Int32) : ExecResult
      guard do
        stmt = statement(sql)
        ExecResult.new(stmt.exec_many(@wire, rows, chunk_size))
      end
    end

    # :nodoc:
    def run_transaction(& : Transaction -> T) : T? forall T
      depth = @tx_depth
      run_exec_all(depth == 0 ? "BEGIN" : "SAVEPOINT mj_sp#{depth}")
      @tx_depth = depth + 1
      begin
        result = yield Transaction.new(self)
      rescue Rollback
        finish_transaction(depth, false)
        return nil
      rescue ex
        begin
          finish_transaction(depth, false)
        rescue
        end
        raise ex
      end
      finish_transaction(depth, true)
      result
    end

    private def finish_transaction(depth : Int32, commit : Bool) : Nil
      @tx_depth = depth
      sql = if depth == 0
              commit ? "COMMIT" : "ROLLBACK"
            elsif commit
              "RELEASE SAVEPOINT mj_sp#{depth}"
            else
              "ROLLBACK TO SAVEPOINT mj_sp#{depth}; RELEASE SAVEPOINT mj_sp#{depth}"
            end
      run_exec_all(sql)
    end

    # Runs the block with the connection checked for readiness, turning
    # socket failures into ConnectionLost and closing the connection on them.
    private def guard(&)
      raise ConnectionLost.new("connection is closed") if @wire.closed?
      raise Error.new("connection is busy: finish or close the open result set first") if @active
      yield
    rescue ex : IO::Error | OpenSSL::SSL::Error
      @wire.close
      raise ConnectionLost.new(ex.message, cause: ex)
    rescue ex : ProtocolError
      @wire.close
      raise ex
    end

    # Finds or creates the statement for *sql*.
    private def statement(sql : String) : Statement
      return Statement.new(sql, true) unless @prepared

      address = sql.to_unsafe.address
      if hit = @by_address[address]?
        return hit[1] if hit[0].same?(sql)
      end

      if stmt = @by_sql[sql]?
        @by_address[address] = {sql, stmt} if @by_address.size < ALIAS_LIMIT
        return stmt
      end

      stmt = Statement.new(sql, false)
      @by_sql[sql] = stmt
      if @by_sql.size > @cache_size
        _, oldest = @by_sql.shift
        oldest.close(@wire)
        @by_address.clear
      end
      stmt
    end
  end
end
