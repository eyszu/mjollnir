module Mjollnir
  # Type OIDs of the built-in PostgreSQL types the driver has a binary
  # codec for. Everything else is fetched in text format.
  module OID
    BOOL        =   16_u32
    BYTEA       =   17_u32
    CHAR        =   18_u32
    NAME        =   19_u32
    INT8        =   20_u32
    INT2        =   21_u32
    INT4        =   23_u32
    TEXT        =   25_u32
    OID         =   26_u32
    JSON        =  114_u32
    FLOAT4      =  700_u32
    FLOAT8      =  701_u32
    BPCHAR      = 1042_u32
    VARCHAR     = 1043_u32
    DATE        = 1082_u32
    TIMESTAMP   = 1114_u32
    TIMESTAMPTZ = 1184_u32
    NUMERIC     = 1700_u32
    UUID        = 2950_u32
    JSONB       = 3802_u32

    BOOL_ARRAY    = 1000_u32
    INT2_ARRAY    = 1005_u32
    INT4_ARRAY    = 1007_u32
    TEXT_ARRAY    = 1009_u32
    BPCHAR_ARRAY  = 1014_u32
    VARCHAR_ARRAY = 1015_u32
    INT8_ARRAY    = 1016_u32
    FLOAT4_ARRAY  = 1021_u32
    FLOAT8_ARRAY  = 1022_u32
    UUID_ARRAY    = 2951_u32

    # Element OID for the array types we can decode/encode in binary, or 0.
    def self.array_element(oid : UInt32) : UInt32
      case oid
      when BOOL_ARRAY    then BOOL
      when INT2_ARRAY    then INT2
      when INT4_ARRAY    then INT4
      when TEXT_ARRAY    then TEXT
      when BPCHAR_ARRAY  then BPCHAR
      when VARCHAR_ARRAY then VARCHAR
      when INT8_ARRAY    then INT8
      when FLOAT4_ARRAY  then FLOAT4
      when FLOAT8_ARRAY  then FLOAT8
      when UUID_ARRAY    then UUID
      else                    0_u32
      end
    end
  end

  # How a result column is represented on the wire and in the decoder.
  # Computed once per prepared statement from the RowDescription.
  enum Kind : UInt8
    TextFmt # unsupported type, fetched in text format
    Bool
    Int2
    Int4
    Int8
    Oid
    Float4
    Float8
    Text
    Bytea
    Json
    Jsonb
    Uuid
    Date
    Timestamp
    Timestamptz
    Numeric
    Array

    def self.for(oid : UInt32) : Kind
      case oid
      when OID::BOOL                                       then Bool
      when OID::INT2                                       then Int2
      when OID::INT4                                       then Int4
      when OID::INT8                                       then Int8
      when OID::OID                                        then Oid
      when OID::FLOAT4                                     then Float4
      when OID::FLOAT8                                     then Float8
      when OID::TEXT, OID::VARCHAR, OID::BPCHAR, OID::NAME then Text
      when OID::BYTEA                                      then Bytea
      when OID::JSON                                       then Json
      when OID::JSONB                                      then Jsonb
      when OID::UUID                                       then Uuid
      when OID::DATE                                       then Date
      when OID::TIMESTAMP                                  then Timestamp
      when OID::TIMESTAMPTZ                                then Timestamptz
      when OID::NUMERIC                                    then Numeric
      else
        OID.array_element(oid) != 0 ? Array : TextFmt
      end
    end

    # Wire format code requested for this kind in the Bind message.
    def format_code : Int16
      text_fmt? ? 0_i16 : 1_i16
    end
  end

  # One column of a RowDescription.
  struct Field
    getter name : String
    getter oid : UInt32
    getter kind : Kind

    def initialize(@name : String, @oid : UInt32)
      @kind = Kind.for(oid)
    end
  end
end
