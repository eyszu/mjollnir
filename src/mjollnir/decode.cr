require "uuid"
require "json"

module Mjollnir
  # Values of a one-dimensional array read without a static element type.
  alias ArrayValue = Nil | Bool | Int16 | Int32 | Int64 | Float32 | Float64 | String | UUID

  # Everything an untyped `ResultSet#read` can return.
  alias Value = Nil | Bool | Int16 | Int32 | Int64 | Float32 | Float64 | String | Bytes |
                Time | UUID | JSON::Any | Numeric | Array(ArrayValue)

  # Binary decoders. Every method reads straight from the receive buffer;
  # the only allocations are the values handed back to the caller.
  module Decode
    # Seconds between 0001-01-01 (Crystal's Time epoch) and 2000-01-01 (PostgreSQL's).
    PG_EPOCH_SECONDS = 63082281600_i64
    MICROS           =   1_000_000_i64

    @[AlwaysInline]
    def self.timestamp(micros : Int64) : Time
      if micros == Int64::MAX || micros == Int64::MIN
        raise Error.new("infinite timestamps cannot be represented as Time; cast to text in SQL")
      end
      secs = micros // MICROS
      us = micros - secs * MICROS
      Time.utc(seconds: PG_EPOCH_SECONDS + secs, nanoseconds: (us * 1000).to_i32)
    end

    @[AlwaysInline]
    def self.date(days : Int32) : Time
      if days == Int32::MAX || days == Int32::MIN
        raise Error.new("infinite dates cannot be represented as Time; cast to text in SQL")
      end
      Time.utc(seconds: PG_EPOCH_SECONDS + days.to_i64 * 86400_i64, nanoseconds: 0)
    end

    # --- scalar decoders keyed by column kind; nil means "kind does not fit" ---

    @[AlwaysInline]
    def self.bool(kind : Kind, p : Pointer(UInt8)) : Bool?
      p[0] != 0 if kind.bool?
    end

    @[AlwaysInline]
    def self.int16(kind : Kind, p : Pointer(UInt8)) : Int16?
      BE.i16(p) if kind.int2?
    end

    @[AlwaysInline]
    def self.int32(kind : Kind, p : Pointer(UInt8)) : Int32?
      case kind
      when .int4? then BE.i32(p)
      when .int2? then BE.i16(p).to_i32
      end
    end

    @[AlwaysInline]
    def self.int64(kind : Kind, p : Pointer(UInt8)) : Int64?
      case kind
      when .int8? then BE.i64(p)
      when .int4? then BE.i32(p).to_i64
      when .int2? then BE.i16(p).to_i64
      when .oid?  then BE.i32(p).to_u32!.to_i64
      end
    end

    @[AlwaysInline]
    def self.float32(kind : Kind, p : Pointer(UInt8)) : Float32?
      BE.i32(p).unsafe_as(Float32) if kind.float4?
    end

    @[AlwaysInline]
    def self.float64(kind : Kind, p : Pointer(UInt8)) : Float64?
      case kind
      when .float8? then BE.i64(p).unsafe_as(Float64)
      when .float4? then BE.i32(p).unsafe_as(Float32).to_f64
      end
    end

    @[AlwaysInline]
    def self.string(kind : Kind, p : Pointer(UInt8), len : Int32) : String?
      case kind
      when .text?, .text_fmt?, .json? then String.new(p, len)
      when .jsonb?                    then String.new(p + 1, len - 1)
      end
    end

    @[AlwaysInline]
    def self.bytes(kind : Kind, p : Pointer(UInt8), len : Int32) : Bytes?
      if kind.bytea?
        b = Bytes.new(len)
        b.to_unsafe.copy_from(p, len)
        b
      end
    end

    @[AlwaysInline]
    def self.time(kind : Kind, p : Pointer(UInt8)) : Time?
      case kind
      when .timestamp?, .timestamptz? then timestamp(BE.i64(p))
      when .date?                     then date(BE.i32(p))
      end
    end

    @[AlwaysInline]
    def self.uuid(kind : Kind, p : Pointer(UInt8)) : UUID?
      UUID.new(Slice.new(p, 16)) if kind.uuid?
    end

    def self.numeric(kind : Kind, p : Pointer(UInt8), len : Int32) : Numeric?
      Numeric.decode(p, len) if kind.numeric?
    end

    # The JSON text of a json/jsonb column as a String. Parsing from a String
    # uses Crystal's pointer-based lexer, which is markedly faster than the
    # IO-based one, and the one memcpy it costs is cheaper than that gap.
    def self.json_text(kind : Kind, p : Pointer(UInt8), len : Int32) : String?
      case kind
      when .json?
        String.new(p, len)
      when .jsonb?
        raise Error.new("unsupported jsonb version #{p[0]}") unless p[0] == 1
        String.new(p + 1, len - 1)
      end
    end

    def self.json_any(text : String) : JSON::Any
      JSON::Any.new(JSON::PullParser.new(text))
    end

    # --- arrays -------------------------------------------------------------

    # Reads the header of a 1-D binary array. Returns {element oid, count, offset of first element}.
    def self.array_header(p : Pointer(UInt8), len : Int32) : {UInt32, Int32, Int32}
      ndim = BE.i32(p)
      return {BE.i32(p + 8).to_u32!, 0, 12} if ndim == 0
      raise Error.new("multi-dimensional arrays are not supported (#{ndim} dimensions)") if ndim != 1
      # layout: ndim, has-null flag, element oid, then {size, lower bound} per dimension
      {BE.i32(p + 8).to_u32!, BE.i32(p + 12), 20}
    end

    def self.array_elem(oid : UInt32, p : Pointer(UInt8), len : Int32) : ArrayValue
      case oid
      when OID::BOOL                            then p[0] != 0
      when OID::INT2                            then BE.i16(p)
      when OID::INT4                            then BE.i32(p)
      when OID::INT8                            then BE.i64(p)
      when OID::FLOAT4                          then BE.i32(p).unsafe_as(Float32)
      when OID::FLOAT8                          then BE.i64(p).unsafe_as(Float64)
      when OID::TEXT, OID::VARCHAR, OID::BPCHAR then String.new(p, len)
      when OID::UUID                            then UUID.new(Slice.new(p, 16))
      else
        raise Error.new("unsupported array element type #{oid}")
      end
    end

    # Untyped array read.
    def self.array(p : Pointer(UInt8), len : Int32) : Array(ArrayValue)
      elem_oid, n, off = array_header(p, len)
      out = Array(ArrayValue).new(n)
      cur = p + off
      n.times do
        l = BE.i32(cur)
        cur += 4
        if l < 0
          out << nil
        else
          out << array_elem(elem_oid, cur, l)
          cur += l
        end
      end
      out
    end

    # Typed element decoders for `read(Array(T))`.
    def self.elem(t : Bool.class, oid : UInt32, p : Pointer(UInt8), len : Int32) : Bool
      oid == OID::BOOL ? p[0] != 0 : elem_mismatch("Bool", oid)
    end

    def self.elem(t : Int16.class, oid : UInt32, p : Pointer(UInt8), len : Int32) : Int16
      oid == OID::INT2 ? BE.i16(p) : elem_mismatch("Int16", oid)
    end

    def self.elem(t : Int32.class, oid : UInt32, p : Pointer(UInt8), len : Int32) : Int32
      case oid
      when OID::INT4 then BE.i32(p)
      when OID::INT2 then BE.i16(p).to_i32
      else                elem_mismatch("Int32", oid)
      end
    end

    def self.elem(t : Int64.class, oid : UInt32, p : Pointer(UInt8), len : Int32) : Int64
      case oid
      when OID::INT8 then BE.i64(p)
      when OID::INT4 then BE.i32(p).to_i64
      when OID::INT2 then BE.i16(p).to_i64
      else                elem_mismatch("Int64", oid)
      end
    end

    def self.elem(t : Float32.class, oid : UInt32, p : Pointer(UInt8), len : Int32) : Float32
      oid == OID::FLOAT4 ? BE.i32(p).unsafe_as(Float32) : elem_mismatch("Float32", oid)
    end

    def self.elem(t : Float64.class, oid : UInt32, p : Pointer(UInt8), len : Int32) : Float64
      case oid
      when OID::FLOAT8 then BE.i64(p).unsafe_as(Float64)
      when OID::FLOAT4 then BE.i32(p).unsafe_as(Float32).to_f64
      else                  elem_mismatch("Float64", oid)
      end
    end

    def self.elem(t : String.class, oid : UInt32, p : Pointer(UInt8), len : Int32) : String
      case oid
      when OID::TEXT, OID::VARCHAR, OID::BPCHAR then String.new(p, len)
      else                                           elem_mismatch("String", oid)
      end
    end

    def self.elem(t : UUID.class, oid : UInt32, p : Pointer(UInt8), len : Int32) : UUID
      oid == OID::UUID ? UUID.new(Slice.new(p, 16)) : elem_mismatch("UUID", oid)
    end

    def self.elem_mismatch(expected : String, oid : UInt32) : NoReturn
      raise Error.new("array element type mismatch: expected #{expected}, got oid #{oid}")
    end

    # Typed array read. Nilable element types (`Array(Int32?)`) accept NULL elements.
    def self.array(type : Array(T).class, p : Pointer(UInt8), len : Int32) : Array(T) forall T
      {% begin %}
      {% base = T.union_types.reject { |u| u == Nil }.first %}
      elem_oid, n, off = array_header(p, len)
      out = Array(T).new(n)
      cur = p + off
      n.times do
        l = BE.i32(cur)
        cur += 4
        if l < 0
          {% if T.nilable? %}
            out << nil
          {% else %}
            raise Error.new("unexpected NULL element in array of {{T}}")
          {% end %}
        else
          out << elem({{base}}, elem_oid, cur, l)
          cur += l
        end
      end
      out
      {% end %}
    end

    # Untyped decode of one field. *oid* is only consulted for arrays.
    def self.value(kind : Kind, p : Pointer(UInt8), len : Int32) : Value
      case kind
      in .bool?     then p[0] != 0
      in .int2?     then BE.i16(p)
      in .int4?     then BE.i32(p)
      in .int8?     then BE.i64(p)
      in .oid?      then BE.i32(p).to_u32!.to_i64
      in .float4?   then BE.i32(p).unsafe_as(Float32)
      in .float8?   then BE.i64(p).unsafe_as(Float64)
      in .text?     then String.new(p, len)
      in .text_fmt? then String.new(p, len)
      in .bytea?
        b = Bytes.new(len)
        b.to_unsafe.copy_from(p, len)
        b
      in .json?, .jsonb?            then json_any(json_text(kind, p, len).not_nil!)
      in .uuid?                     then UUID.new(Slice.new(p, 16))
      in .date?                     then date(BE.i32(p))
      in .timestamp?, .timestamptz? then timestamp(BE.i64(p))
      in .numeric?                  then Numeric.decode(p, len)
      in .array?                    then array(p, len)
      end
    end
  end
end
