module Mjollnir
  # One SQL string prepared on one connection. Internal: users go through
  # `Connection`, `Pool` and `Transaction`, which look statements up in a cache.
  #
  # Prepared mode: the first execution sends Parse + Describe, learns the
  # parameter and column types from the server, and keeps the statement on
  # the server under a short generated name. Every later execution sends only
  # Bind + Execute + Sync in a single write, with the parameters encoded for
  # the types the server declared and the columns requested in binary.
  #
  # Unnamed mode re-prepares the unnamed statement on every execution (two
  # round trips) and leaves no server-side state behind.
  class Statement
    getter sql : String
    getter fields : Array(Field) = [] of Field

    @name : String = ""
    @unnamed : Bool
    @prepared : Bool = false
    @param_oids : Array(UInt32) = [] of UInt32
    @result_tail : Bytes = Bytes.empty

    def initialize(@sql : String, @unnamed : Bool)
    end

    # Queues the server-side Close for this statement (sent with the next request).
    def close(w : Wire) : Nil
      w.queue_close(@name) if @prepared && !@unnamed
      @prepared = false
    end

    # Makes sure the statement is prepared and runs Bind/Execute/Sync, leaving
    # the connection positioned just after BindComplete. *params* is a Tuple
    # (encoded with no runtime type dispatch) or any Enumerable.
    def run(w : Wire, params) : Nil
      attempts = 0
      loop do
        begin
          prepare(w) unless @prepared
          w.begin_request
          w.write_pending_closes
          write_bind(w.wbuf, params)
          w.wbuf.raw(Wire::EXECUTE_SYNC)
          w.flush
          w.expect('2')
          return
        rescue e : PGError
          # The server forgot the statement or its result shape changed under
          # us (DDL). Re-prepare once, but only outside a failed transaction.
          if (attempts += 1) == 1 && stale?(e) && !w.in_transaction?
            w.queue_close(@name) unless @unnamed || @name.empty?
            @prepared = false
            next
          end
          raise e
        end
      end
    end

    # Consumes the rest of the response, discarding rows. Returns rows affected.
    def drain(w : Wire) : Int64
      rows = 0_i64
      loop do
        case w.read_message.unsafe_chr
        when 'C'
          rows = Wire.rows_from_tag(w.msg_ptr, w.msg_len)
        when 'Z'
          w.status_from_message
          return rows
        when 'E'
          w.fail(false)
        end
      end
    end

    # Executes the statement once per element of *rows* (each an Enumerable of
    # arguments), pipelined in chunks of *chunk_size* with one Sync and one
    # write per chunk. Returns total rows affected.
    def exec_many(w : Wire, rows : Enumerable, chunk_size : Int32) : Int64
      prepare(w) unless @prepared
      total = 0_i64
      pending = 0
      w.begin_request
      w.write_pending_closes
      rows.each do |args|
        write_bind(w.wbuf, args)
        w.wbuf.raw(Wire::EXECUTE)
        pending += 1
        if pending >= chunk_size
          total += flush_chunk(w)
          pending = 0
          w.begin_request
        end
      end
      total += flush_chunk(w) if pending > 0
      total
    end

    # --- internals ---------------------------------------------------------

    private def flush_chunk(w : Wire) : Int64
      w.wbuf.raw(Wire::SYNC)
      w.flush
      total = 0_i64
      loop do
        case w.read_message.unsafe_chr
        when 'C'
          total += Wire.rows_from_tag(w.msg_ptr, w.msg_len)
        when 'Z'
          w.status_from_message
          return total
        when 'E'
          w.fail(false)
        end
      end
    end

    private def stale?(e : PGError) : Bool
      e.code == "26000" || (e.code == "0A000" && e.message.to_s.includes?("cached plan must not change result type"))
    end

    private def prepare(w : Wire) : Nil
      name = @unnamed ? "" : w.next_statement_name
      w.begin_request
      w.write_pending_closes
      b = w.wbuf
      pos = b.start_message('P')
      b.cstr(name)
      b.cstr(@sql)
      b.i16(0)
      b.finish_message(pos)
      pos = b.start_message('D')
      b.u8('S'.ord.to_u8)
      b.cstr(name)
      b.finish_message(pos)
      b.raw(Wire::FLUSH)
      w.flush

      w.expect('1', sync_on_error: true) # ParseComplete
      w.expect('t', sync_on_error: true) # ParameterDescription
      r = MsgReader.new(w.msg_ptr, w.msg_len)
      n = r.i16.to_i
      oids = Array(UInt32).new(n)
      n.times { oids << r.i32.to_u32! }

      fields = [] of Field
      case w.read_message.unsafe_chr
      when 'T'
        r = MsgReader.new(w.msg_ptr, w.msg_len)
        count = r.i16.to_i
        fields = Array(Field).new(count)
        count.times do
          field_name = r.cstr
          r.i32 # table oid
          r.i16 # attribute number
          oid = r.i32.to_u32!
          r.i16 # type size
          r.i32 # type modifier
          r.i16 # format code
          fields << Field.new(field_name, oid)
        end
      when 'n' # NoData
      when 'E'
        w.fail(true)
      else
        raise ProtocolError.new("expected RowDescription or NoData after Describe")
      end

      tail = Bytes.new(2 + 2 * fields.size)
      BE.put_i16(tail.to_unsafe, fields.size.to_i16)
      fields.each_with_index { |f, i| BE.put_i16(tail.to_unsafe + 2 + 2 * i, f.kind.format_code) }

      @name = name
      @param_oids = oids
      @fields = fields
      @result_tail = tail
      @prepared = true
    end

    private def arity_error(got : Int32) : NoReturn
      raise Error.new("wrong number of arguments: statement takes #{@param_oids.size}, got #{got}")
    end

    private def bind_begin(b : WriteBuffer, nparams : Int32) : {Int32, Int32}
      pos = b.start_message('B')
      b.u8(0_u8) # unnamed portal
      b.cstr(@name)
      b.i16(nparams.to_i16)
      fmt_pos = b.skip(2 * nparams)
      b.i16(nparams.to_i16)
      {pos, fmt_pos}
    end

    private def bind_end(b : WriteBuffer, pos : Int32) : Nil
      b.raw(@result_tail)
      b.finish_message(pos)
    end

    # Appends one Bind message (not followed by Execute) for a Tuple of
    # arguments. The loop is unrolled at compile time, so each argument is
    # encoded by code specialised for its exact Crystal type.
    private def write_bind(b : WriteBuffer, params : Tuple(*T)) : Nil forall T
      {% begin %}
        arity_error({{T.size}}) if @param_oids.size != {{T.size}}
        pos, fmt_pos = bind_begin(b, {{T.size}})
        {% for i in 0...T.size %}
          b.patch_i16(fmt_pos + {{2 * i}}, Encode.write(b, params[{{i}}], @param_oids.unsafe_fetch({{i}})))
        {% end %}
        bind_end(b, pos)
      {% end %}
    end

    # Same for any Enumerable of arguments (dynamic argument lists).
    private def write_bind(b : WriteBuffer, params : Enumerable) : Nil
      nparams = @param_oids.size
      arity_error(params.size) if params.size != nparams
      pos, fmt_pos = bind_begin(b, nparams)
      i = 0
      params.each do |arg|
        b.patch_i16(fmt_pos + 2 * i, Encode.write(b, arg, @param_oids.unsafe_fetch(i)))
        i += 1
      end
      bind_end(b, pos)
    end
  end
end
