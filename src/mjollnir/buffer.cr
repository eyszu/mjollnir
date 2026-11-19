module Mjollnir
  # Big-endian primitives read straight from a pointer. The shift/or form is
  # recognised by LLVM and compiled to a single load plus bswap on x86-64
  # and aarch64, while staying correct for unaligned addresses.
  module BE
    @[AlwaysInline]
    def self.i16(p : Pointer(UInt8)) : Int16
      ((p[0].to_u16 << 8) | p[1].to_u16).to_i16!
    end

    @[AlwaysInline]
    def self.i32(p : Pointer(UInt8)) : Int32
      ((p[0].to_u32 << 24) | (p[1].to_u32 << 16) | (p[2].to_u32 << 8) | p[3].to_u32).to_i32!
    end

    @[AlwaysInline]
    def self.i64(p : Pointer(UInt8)) : Int64
      ((p[0].to_u64 << 56) | (p[1].to_u64 << 48) | (p[2].to_u64 << 40) | (p[3].to_u64 << 32) |
        (p[4].to_u64 << 24) | (p[5].to_u64 << 16) | (p[6].to_u64 << 8) | p[7].to_u64).to_i64!
    end

    @[AlwaysInline]
    def self.put_i16(p : Pointer(UInt8), v : Int16) : Nil
      u = v.to_u16!
      p[0] = (u >> 8).to_u8!
      p[1] = u.to_u8!
    end

    @[AlwaysInline]
    def self.put_i32(p : Pointer(UInt8), v : Int32) : Nil
      u = v.to_u32!
      p[0] = (u >> 24).to_u8!
      p[1] = (u >> 16).to_u8!
      p[2] = (u >> 8).to_u8!
      p[3] = u.to_u8!
    end

    @[AlwaysInline]
    def self.put_i64(p : Pointer(UInt8), v : Int64) : Nil
      u = v.to_u64!
      p[0] = (u >> 56).to_u8!
      p[1] = (u >> 48).to_u8!
      p[2] = (u >> 40).to_u8!
      p[3] = (u >> 32).to_u8!
      p[4] = (u >> 24).to_u8!
      p[5] = (u >> 16).to_u8!
      p[6] = (u >> 8).to_u8!
      p[7] = u.to_u8!
    end
  end

  # Growable, reusable output buffer. Frontend messages are assembled here
  # and handed to the socket with a single `write`, so a whole
  # Bind/Execute/Sync pipeline costs one syscall.
  class WriteBuffer
    getter size : Int32 = 0
    @buf : Pointer(UInt8)
    @cap : Int32

    def initialize(@cap : Int32 = 16 * 1024)
      @buf = Pointer(UInt8).malloc(@cap)
    end

    def clear : Nil
      @size = 0
    end

    # Discards everything written after offset *n* (used to roll back a partial value).
    def truncate(n : Int32) : Nil
      @size = n
    end

    def to_slice : Bytes
      Slice.new(@buf, @size)
    end

    @[AlwaysInline]
    def reserve(n : Int32) : Nil
      grow(n) if @size + n > @cap
    end

    private def grow(n : Int32) : Nil
      new_cap = @cap
      while new_cap < @size + n
        new_cap *= 2
      end
      @buf = @buf.realloc(new_cap)
      @cap = new_cap
    end

    @[AlwaysInline]
    def u8(v : UInt8) : Nil
      reserve(1)
      @buf[@size] = v
      @size += 1
    end

    @[AlwaysInline]
    def i16(v : Int16) : Nil
      reserve(2)
      BE.put_i16(@buf + @size, v)
      @size += 2
    end

    @[AlwaysInline]
    def i32(v : Int32) : Nil
      reserve(4)
      BE.put_i32(@buf + @size, v)
      @size += 4
    end

    @[AlwaysInline]
    def i64(v : Int64) : Nil
      reserve(8)
      BE.put_i64(@buf + @size, v)
      @size += 8
    end

    def raw(src : Pointer(UInt8), len : Int32) : Nil
      reserve(len)
      (@buf + @size).copy_from(src, len)
      @size += len
    end

    def raw(src : Bytes) : Nil
      raw(src.to_unsafe, src.size)
    end

    # Writes the bytes of *s* followed by a NUL.
    def cstr(s : String) : Nil
      reserve(s.bytesize + 1)
      (@buf + @size).copy_from(s.to_unsafe, s.bytesize)
      @size += s.bytesize
      @buf[@size] = 0_u8
      @size += 1
    end

    # Writes a length-prefixed value (Int32 length, then the bytes).
    def value(s : String) : Nil
      i32(s.bytesize)
      reserve(s.bytesize)
      (@buf + @size).copy_from(s.to_unsafe, s.bytesize)
      @size += s.bytesize
    end

    # Reserves *n* zeroed bytes and returns the offset of the first.
    def skip(n : Int32) : Int32
      reserve(n)
      pos = @size
      @size += n
      pos
    end

    def patch_i16(pos : Int32, v : Int16) : Nil
      BE.put_i16(@buf + pos, v)
    end

    def patch_i32(pos : Int32, v : Int32) : Nil
      BE.put_i32(@buf + pos, v)
    end

    # Starts a frontend message: writes the type byte and a length
    # placeholder. Returns the offset to hand to `finish_message`.
    @[AlwaysInline]
    def start_message(type : Char) : Int32
      u8(type.ord.to_u8)
      pos = @size
      i32(0)
      pos
    end

    @[AlwaysInline]
    def finish_message(pos : Int32) : Nil
      BE.put_i32(@buf + pos, @size - pos)
    end
  end

  # Cursor over the body of one backend message. A struct, so the
  # non-hot-path messages (RowDescription, auth, errors) cost no allocation.
  struct MsgReader
    getter pos : Int32 = 0

    def initialize(@ptr : Pointer(UInt8), @len : Int32)
    end

    def u8 : UInt8
      v = @ptr[@pos]
      @pos += 1
      v
    end

    def i16 : Int16
      v = BE.i16(@ptr + @pos)
      @pos += 2
      v
    end

    def i32 : Int32
      v = BE.i32(@ptr + @pos)
      @pos += 4
      v
    end

    def cstr : String
      start = @pos
      while @pos < @len && @ptr[@pos] != 0
        @pos += 1
      end
      s = String.new(@ptr + start, @pos - start)
      @pos += 1
      s
    end

    def rest : Bytes
      Slice.new(@ptr + @pos, @len - @pos)
    end

    def remaining : Int32
      @len - @pos
    end
  end
end
