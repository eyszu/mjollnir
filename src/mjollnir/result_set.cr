module Mjollnir
  # Streams rows straight out of the receive buffer.
  #
  # `move_next` reads one DataRow message; `read` then walks its fields with
  # a pointer, decoding on demand. Skipping columns costs nothing (the row is
  # already in memory) and a row that is only partly read needs no cleanup.
  #
  # Typed reads (`rs.read(Int32)`, `rs.read(String?)`, `rs.read(Array(Int64))`,
  # `rs.read(Int32, String)`, `rs.read(MyJsonSerializableType)`...) decode
  # directly to the requested type without going through the untyped `Value`
  # union.
  #
  # A result set holds its connection until it is finished or closed; run
  # nothing else on that connection in between (the driver raises if you try).
  # `query` with a block closes it for you.
  class ResultSet
    getter rows_affected : Int64 = 0_i64

    @cur : Pointer(UInt8) = Pointer(UInt8).null
    @col : Int32 = 0
    @ncols : Int32
    @done : Bool = false
    @closed : Bool = false

    def initialize(@conn : Connection, @wire : Wire, @fields : Array(Field))
      @ncols = @fields.size
    end

    # Advances to the next row. Returns false when there are no more.
    def move_next : Bool
      return false if @done
      case @wire.read_message
      when 'D'.ord
        @cur = @wire.msg_ptr + 2 # skip the Int16 column count
        @col = 0
        true
      when 'C'.ord
        @rows_affected = Wire.rows_from_tag(@wire.msg_ptr, @wire.msg_len)
        finish
        false
      when 'I'.ord # EmptyQueryResponse
        finish
        false
      when 'E'.ord
        @done = true
        @conn.result_done(self)
        @wire.fail(false)
      else
        @done = true
        @conn.broken!
        raise ProtocolError.new("unexpected message #{@wire.msg_ptr.value.chr.inspect} in result stream")
      end
    rescue ex : IO::Error | OpenSSL::SSL::Error
      @done = true
      @conn.broken!
      raise ConnectionLost.new(ex.message, cause: ex)
    end

    # Iterates over all remaining rows.
    def each(& : ->) : Nil
      while move_next
        yield
      end
    end

    def column_count : Int32
      @ncols
    end

    def column_name(index : Int32) : String
      @fields[index].name
    end

    def column_names : Array(String)
      @fields.map(&.name)
    end

    # The PostgreSQL type OID of a column.
    def column_oid(index : Int32) : UInt32
      @fields[index].oid
    end

    # Index of the column the next `read` will return.
    def next_column_index : Int32
      @col
    end

    def closed? : Bool
      @closed
    end

    # Discards any unread rows and releases the connection. Safe to call twice.
    def close : Nil
      return if @closed
      @closed = true
      unless @done
        @done = true
        begin
          @wire.wait_ready # drain rows nobody read
        rescue ex : IO::Error | OpenSSL::SSL::Error
          @conn.broken!
          raise ConnectionLost.new(ex.message, cause: ex)
        end
      end
      @conn.result_done(self)
    end

    private def finish : Nil
      @done = true
      @wire.expect_ready
      @conn.result_done(self)
    end

    @[AlwaysInline]
    private def next_field : {Pointer(UInt8), Int32, Kind}
      raise Error.new("no more columns to read (#{@ncols} columns)") if @col >= @ncols
      len = BE.i32(@cur)
      p = @cur + 4
      @cur = p + (len < 0 ? 0 : len)
      kind = @fields.unsafe_fetch(@col).kind
      @col += 1
      {p, len, kind}
    end

    private def current_kind : Kind
      @fields[@col - 1].kind
    end

    # *kind* nil means the value was NULL.
    private def mismatch(expected : T.class, kind : Kind?) : NoReturn forall T
      index = @col - 1
      what = kind ? "#{kind} (oid #{@fields[index].oid})" : "NULL"
      raise TypeMismatchError.new(
        "column #{index} (#{column_name(index)}) is #{what}, which cannot be read as #{T}")
    end

    # Untyped read.
    def read
      p, len, kind = next_field
      return nil if len < 0
      Decode.value(kind, p, len)
    end

    # Reads several columns at once and returns them as a Tuple.
    def read(*types : Class)
      internal_read(*types)
    end

    # Reads named columns into a NamedTuple: `rs.read(id: Int32, name: String)`.
    def read(**types : Class)
      internal_read(**types)
    end

    private def internal_read(*types : *T) forall T
      {% begin %}
        Tuple.new(
          {% for type in T %}
            read({{type.instance}}),
          {% end %}
        )
      {% end %}
    end

    private def internal_read(**types : **T) forall T
      {% begin %}
        NamedTuple.new(
          {% for name, type in T %}
            {{name}}: read({{type.instance}}),
          {% end %}
        )
      {% end %}
    end

    macro typed_read(type, expr)
      def read(t : {{type}}.class) : {{type}}
        p, len, kind = next_field
        mismatch(t, nil) if len < 0
        v = {{expr}}
        v.nil? ? mismatch(t, kind) : v
      end

      def read(t : {{type}}?.class) : {{type}}?
        p, len, kind = next_field
        return nil if len < 0
        v = {{expr}}
        v.nil? ? mismatch({{type}}, kind) : v
      end
    end

    typed_read Bool, Decode.bool(kind, p)
    typed_read Int16, Decode.int16(kind, p)
    typed_read Int32, Decode.int32(kind, p)
    typed_read Int64, Decode.int64(kind, p)
    typed_read Float32, Decode.float32(kind, p)
    typed_read Float64, Decode.float64(kind, p)
    typed_read String, Decode.string(kind, p, len)
    typed_read Bytes, Decode.bytes(kind, p, len)
    typed_read Time, Decode.time(kind, p)
    typed_read UUID, Decode.uuid(kind, p)
    typed_read Numeric, Decode.numeric(kind, p, len)

    def read(t : JSON::Any.class) : JSON::Any
      p, len, kind = next_field
      mismatch(t, nil) if len < 0
      Decode.json_any(Decode.json_text(kind, p, len) || mismatch(t, kind))
    end

    def read(t : JSON::Any?.class) : JSON::Any?
      p, len, kind = next_field
      return nil if len < 0
      Decode.json_any(Decode.json_text(kind, p, len) || mismatch(JSON::Any, kind))
    end

    # A pull parser over the column's JSON text.
    def read(t : JSON::PullParser.class) : JSON::PullParser
      p, len, kind = next_field
      mismatch(t, nil) if len < 0
      JSON::PullParser.new(Decode.json_text(kind, p, len) || mismatch(t, kind))
    end

    def read(t : Array(T).class) : Array(T) forall T
      p, len, kind = next_field
      mismatch(t, nil) if len < 0
      mismatch(t, kind) unless kind.array?
      Decode.array(t, p, len)
    end

    def read(t : Array(T)?.class) : Array(T)? forall T
      p, len, kind = next_field
      return nil if len < 0
      mismatch(Array(T), kind) unless kind.array?
      Decode.array(Array(T), p, len)
    end

    # Everything else:
    #
    # * types including `JSON::Serializable` are parsed from a json/jsonb column
    #   with no intermediate `JSON::Any`;
    # * enums are read from text (by name) or integer columns (by value);
    # * classes defining `self.from_rs(rs : Mjollnir::ResultSet)` build themselves
    #   from the following columns;
    # * any other type is read untyped and checked with `is_a?`.
    def read(type : T.class) : T forall T
      {% begin %}
        {% base = T.union_types.reject { |u| u == Nil }.first %}
        {% if base < JSON::Serializable %}
          p, len, kind = next_field
          if len < 0
            {% if T.nilable? %}
              return nil
            {% else %}
              mismatch(type, nil)
            {% end %}
          end
          text = Decode.json_text(kind, p, len) || mismatch(type, kind)
          {{base}}.new(JSON::PullParser.new(text))
        {% elsif base < Enum %}
          case value = read
          when Nil
            {% if T.nilable? %}
              nil
            {% else %}
              mismatch(type, nil)
            {% end %}
          when String then {{base}}.parse(value)
          when Int    then {{base}}.from_value(value)
          else             mismatch(type, current_kind)
          end
        {% elsif base < Tuple %}
          Tuple.new(
            {% for t in base.type_vars %}
              read({{t}}),
            {% end %}
          )
        {% elsif base.class.has_method?(:from_rs) %}
          {{base}}.from_rs(self)
        {% else %}
          v = read
          if v.is_a?(T)
            v
          elsif v.nil?
            mismatch(type, nil)
          else
            mismatch(type, current_kind)
          end
        {% end %}
      {% end %}
    end
  end
end
