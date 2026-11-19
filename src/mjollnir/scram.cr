require "openssl"
require "openssl/hmac"
require "base64"

module Mjollnir
  # Client side of SCRAM-SHA-256 (RFC 5802 / RFC 7677) as PostgreSQL speaks it.
  #
  # The password is used as-is; SASLprep normalisation is not applied, which
  # only matters for passwords containing non-ASCII characters.
  class Scram
    MECHANISM = "SCRAM-SHA-256"

    @first_bare : String
    @auth_message : String = ""
    @server_signature : Bytes = Bytes.empty

    def initialize(@password : String)
      @nonce = Random::Secure.base64(18)
      @first_bare = "n=,r=#{@nonce}"
    end

    # The client-first-message sent in SASLInitialResponse.
    def client_first : String
      "n,,#{@first_bare}"
    end

    # Consumes the server-first-message and produces the client-final-message.
    def client_final(server_first : String) : String
      nonce = salt = iterations = nil
      server_first.split(',') do |part|
        case
        when part.starts_with?("r=") then nonce = part[2..]
        when part.starts_with?("s=") then salt = part[2..]
        when part.starts_with?("i=") then iterations = part[2..].to_i
        end
      end
      raise AuthError.new("malformed SCRAM server-first message") unless nonce && salt && iterations
      raise AuthError.new("SCRAM nonce mismatch") unless nonce.starts_with?(@nonce)

      salted = OpenSSL::PKCS5.pbkdf2_hmac(@password, Base64.decode(salt), iterations,
        OpenSSL::Algorithm::SHA256, 32)
      client_key = OpenSSL::HMAC.digest(:sha256, salted, "Client Key")
      stored_key = OpenSSL::Digest.new("SHA256").update(client_key).final
      without_proof = "c=biws,r=#{nonce}"
      @auth_message = "#{@first_bare},#{server_first},#{without_proof}"
      signature = OpenSSL::HMAC.digest(:sha256, stored_key, @auth_message)
      proof = Bytes.new(32) { |i| client_key[i] ^ signature[i] }
      server_key = OpenSSL::HMAC.digest(:sha256, salted, "Server Key")
      @server_signature = OpenSSL::HMAC.digest(:sha256, server_key, @auth_message)
      "#{without_proof},p=#{Base64.strict_encode(proof)}"
    end

    # Verifies the server-final-message (proves the server knows the password).
    def verify(server_final : String) : Nil
      if server_final.starts_with?("e=")
        raise AuthError.new("SCRAM authentication failed: #{server_final[2..]}")
      end
      unless server_final.starts_with?("v=") &&
             Base64.decode(server_final[2..]) == @server_signature
        raise AuthError.new("SCRAM server signature mismatch")
      end
    end
  end
end
