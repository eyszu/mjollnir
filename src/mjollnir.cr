require "socket"
require "uri"
require "http/params"
require "json"
require "uuid"
require "./mjollnir/version"
require "./mjollnir/error"
require "./mjollnir/oid"
require "./mjollnir/buffer"
require "./mjollnir/conninfo"
require "./mjollnir/scram"
require "./mjollnir/numeric"
require "./mjollnir/decode"
require "./mjollnir/encode"
require "./mjollnir/wire"
require "./mjollnir/statement"
require "./mjollnir/result_set"
require "./mjollnir/queries"
require "./mjollnir/connection"
require "./mjollnir/pool"

# Mjollnir, a standalone PostgreSQL driver. It has no dependencies beyond
# Crystal's standard library.
#
# ```
# require "mjollnir"
#
# Mjollnir.open("postgres://user:pass@localhost/appdb") do |db|
#   db.exec "insert into users (id, name) values ($1, $2)", 1, "Thor"
#   name = db.query_one("select name from users where id = $1", 1, as: String)
# end
# ```
module Mjollnir
  # Opens a connection pool (see `Pool`) for *url*.
  def self.pool(url : String) : Pool
    Pool.new(url)
  end

  # Opens a pool, yields it and closes it afterwards.
  def self.open(url : String, &)
    pool = Pool.new(url)
    begin
      yield pool
    ensure
      pool.close
    end
  end

  # Opens a pool and returns it; close it with `Pool#close`.
  def self.open(url : String) : Pool
    Pool.new(url)
  end

  # Opens a single connection.
  def self.connect(url : String) : Connection
    Connection.new(url)
  end

  # Opens a single connection, yields it and closes it afterwards.
  def self.connect(url : String, &)
    conn = Connection.new(url)
    begin
      yield conn
    ensure
      conn.close
    end
  end
end
