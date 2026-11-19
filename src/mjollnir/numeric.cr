module Mjollnir
  # A PostgreSQL `numeric`, kept in the server's base-10000 digit form so no
  # precision is lost. Convert with `to_s` (exact) or `to_f64` (rounded).
  struct Numeric
    NAN     = 0xC000_u16
    POS_INF = 0xD000_u16
    NEG_INF = 0xF000_u16

    getter weight : Int16
    getter sign : UInt16
    getter dscale : Int16
    getter digits : Array(Int16)

    def initialize(@weight, @sign, @dscale, @digits)
    end

    # Decodes the binary representation (header + base-10000 digits).
    def self.decode(ptr : Pointer(UInt8), len : Int32) : Numeric
      ndigits = BE.i16(ptr)
      weight = BE.i16(ptr + 2)
      sign = BE.i16(ptr + 4).to_u16!
      dscale = BE.i16(ptr + 6)
      digits = Array(Int16).new(ndigits.to_i)
      ndigits.times { |i| digits << BE.i16(ptr + 8 + i * 2) }
      new(weight, sign, dscale, digits)
    end

    def nan? : Bool
      @sign == NAN
    end

    def infinite? : Bool
      @sign == POS_INF || @sign == NEG_INF
    end

    def negative? : Bool
      @sign == 0x4000_u16 || @sign == NEG_INF
    end

    # Exact decimal text, identical to what the server prints.
    def to_s(io : IO) : Nil
      case @sign
      when NAN     then return io << "NaN"
      when POS_INF then return io << "Infinity"
      when NEG_INF then return io << "-Infinity"
      end
      io << '-' if negative?

      # integer part: base-10000 digits 0..weight
      if @weight < 0
        io << '0'
      else
        (0..@weight).each do |i|
          d = i < @digits.size ? @digits[i].to_i : 0
          if i == 0
            io << d
          else
            io << '0' if d < 1000
            io << '0' if d < 100
            io << '0' if d < 10
            io << d
          end
        end
      end

      # fractional part, exactly dscale decimal digits
      if @dscale > 0
        io << '.'
        written = 0
        # groups between the decimal point and the first stored digit
        gi = @weight + 1
        while written < @dscale
          d = gi >= 0 && gi < @digits.size ? @digits[gi].to_i : 0
          group = d.to_s.rjust(4, '0')
          take = Math.min(4, @dscale - written)
          io << group[0, take]
          written += take
          gi += 1
        end
      end
    end

    def to_f64 : Float64
      case @sign
      when NAN     then Float64::NAN
      when POS_INF then Float64::INFINITY
      when NEG_INF then -Float64::INFINITY
      else              to_s.to_f64
      end
    end
  end
end
