require "spec"
require "../src/mjollnir"

URL = ENV["MJOLLNIR_URL"]? || "postgres://mjol:mjol@127.0.0.1/mjol"

def with_db(url : String = URL, &)
  Mjollnir.open(url) { |db| yield db }
end

# Runs the block on a single connection.
def with_conn(url : String = URL, &)
  Mjollnir.connect(url) { |conn| yield conn }
end

struct Nested
  include JSON::Serializable
  getter flag : Bool
end

struct Doc
  include JSON::Serializable
  getter id : Int32
  getter name : String
  getter tags : Array(String)
  getter nested : Nested?
end

enum Color
  Red
  Green
end

class Person
  getter id : Int32
  getter name : String

  def initialize(@id, @name)
  end

  def self.from_rs(rs : Mjollnir::ResultSet)
    new(rs.read(Int32), rs.read(String))
  end
end
