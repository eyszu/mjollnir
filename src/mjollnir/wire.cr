require "socket"
require "openssl"
require "digest/md5"

module Mjollnir
  # The PostgreSQL frontend/backend protocol v3 over one socket.
  #
  # Reading is zero-copy: the socket is read in large chunks into one buffer
  # and backend messages are parsed in place. `read_message` returns the
  # message type and exposes the body as `msg_ptr`/`msg_len`; the body is
  # only valid until the next `read_message` call, which is exactly the
  # lifetime a DataRow needs.
  #
  # Writing is batched: frontend messages are assembled in `wbuf` and sent
  # with one `write` in `flush`.
  class Wire
    READ_BUFFER = 128 * 1024
    MIN_READ    = 8 * 1024

    SSL_REQUEST = Bytes[0, 0, 0, 8, 0x04, 0xd2, 0x16, 0x2f]

    # Execute(portal "", max_rows 0) followed by Sync, pre-serialised.
    EXECUTE_SYNC = Bytes['E'.ord, 0, 0, 0, 9, 0, 0, 0, 0, 0, 'S'.ord, 0, 0, 0, 4]
    # Execute only (used inside multi-statement pipelines).
    EXECUTE = Bytes['E'.ord, 0, 0, 0, 9, 0, 0, 0, 0, 0]
    SYNC    = Bytes['S'.ord, 0, 0, 0, 4]
    FLUSH   = Bytes['H'.ord, 0, 0, 0, 4]

    getter io : IO
    getter wbuf : WriteBuffer = WriteBuffer.new
    getter params : Hash(String, String) = {} of String => String
    getter status : UInt8 = 'I'.ord.to_u8
    getter backend_pid : Int32 = 0
    getter backend_secret : Int32 = 0
    getter msg_ptr : Pointer(UInt8)
    getter msg_len : Int32 = 0
    property notice_handler : Proc(PGError, Nil)? = nil

    @rbuf : Pointer(UInt8)
    @rcap : Int32 = READ_BUFFER
    @rpos : Int32 = 0
    @rend : Int32 = 0
    @close_acks : Int32 = 0
    @closes_in_wbuf : Int32 = 0
    @pending_close : Array(String) = [] of String
    @stmt_seq : Int32 = 0
    @closed : Bool = false

    def initialize(info : ConnInfo)
      @rbuf = Pointer(UInt8).malloc(@rcap)
      @msg_ptr = @rbuf
      @io = negotiate_tls(open_socket(info), info)
      startup(info)
    end

    # --- connection setup ---------------------------------------------------

    private def open_socket(info : ConnInfo) : Socket
      sock = if info.unix_socket?
               UNIXSocket.new("#{info.host.rstrip('/')}/.s.PGSQL.#{info.port}")
             else
               s = TCPSocket.new(info.host, info.port, connect_timeout: info.connect_timeout)
               s.tcp_nodelay = true
               s.keepalive = true
               s
             end
      sock.sync = true
      sock.read_buffering = false
      sock
    end

    private def negotiate_tls(sock : Socket, info : ConnInfo) : IO
      return sock if info.sslmode.disable? || info.unix_socket?
      sock.write(SSL_REQUEST)
      case sock.read_byte
      when 'S'.ord
        ctx = OpenSSL::SSL::Context::Client.new
        ctx.verify_mode = OpenSSL::SSL::VerifyMode::NONE unless info.sslmode.verify_full?
        tls = OpenSSL::SSL::Socket::Client.new(sock, context: ctx, sync_close: true, hostname: info.host)
        tls.sync = true
        tls
      when 'N'.ord
        if info.sslmode.prefer?
          sock
        else
          sock.close
          raise AuthError.new("server does not support TLS but sslmode requires it")
        end
      else
        sock.close
        raise ProtocolError.new("unexpected reply to SSLRequest")
      end
    end

    private def startup(info : ConnInfo) : Nil
      begin_request
      pos = @wbuf.size
      @wbuf.i32(0)
      @wbuf.i32(196608) # protocol 3.0
      pair("user", info.user)
      pair("database", info.database)
      pair("client_encoding", "UTF8")
      info.application_name.try { |v| pair("application_name", v) }
      info.options.each { |k, v| pair(k, v) }
      @wbuf.u8(0)
      @wbuf.finish_message(pos)
      flush

      scram = nil
      loop do
        case read_message.unsafe_chr
        when 'R'
          r = MsgReader.new(@msg_ptr, @msg_len)
          case code = r.i32
          when 0 # AuthenticationOk
          when 3
            send_password(require_password(info))
          when 5
            salt = r.rest
            inner = Digest::MD5.hexdigest(require_password(info) + info.user)
            md5 = "md5" + Digest::MD5.hexdigest(inner.to_slice + salt)
            send_password(md5)
          when 10
            mechanisms = [] of String
            while r.remaining > 1
              mechanisms << r.cstr
            end
            unless mechanisms.includes?(Scram::MECHANISM)
              raise AuthError.new("server offers no supported SASL mechanism (#{mechanisms.join(", ")})")
            end
            scram = Scram.new(require_password(info))
            first = scram.client_first
            begin_request
            pos = @wbuf.start_message('p')
            @wbuf.cstr(Scram::MECHANISM)
            @wbuf.i32(first.bytesize)
            @wbuf.raw(first.to_slice)
            @wbuf.finish_message(pos)
            flush
          when 11
            sc = scram || raise ProtocolError.new("unexpected SASLContinue")
            final = sc.client_final(String.new(r.rest))
            begin_request
            pos = @wbuf.start_message('p')
            @wbuf.raw(final.to_slice)
            @wbuf.finish_message(pos)
            flush
          when 12
            (scram || raise ProtocolError.new("unexpected SASLFinal")).verify(String.new(r.rest))
          else
            raise AuthError.new("unsupported authentication method (code #{code})")
          end
        when 'K'
          r = MsgReader.new(@msg_ptr, @msg_len)
          @backend_pid = r.i32
          @backend_secret = r.i32
        when 'Z'
          @status = @msg_ptr[0]
          return
        when 'E'
          raise PGError.parse(@msg_ptr, @msg_len)
        end
      end
    rescue ex
      @io.close rescue nil
      raise ex
    end

    private def pair(key : String, value : String) : Nil
      @wbuf.cstr(key)
      @wbuf.cstr(value)
    end

    private def require_password(info : ConnInfo) : String
      info.password || raise AuthError.new("server requested a password but none was given")
    end

    private def send_password(password : String) : Nil
      begin_request
      pos = @wbuf.start_message('p')
      @wbuf.cstr(password)
      @wbuf.finish_message(pos)
      flush
    end

    # --- writing ------------------------------------------------------------

    # Starts building a new request: resets the output buffer.
    def begin_request : Nil
      @wbuf.clear
      @closes_in_wbuf = 0
    end

    # Queues a server-side statement to be closed. The Close message rides
    # along with the next request, so closing never costs a round trip.
    def queue_close(name : String) : Nil
      @pending_close << name unless @closed
    end

    # Appends Close messages for every queued statement to the request being built.
    def write_pending_closes : Nil
      @closes_in_wbuf = @pending_close.size
      @pending_close.each do |name|
        pos = @wbuf.start_message('C')
        @wbuf.u8('S'.ord.to_u8)
        @wbuf.cstr(name)
        @wbuf.finish_message(pos)
      end
    end

    def flush : Nil
      @io.write(@wbuf.to_slice)
      if @closes_in_wbuf > 0
        @close_acks += @closes_in_wbuf
        @pending_close.clear
        @closes_in_wbuf = 0
      end
      @wbuf.clear
    end

    def next_statement_name : String
      @stmt_seq += 1
      "mj#{@stmt_seq}"
    end

    # --- reading ------------------------------------------------------------

    # Reads the next backend message, transparently handling the
    # asynchronous ones (notices, parameter status, notifications and the
    # CloseComplete answering our deferred closes). Returns the type byte.
    def read_message : UInt8
      loop do
        ensure_buffered(5)
        p = @rbuf + @rpos
        type = p[0]
        len = BE.i32(p + 1) - 4
        raise ProtocolError.new("invalid message length #{len}") if len < 0
        total = 5 + len
        ensure_buffered(total)
        p = @rbuf + @rpos
        @msg_ptr = p + 5
        @msg_len = len
        @rpos += total
        case type
        when 'N'.ord
          if handler = @notice_handler
            handler.call(PGError.parse(@msg_ptr, @msg_len))
          end
          next
        when 'S'.ord
          r = MsgReader.new(@msg_ptr, @msg_len)
          name = r.cstr
          @params[name] = r.cstr
          next
        when 'A'.ord
          next
        when '3'.ord
          if @close_acks > 0
            @close_acks -= 1
            next
          end
        end
        return type
      end
    end

    @[AlwaysInline]
    private def ensure_buffered(n : Int32) : Nil
      fill(n) if @rend - @rpos < n
    end

    private def fill(need : Int32) : Nil
      while @rend - @rpos < need
        avail = @rend - @rpos
        if avail == 0
          @rpos = @rend = 0
        end
        if @rpos + need > @rcap || @rcap - @rend < MIN_READ
          if need > @rcap
            new_cap = @rcap
            while new_cap < need
              new_cap *= 2
            end
            nb = Pointer(UInt8).malloc(new_cap)
            nb.copy_from(@rbuf + @rpos, avail)
            @rbuf = nb
            @rcap = new_cap
          else
            @rbuf.move_from(@rbuf + @rpos, avail)
          end
          @rpos = 0
          @rend = avail
        end
        n = @io.read(Slice.new(@rbuf + @rend, @rcap - @rend))
        raise IO::EOFError.new("connection closed by server") if n == 0
        @rend += n
      end
    end

    # Parses the ErrorResponse currently held in the message slot, then
    # brings the connection back to a usable state and raises.
    #
    # With *sync* true a Sync is sent first (needed when the request was
    # ended with Flush rather than Sync, as the server discards messages
    # until it sees one).
    def fail(sync : Bool) : NoReturn
      error = PGError.parse(@msg_ptr, @msg_len)
      if sync
        begin_request
        @wbuf.raw(SYNC)
        flush
      end
      wait_ready
      raise error
    end

    # Reads and discards messages up to and including ReadyForQuery.
    def wait_ready : Nil
      loop do
        t = read_message
        if t == 'Z'.ord
          @status = @msg_ptr[0]
          return
        end
      end
    end

    # Records the transaction status byte of the ReadyForQuery message just read.
    def status_from_message : Nil
      @status = @msg_ptr[0]
    end

    # Reads ReadyForQuery, raising on anything else.
    def expect_ready : Nil
      t = read_message
      case t
      when 'Z'.ord then @status = @msg_ptr[0]
      when 'E'.ord then fail(false)
      else              raise ProtocolError.new("expected ReadyForQuery, got #{t.unsafe_chr.inspect}")
      end
    end

    # Reads one message and checks its type; raises the server error on 'E'.
    def expect(type : Char, sync_on_error : Bool = false) : Nil
      t = read_message
      return if t == type.ord
      if t == 'E'.ord
        fail(sync_on_error)
      else
        raise ProtocolError.new("expected #{type.inspect}, got #{t.unsafe_chr.inspect}")
      end
    end

    # --- simple queries -----------------------------------------------------

    # Runs one or more statements with the simple query protocol and
    # discards any rows.
    def simple_query(sql : String) : Nil
      begin_request
      write_pending_closes
      pos = @wbuf.start_message('Q')
      @wbuf.cstr(sql)
      @wbuf.finish_message(pos)
      flush
      first_error = nil
      loop do
        case read_message.unsafe_chr
        when 'Z'
          @status = @msg_ptr[0]
          break
        when 'E'
          first_error ||= PGError.parse(@msg_ptr, @msg_len)
        end
      end
      raise first_error if first_error
    end

    # Number of rows from the tag of a CommandComplete body ("INSERT 0 5" => 5).
    def self.rows_from_tag(ptr : Pointer(UInt8), len : Int32) : Int64
      i = len - 1
      i -= 1 if i >= 0 && ptr[i] == 0
      last = i
      n = 0_i64
      mul = 1_i64
      while i >= 0
        c = ptr[i]
        break if c < 48_u8 || c > 57_u8
        n += (c - 48).to_i64 * mul
        mul *= 10
        i -= 1
      end
      i == last ? 0_i64 : n
    end

    def in_transaction? : Bool
      @status != 'I'.ord
    end

    def close : Nil
      return if @closed
      @closed = true
      begin
        begin_request
        @wbuf.raw(Bytes['X'.ord, 0, 0, 0, 4])
        flush
      rescue
      end
      @io.close rescue nil
    end

    def closed? : Bool
      @closed
    end
  end
end
