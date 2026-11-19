module Mjollnir
  struct ExecResult
    getter rows_affected : Int64

    def initialize(@rows_affected : Int64)
    end
  end

  # The query API, shared by `Pool`, `Connection` and `Transaction`.
  #
  # Including types provide `with_connection(&)`, which yields the
  # `Connection` to run on: a pool checks one out for the duration of the
  # call, a connection or transaction yields itself.
  #
  # Arguments are passed as a splat (`db.exec(sql, 1, "x")`), which keeps their
  # exact types known at compile time, or as an Array with `args:`.
  module Queries
    # Runs a statement that returns no rows (or whose rows you do not need).
    def exec(sql : String, *params) : ExecResult
      with_connection { |c| c.run_exec(sql, params) }
    end

    def exec(sql : String, *, args : Enumerable) : ExecResult
      with_connection { |c| c.run_exec(sql, args) }
    end

    # Runs a query and yields the `ResultSet`, closing it afterwards.
    def query(sql : String, *params, &)
      with_connection do |c|
        rs = c.run_query(sql, params)
        begin
          yield rs
        ensure
          rs.close
        end
      end
    end

    def query(sql : String, *, args : Enumerable, &)
      with_connection do |c|
        rs = c.run_query(sql, args)
        begin
          yield rs
        ensure
          rs.close
        end
      end
    end

    # First row as one type: `query_one(sql, 1, as: Int32)`.
    # Raises `NoResultsError` when there are no rows.
    def query_one(sql : String, *params, as type : T.class) : T forall T
      query(sql, *params) do |rs|
        raise NoResultsError.new("no results") unless rs.move_next
        rs.read(type)
      end
    end

    # First row as a Tuple of types: `query_one(sql, 1, as: {Int32, String})`.
    def query_one(sql : String, *params, as types : Tuple)
      query(sql, *params) do |rs|
        raise NoResultsError.new("no results") unless rs.move_next
        rs.read(*types)
      end
    end

    # Like `query_one` but returns nil when there are no rows.
    def query_one?(sql : String, *params, as type : T.class) : T? forall T
      query(sql, *params) do |rs|
        rs.move_next ? rs.read(type) : nil
      end
    end

    def query_one?(sql : String, *params, as types : Tuple)
      query(sql, *params) do |rs|
        rs.move_next ? rs.read(*types) : nil
      end
    end

    # All rows as an Array of one type or of Tuples.
    def query_all(sql : String, *params, as type : T.class) : Array(T) forall T
      query(sql, *params) do |rs|
        result = [] of T
        rs.each { result << rs.read(type) }
        result
      end
    end

    def query_all(sql : String, *params, as types : Tuple)
      query(sql, *params) do |rs|
        result = [] of typeof(rs.read(*types))
        rs.each { result << rs.read(*types) }
        result
      end
    end

    # First column of the first row, untyped. Raises `NoResultsError` when there are no rows.
    def scalar(sql : String, *params)
      query(sql, *params) do |rs|
        raise NoResultsError.new("no results") unless rs.move_next
        rs.read
      end
    end

    # `args:` forms of the helpers above, for dynamic argument lists.
    def query_one(sql : String, *, args : Enumerable, as type : T.class) : T forall T
      query(sql, args: args) do |rs|
        raise NoResultsError.new("no results") unless rs.move_next
        rs.read(type)
      end
    end

    def query_one(sql : String, *, args : Enumerable, as types : Tuple)
      query(sql, args: args) do |rs|
        raise NoResultsError.new("no results") unless rs.move_next
        rs.read(*types)
      end
    end

    def query_one?(sql : String, *, args : Enumerable, as type : T.class) : T? forall T
      query(sql, args: args) { |rs| rs.move_next ? rs.read(type) : nil }
    end

    def query_all(sql : String, *, args : Enumerable, as type : T.class) : Array(T) forall T
      query(sql, args: args) do |rs|
        result = [] of T
        rs.each { result << rs.read(type) }
        result
      end
    end

    def query_all(sql : String, *, args : Enumerable, as types : Tuple)
      query(sql, args: args) do |rs|
        result = [] of typeof(rs.read(*types))
        rs.each { result << rs.read(*types) }
        result
      end
    end

    def scalar(sql : String, *, args : Enumerable)
      query(sql, args: args) do |rs|
        raise NoResultsError.new("no results") unless rs.move_next
        rs.read
      end
    end

    # Runs one or more semicolon-separated statements with no parameters and
    # no result rows, in one round trip (simple query protocol).
    def exec_all(sql : String) : Nil
      with_connection { |c| c.run_exec_all(sql) }
    end

    # Executes *sql* once per element of *rows* (each element an Enumerable of
    # arguments), pipelined in chunks of *chunk_size* rows with one write and
    # one round trip per chunk. Each chunk is atomic (one implicit
    # transaction); call inside `transaction` to make the whole batch atomic.
    def exec_many(sql : String, rows : Enumerable, chunk_size : Int32 = 500) : ExecResult
      with_connection { |c| c.run_exec_many(sql, rows, chunk_size) }
    end

    # Runs the block in a transaction: COMMIT when it returns, ROLLBACK when
    # it raises (the exception is re-raised) or calls `tx.rollback` (then
    # `transaction` returns nil). Nested calls on the yielded `Transaction`
    # use savepoints.
    def transaction(& : Transaction -> T) : T? forall T
      with_connection { |c| c.run_transaction { |tx| yield tx } }
    end
  end

  # Handle passed to `transaction` blocks. Run queries on it (not on the pool)
  # so they join the transaction.
  class Transaction
    include Queries

    getter connection : Connection

    def initialize(@connection : Connection)
    end

    def with_connection(&)
      yield @connection
    end

    # Rolls the transaction back and leaves the `transaction` block.
    def rollback : NoReturn
      raise Rollback.new
    end
  end
end
