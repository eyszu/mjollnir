# Benchmark workloads. The same file is compiled twice:
#
#   crystal build --release -Dmjollnir bench/workloads.cr   (Mjollnir, its own API)
#   crystal build --release            bench/workloads.cr   (crystal-pg, via crystal-db)
#
# Mjollnir is standalone and does not use crystal-db; crystal-pg is built on it.
# The two APIs are call-compatible for everything used here (exec, query,
# query_one, query_all, scalar, transaction, rs.read), so the workload bodies
# are literally the same code. The only differences are the `require`, how the
# pool is opened, and the spots marked DRIVER-SPECIFIC below.
{% if flag?(:mjollnir) %}
  require "mjollnir"
  SCHEME = "mjollnir"
  alias Handle = Mjollnir::Pool
{% else %}
  require "pg"
  SCHEME = "postgres"
  alias Handle = DB::Database
{% end %}
require "json"

BASE = ENV["BENCH_DSN"]? || "mjol:mjol@127.0.0.1/mjol"

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

def lcg(x : Int64) : Int64
  (x &* 1103515245_i64 &+ 12345_i64) & 0x7fffffff_i64
end

alias Workload = Proc(Handle, Int64)

WORKLOADS = {} of String => Workload

def workload(name : String, &block : Handle -> Int64)
  WORKLOADS[name] = block
end

# --- round-trip latency -------------------------------------------------------

workload("select_one") do |db|
  sum = 0_i64
  20_000.times { |i| sum &+= db.query_one("select $1::int8", i.to_i64, as: Int64) }
  sum
end

workload("point_lookup") do |db|
  sum = 0_i64
  x = 42_i64
  20_000.times do
    x = lcg(x)
    id, name, score = db.query_one("select id, name, score from bench_items where id = $1", (x % 100_000 + 1).to_i32,
      as: {Int32, String, Float64})
    sum &+= id &+ name.bytesize &+ (score * 2).to_i64
  end
  sum
end

workload("pool_8_fibers") do |db|
  ch = Channel(Int64).new
  8.times do |f|
    spawn do
      s = 0_i64
      x = (f + 1).to_i64
      2_500.times do
        x = lcg(x)
        id, name = db.query_one("select id, name from bench_items where id = $1", (x % 100_000 + 1).to_i32, as: {Int32, String})
        s &+= id &+ name.bytesize
      end
      ch.send s
    end
  end
  total = 0_i64
  8.times { total &+= ch.receive }
  total
end

# --- result throughput ----------------------------------------------------------

workload("scan_ints_1M") do |db|
  sum = 0_i64
  db.query("select id, a, b from bench_nums") do |rs|
    rs.each { sum &+= rs.read(Int32) &+ rs.read(Int64) &+ rs.read(Int32) }
  end
  sum
end

workload("scan_text_300k") do |db|
  sum = 0_i64
  db.query("select name, email, bio from bench_text") do |rs|
    rs.each do
      sum &+= rs.read(String).bytesize &+ rs.read(String).bytesize &+ rs.read(String).bytesize
    end
  end
  sum
end

workload("scan_mixed_200k") do |db|
  sum = 0_i64
  db.query("select id, score, name, active, ts, uid from bench_mixed") do |rs|
    rs.each do
      id, score, name, active, ts, uid = rs.read(Int32, Float64, String, Bool, Time, UUID)
      sum &+= id &+ (score * 10).to_i64 &+ name.bytesize &+ (active ? 1 : 0) &+ ts.to_unix &+ uid.bytes[0]
    end
  end
  sum
end

workload("int_arrays_50k") do |db|
  sum = 0_i64
  db.query("select xs from bench_arr") do |rs|
    rs.each { rs.read(Array(Int32)).each { |v| sum &+= v } }
  end
  sum
end

workload("jsonb_any_20k") do |db|
  sum = 0_i64
  db.query("select doc from bench_json") do |rs|
    rs.each do
      d = rs.read(JSON::Any)
      sum &+= d["id"].as_i &+ d["tags"].as_a.size &+ d["name"].as_s.bytesize
    end
  end
  sum
end

workload("jsonb_typed_20k") do |db|
  sum = 0_i64
  db.query("select doc from bench_json") do |rs|
    rs.each do
      # DRIVER-SPECIFIC: crystal-pg's idiom is a pull parser; Mjollnir can also parse the type directly.
      d = {% if flag?(:mjollnir) %} rs.read(Doc) {% else %} Doc.new(rs.read(JSON::PullParser)) {% end %}
      sum &+= d.id &+ d.tags.size &+ d.name.bytesize &+ (d.nested.try(&.flag) ? 1 : 0)
    end
  end
  sum
end

# --- writes ---------------------------------------------------------------------

def insert_check(db : Handle) : Int64
  db.query_one("select count(*) + coalesce(sum(id), 0)::int8 + coalesce(sum(length(name)), 0)::int8 from bench_ins", as: Int64)
end

workload("insert_loop_10k") do |db|
  db.exec "truncate bench_ins"
  db.transaction do |tx|
    conn = tx.connection
    10_000.times { |i| conn.exec("insert into bench_ins values ($1, $2, $3)", i, "name-#{i}", i * 0.5) }
  end
  insert_check(db)
end

workload("insert_50k") do |db|
  db.exec "truncate bench_ins"
  # DRIVER-SPECIFIC: Mjollnir's pipelined exec_many vs the plain loop crystal-pg offers.
  {% if flag?(:mjollnir) %}
    rows = Array(Array(Int32 | String | Float64)).new(50_000)
    50_000.times { |i| rows << [i, "name-#{i}", i * 0.5] of (Int32 | String | Float64) }
    db.transaction { |tx| tx.exec_many("insert into bench_ins values ($1, $2, $3)", rows) }
  {% else %}
    db.transaction do |tx|
      conn = tx.connection
      50_000.times { |i| conn.exec("insert into bench_ins values ($1, $2, $3)", i, "name-#{i}", i * 0.5) }
    end
  {% end %}
  insert_check(db)
end

# --- runner ---------------------------------------------------------------------

only = ARGV.empty? ? nil : ARGV
URL = "#{SCHEME}://#{BASE}?initial_pool_size=8&max_pool_size=8&max_idle_pool_size=8#{ENV["BENCH_EXTRA"]?}"
db = {% if flag?(:mjollnir) %} Mjollnir.open(URL) {% else %} DB.open(URL) {% end %}
db.scalar("select 1") # warm the first connection (auth, prepare)
WORKLOADS.each do |name, block|
  next if only && !only.includes?(name)
  GC.collect
  t0 = Time.monotonic
  sum = block.call(db)
  ms = (Time.monotonic - t0).total_milliseconds
  puts %({"w":"#{name}","ms":#{ms.round(3)},"sum":#{sum}})
end
rss = File.read("/proc/self/status").lines.find(&.starts_with?("VmHWM:")).try(&.split.[1].to_i) || 0
puts %({"w":"_peak_rss_kb","ms":0,"sum":#{rss}})
db.close
