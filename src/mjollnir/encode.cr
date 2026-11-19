require "uuid"
require "json"

module Mjollnir
  # Parameter encoders.
  #
  # Each argument is encoded according to the type the *server* reported for
  # that parameter (from Describe), not according to a guess made from the
  # Crystal type. Where a compact binary form exists for the (argument,
  # parameter type) pair it is used (format code 1); otherwise the value is
  # sent as text (format code 0) and the server's own input function parses
  # it. That is also why a `String` is accepted for a uuid, date, inet,
  # enum or any other column.
  module Encode
    UNIX_TO_PG_SECONDS = 946_684_800_i64 # 1970-01-01 to 2000-01-01

    # Writes one parameter (Int32 length, then the payload) and returns its format code.
    def self.write(w : WriteBuffer, arg, oid : UInt32) : Int16
      case arg
      when Nil
        w.i32(-1)
        0_i16
      when Int32, Int64
        int(w, arg.to_i64, oid)
      when String
        w.value(arg)
        0_i16
      when Bool
        if oid == OID::BOOL
          w.i32(1)
          w.u8(arg ? 1_u8 : 0_u8)
          1_i16
        else
          w.value(arg ? "t" : "f")
          0_i16
        end
      when Float64
        float64(w, arg, oid)
      when Int16, Int8, UInt8, UInt16, UInt32
        int(w, arg.to_i64, oid)
      when UInt64
        if arg <= Int64::MAX
          int(w, arg.to_i64, oid)
        else
          w.value(arg.to_s)
          0_i16
        end
      when Float32
        float32(w, arg, oid)
      when Bytes
        raise EncodeError.new("cannot send Bytes for a parameter of type oid #{oid}") unless oid == OID::BYTEA
        w.i32(arg.size)
        w.raw(arg)
        1_i16
      when Time
        time(w, arg, oid)
      when UUID
        if oid == OID::UUID
          w.i32(16)
          w.raw(arg.bytes.to_slice)
          1_i16
        else
          w.value(arg.to_s)
          0_i16
        end
      when JSON::Any, JSON::Serializable
        w.value(arg.to_json)
        0_i16
      when Numeric
        w.value(arg.to_s)
        0_i16
      when Array
        array(w, arg, oid)
      else
        w.value(arg.to_s)
        0_i16
      end
    end

    private def self.int(w : WriteBuffer, v : Int64, oid : UInt32) : Int16
      case oid
      when OID::INT4
        raise EncodeError.new("#{v} is out of range for int4") if v < Int32::MIN || v > Int32::MAX
        w.i32(4)
        w.i32(v.to_i32)
        1_i16
      when OID::INT8
        w.i32(8)
        w.i64(v)
        1_i16
      when OID::INT2
        raise EncodeError.new("#{v} is out of range for int2") if v < Int16::MIN || v > Int16::MAX
        w.i32(2)
        w.i16(v.to_i16)
        1_i16
      when OID::OID
        raise EncodeError.new("#{v} is out of range for oid") if v < 0 || v > UInt32::MAX
        w.i32(4)
        w.i32(v.to_u32.to_i32!)
        1_i16
      when OID::FLOAT8
        w.i32(8)
        w.i64(v.to_f64.unsafe_as(Int64))
        1_i16
      when OID::FLOAT4
        w.i32(4)
        w.i32(v.to_f32.unsafe_as(Int32))
        1_i16
      else
        w.value(v.to_s)
        0_i16
      end
    end

    private def self.float64(w : WriteBuffer, v : Float64, oid : UInt32) : Int16
      case oid
      when OID::FLOAT8
        w.i32(8)
        w.i64(v.unsafe_as(Int64))
        1_i16
      when OID::FLOAT4
        w.i32(4)
        w.i32(v.to_f32.unsafe_as(Int32))
        1_i16
      else
        w.value(v.to_s)
        0_i16
      end
    end

    private def self.float32(w : WriteBuffer, v : Float32, oid : UInt32) : Int16
      case oid
      when OID::FLOAT4
        w.i32(4)
        w.i32(v.unsafe_as(Int32))
        1_i16
      when OID::FLOAT8
        w.i32(8)
        w.i64(v.to_f64.unsafe_as(Int64))
        1_i16
      else
        w.value(v.to_s)
        0_i16
      end
    end

    private def self.time(w : WriteBuffer, t : Time, oid : UInt32) : Int16
      case oid
      when OID::TIMESTAMPTZ, OID::TIMESTAMP
        w.i32(8)
        w.i64((t.to_unix - UNIX_TO_PG_SECONDS) * 1_000_000_i64 + (t.nanosecond // 1000).to_i64)
        1_i16
      when OID::DATE
        w.i32(4)
        w.i32((t.to_unix // 86400 - 10957).to_i32)
        1_i16
      else
        w.value(t.to_utc.to_s("%F %T.%6N+00"))
        0_i16
      end
    end

    # --- arrays -----------------------------------------------------------------

    private def self.array(w : WriteBuffer, arr : Array, oid : UInt32) : Int16
      elem_oid = OID.array_element(oid)
      if elem_oid != 0
        start = w.size
        len_pos = w.skip(4)
        w.i32(1)                        # ndim
        w.i32(arr.any?(&.nil?) ? 1 : 0) # has-null flag
        w.i32(elem_oid.to_i32!)         # element type
        w.i32(arr.size)                 # dimension size
        w.i32(1)                        # lower bound
        ok = arr.all? { |v| array_elem(w, v, elem_oid) }
        if ok
          w.patch_i32(len_pos, w.size - len_pos - 4)
          return 1_i16
        end
        w.truncate(start)
      end
      w.value(array_literal(arr))
      0_i16
    end

    # Binary form of one array element; false when (value, element type) has no binary form.
    private def self.array_elem(w : WriteBuffer, v, elem_oid : UInt32) : Bool
      case v
      when Nil
        w.i32(-1)
        true
      when Int
        case elem_oid
        when OID::INT2
          return false if v < Int16::MIN || v > Int16::MAX
          w.i32(2)
          w.i16(v.to_i16)
          true
        when OID::INT4
          return false if v < Int32::MIN || v > Int32::MAX
          w.i32(4)
          w.i32(v.to_i32)
          true
        when OID::INT8
          return false if v > Int64::MAX
          w.i32(8)
          w.i64(v.to_i64)
          true
        else
          false
        end
      when Float64
        case elem_oid
        when OID::FLOAT8 then w.i32(8); w.i64(v.unsafe_as(Int64)); true
        when OID::FLOAT4 then w.i32(4); w.i32(v.to_f32.unsafe_as(Int32)); true
        else                  false
        end
      when Float32
        case elem_oid
        when OID::FLOAT4 then w.i32(4); w.i32(v.unsafe_as(Int32)); true
        when OID::FLOAT8 then w.i32(8); w.i64(v.to_f64.unsafe_as(Int64)); true
        else                  false
        end
      when Bool
        return false unless elem_oid == OID::BOOL
        w.i32(1)
        w.u8(v ? 1_u8 : 0_u8)
        true
      when String
        return false unless elem_oid == OID::TEXT || elem_oid == OID::VARCHAR || elem_oid == OID::BPCHAR
        w.value(v)
        true
      when UUID
        return false unless elem_oid == OID::UUID
        w.i32(16)
        w.raw(v.bytes.to_slice)
        true
      else
        false
      end
    end

    # PostgreSQL array literal ("{1,2,NULL,\"a b\"}") for the text-format fallback.
    def self.array_literal(arr : Array) : String
      String.build do |io|
        io << '{'
        arr.each_with_index do |v, i|
          io << ',' if i > 0
          case v
          when Nil    then io << "NULL"
          when Array  then io << array_literal(v)
          when Bool   then io << (v ? 't' : 'f')
          when Number then io << v
          else
            io << '"'
            v.to_s.each_char do |c|
              io << '\\' if c == '"' || c == '\\'
              io << c
            end
            io << '"'
          end
        end
        io << '}'
      end
    end
  end
end
