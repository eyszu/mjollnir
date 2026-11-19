module Mjollnir
  # Base class for every error raised by the driver.
  class Error < Exception
  end

  # The server sent something the driver does not understand. The
  # connection is closed when this is raised.
  class ProtocolError < Error
  end

  # Authentication failed or the server asked for an unsupported method.
  class AuthError < Error
  end

  # An argument could not be encoded for the type the server expects.
  class EncodeError < Error
  end

  # A connection could not be established (network, TLS or startup failure).
  class ConnectionRefused < Error
  end

  # An established connection failed (socket error). The connection is
  # closed; a pool discards it.
  class ConnectionLost < Error
  end

  # No pooled connection became available within `checkout_timeout`.
  class PoolTimeout < Error
  end

  # `query_one` found no rows.
  class NoResultsError < Error
  end

  # A column was read as a type it cannot be converted to, or NULL was read
  # into a non-nilable type.
  class TypeMismatchError < Error
  end

  # Raised by `Transaction#rollback`; caught by the enclosing `transaction` block.
  class Rollback < Error
  end

  # An ErrorResponse (or NoticeResponse) from the server, with every field
  # PostgreSQL documents for it.
  class PGError < Error
    getter severity : String
    getter code : String
    getter detail : String?
    getter hint : String?
    getter position : String?
    getter schema : String?
    getter table : String?
    getter column : String?
    getter data_type : String?
    getter constraint : String?

    def initialize(message : String, @severity = "ERROR", @code = "XX000",
                   @detail = nil, @hint = nil, @position = nil, @schema = nil,
                   @table = nil, @column = nil, @data_type = nil, @constraint = nil)
      super(message)
    end

    # Parses the body of an ErrorResponse / NoticeResponse message.
    def self.parse(ptr : Pointer(UInt8), len : Int32) : PGError
      severity = "ERROR"
      code = "XX000"
      message = ""
      detail = hint = position = schema = table = column = data_type = constraint = nil
      i = 0
      while i < len
        field = ptr[i]
        break if field == 0
        i += 1
        start = i
        while i < len && ptr[i] != 0
          i += 1
        end
        value = String.new(ptr + start, i - start)
        i += 1
        case field.unsafe_chr
        when 'V' then severity = value
        when 'S' then severity = value if severity == "ERROR"
        when 'C' then code = value
        when 'M' then message = value
        when 'D' then detail = value
        when 'H' then hint = value
        when 'P' then position = value
        when 's' then schema = value
        when 't' then table = value
        when 'c' then column = value
        when 'd' then data_type = value
        when 'n' then constraint = value
        end
      end
      new(message, severity, code, detail, hint, position, schema, table, column, data_type, constraint)
    end

    def to_s(io : IO) : Nil
      io << message
      io << " (" << code << ")"
    end
  end
end
