require "./spec_helper"

describe Mjollnir do
  describe "connection" do
    it "connects with SCRAM-SHA-256 and reports server info" do
      with_conn do |c|
        c.server_version.not_nil!.should start_with("16")
        c.server_parameter("client_encoding").should eq "UTF8"
        c.backend_pid.should be > 0
      end
    end

    it "rejects a wrong password with a PGError" do
      ex = expect_raises(Mjollnir::PGError) do
        Mjollnir.open("mjollnir://mjol:wrong@127.0.0.1/mjol") { |db| db.scalar("select 1") }
      end
      ex.code.should eq "28P01"
    end

    it "raises ConnectionRefused when nothing listens" do
      expect_raises(Mjollnir::ConnectionRefused) do
        Mjollnir.open("mjollnir://mjol:mjol@127.0.0.1:1/mjol?initial_pool_size=1") { |db| db.scalar("select 1") }
      end
    end

    it "authenticates with md5 and cleartext when configured" do
      if url = ENV["MJOLLNIR_MD5_URL"]?
        with_db(url) { |db| db.scalar("select 1").should eq 1 }
      end
      if url = ENV["MJOLLNIR_CLEARTEXT_URL"]?
        with_db(url) { |db| db.scalar("select 1").should eq 1 }
      end
    end

    it "connects over TLS with sslmode=require" do
      with_db(URL + "?sslmode=require") do |db|
        db.scalar("select ssl from pg_stat_ssl where pid = pg_backend_pid()").should eq true
      end
    end

    it "connects over a unix socket when one exists" do
      if File.exists?("/var/run/postgresql/.s.PGSQL.5432") && ENV["MJOLLNIR_TEST_UNIX"]?
        with_db("mjollnir://mjol:mjol@%2Fvar%2Frun%2Fpostgresql/mjol") { |db| db.scalar("select 1").should eq 1 }
      end
    end

    it "sends extra parameters in the startup packet" do
      with_db(URL + "?application_name=mjolspec&search_path=pg_catalog") do |db|
        db.scalar("select current_setting('application_name')").should eq "mjolspec"
        db.scalar("select current_setting('search_path')").should eq "pg_catalog"
      end
    end
  end

  describe "scalar types" do
    it "round-trips integers, floats and bool in binary" do
      with_db do |db|
        db.query_one("select $1::int2, $2::int4, $3::int8, $4::float4, $5::float8, $6::bool",
          12_i16, -123456, 9_000_000_000_i64, 1.5_f32, 2.25, false,
          as: {Int16, Int32, Int64, Float32, Float64, Bool}).should eq({12_i16, -123456, 9_000_000_000_i64, 1.5_f32, 2.25, false})
      end
    end

    it "widens int2/int4 to larger Crystal ints and float4 to Float64" do
      with_db do |db|
        db.query_one("select 5::int2, 6::int4, 7::int2, 1.5::float4", as: {Int32, Int64, Int64, Float64}).should eq({5, 6_i64, 7_i64, 1.5})
      end
    end

    it "round-trips text, bytea and uuid" do
      with_db do |db|
        u = UUID.random
        bytes = Bytes[0, 1, 2, 255, 0, 7]
        db.query_one("select $1::text, $2::bytea, $3::uuid", "héllo wörld ✓", bytes, u, as: {String, Bytes, UUID}).should eq({"héllo wörld ✓", bytes, u})
      end
    end

    it "decodes NULL for every typed nilable read and rejects it for non-nilable" do
      with_db do |db|
        db.query_one("select null::int4, null::int8, null::text, null::bool, null::float8, null::uuid, null::timestamptz, null::jsonb, null::bytea, null::numeric, null::int4[]",
          as: {Int32?, Int64?, String?, Bool?, Float64?, UUID?, Time?, JSON::Any?, Bytes?, Mjollnir::Numeric?, Array(Int32)?}).should eq({nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil})
        expect_raises(Mjollnir::TypeMismatchError) { db.query_one("select null::int4", as: Int32) }
      end
    end

    it "raises ColumnTypeMismatchError on a wrong type" do
      with_db do |db|
        expect_raises(Mjollnir::TypeMismatchError, /cannot be read as Int32/) { db.query_one("select 'x'::text", as: Int32) }
        expect_raises(Mjollnir::TypeMismatchError) { db.query_one("select 1::int8", as: Int32) }
      end
    end

    it "decodes timestamps and dates, including before 1970 and 2000" do
      with_db do |db|
        db.query_one("select '2026-11-18 12:34:56.789012+00'::timestamptz", as: Time).should eq Time.utc(2026, 11, 18, 12, 34, 56, nanosecond: 789_012_000)
        db.query_one("select '1969-12-31 23:59:59.999999'::timestamp", as: Time).should eq Time.utc(1969, 12, 31, 23, 59, 59, nanosecond: 999_999_000)
        db.query_one("select '1900-01-01 00:00:00'::timestamp", as: Time).should eq Time.utc(1900, 1, 1)
        db.query_one("select '2000-01-01'::date", as: Time).should eq Time.utc(2000, 1, 1)
        db.query_one("select '1999-12-31'::date", as: Time).should eq Time.utc(1999, 12, 31)
        db.query_one("select '2026-02-29'::date is null", as: Bool) rescue nil
      end
    end

    it "round-trips Time parameters through timestamptz, timestamp and date" do
      with_db do |db|
        t = Time.utc(2031, 7, 4, 1, 2, 3, nanosecond: 456_789_000)
        db.query_one("select $1::timestamptz, $2::timestamp, $3::date", t, t, t, as: {Time, Time, Time}).should eq({t, t, Time.utc(2031, 7, 4)})
        before = Time.utc(1950, 3, 4, 5, 6, 7, nanosecond: 8_000)
        db.query_one("select $1::timestamptz", before, as: Time).should eq before
      end
    end

    it "raises on infinite timestamps instead of returning garbage" do
      with_db do |db|
        expect_raises(Mjollnir::Error, /infinite/) { db.query_one("select 'infinity'::timestamptz", as: Time) }
        db.scalar("select 1").should eq 1
      end
    end

    it "decodes numeric exactly (compared with the server's own text output)" do
      values = ["0", "0.00", "1", "-1", "10000", "100000000", "99999999.9999", "0.0001", "0.00001",
                "0.000000123", "123456789012345678901234567890.123456789", "1.10", "-0.000001",
                "1e-10", "12345678.00", "0.5", "-0.5", "NaN", "Infinity", "-Infinity", "10000.0001",
                "0.00010001", "100.0000000000"]
      with_db do |db|
        values.each do |v|
          db.query("select $1::numeric, $1::numeric::text", v) do |rs|
            rs.each do
              n = rs.read(Mjollnir::Numeric)
              expected = rs.read(String)
              n.to_s.should eq(expected)
            end
          end
        end
        db.query_one("select 1.25::numeric", as: Mjollnir::Numeric).to_f64.should eq 1.25
      end
    end

    it "returns text for types without a binary codec" do
      with_db do |db|
        db.query_one("select '10.1.2.3'::inet, '1 day 02:03:04'::interval, 'a'::\"char\"", as: {String, String, String}).should eq({"10.1.2.3", "1 day 02:03:04", "a"})
      end
    end

    it "accepts Strings for parameters of any server type" do
      with_db do |db|
        u = "6b0f1b7e-0c3e-4f7a-9d52-0d4c2f9d3a11"
        db.query_one("select $1::uuid, $2::date, $3::inet, $4::int8", u, "2020-02-29", "127.0.0.1", "42",
          as: {UUID, Time, String, Int64}).should eq({UUID.new(u), Time.utc(2020, 2, 29), "127.0.0.1", 42_i64})
      end
    end

    it "encodes integers for the server-declared type and range-checks them" do
      with_db do |db|
        db.query_one("select $1::int2, $2::int8, $3::float8, $4::numeric::text", 5, 6, 7, 8, as: {Int16, Int64, Float64, String}).should eq({5_i16, 6_i64, 7.0, "8"})
        expect_raises(Mjollnir::EncodeError, /out of range for int2/) { db.query_one("select $1::int2", 40_000, as: Int16) }
        db.scalar("select 1").should eq 1
      end
    end

    it "handles an Int64 above Int32 for an int8 column and UInt64 via text" do
      with_db do |db|
        db.query_one("select $1::int8, $2::numeric::text", Int64::MAX, UInt64::MAX, as: {Int64, String}).should eq({Int64::MAX, UInt64::MAX.to_s})
      end
    end
  end

  describe "json" do
    it "reads json and jsonb as JSON::Any, String and PullParser" do
      with_db do |db|
        db.query_one("select '{\"a\":[1,2,{\"b\":null}]}'::jsonb", as: JSON::Any).should eq JSON.parse(%({"a":[1,2,{"b":null}]}))
        db.query_one("select '{\"a\": 1}'::json", as: JSON::Any)["a"].as_i.should eq 1
        db.query_one("select '{\"a\": 1}'::json", as: String).should eq %({"a": 1})
        db.query("select '{\"id\":1,\"name\":\"x\",\"tags\":[],\"nested\":null}'::jsonb") do |rs|
          rs.each { Doc.new(rs.read(JSON::PullParser)).name.should eq "x" }
        end
      end
    end

    it "parses a JSON::Serializable type straight from the column" do
      with_db do |db|
        doc = db.query_one(%(select '{"id":7,"name":"thor","tags":["a","b"],"nested":{"flag":true}}'::jsonb), as: Doc)
        doc.id.should eq 7
        doc.name.should eq "thor"
        doc.tags.should eq ["a", "b"]
        doc.nested.not_nil!.flag.should be_true
        db.query_one("select null::jsonb", as: Doc?).should be_nil
      end
    end

    it "sends JSON::Any and serializable values as parameters" do
      with_db do |db|
        db.query_one("select $1::jsonb", JSON.parse(%({"k":[1,2]})), as: JSON::Any).should eq JSON.parse(%({"k":[1,2]}))
        d = Doc.from_json(%({"id":1,"name":"n","tags":["t"]}))
        db.query_one("select $1::jsonb", d, as: Doc).name.should eq "n"
      end
    end
  end

  describe "arrays" do
    it "reads typed arrays, with and without NULL elements" do
      with_db do |db|
        db.query_one("select array[1,2,3]::int4[]", as: Array(Int32)).should eq [1, 2, 3]
        db.query_one("select array[1,null,3]::int4[]", as: Array(Int32?)).should eq [1, nil, 3]
        db.query_one("select array[1,2]::int2[]", as: Array(Int64)).should eq [1_i64, 2_i64]
        db.query_one("select array['a','b c',null]::text[]", as: Array(String?)).should eq ["a", "b c", nil]
        db.query_one("select array[1.5,2.5]::float8[]", as: Array(Float64)).should eq [1.5, 2.5]
        db.query_one("select array[true,false]::bool[]", as: Array(Bool)).should eq [true, false]
        db.query_one("select '{}'::int4[]", as: Array(Int32)).should eq([] of Int32)
        u = UUID.random
        db.query_one("select array[$1]::uuid[]", u, as: Array(UUID)).should eq [u]
        expect_raises(Mjollnir::Error, /unexpected NULL/) { db.query_one("select array[1,null]::int4[]", as: Array(Int32)) }
      end
    end

    it "reads arrays untyped" do
      with_db do |db|
        db.scalar("select array[1,null,3]::int4[]").should eq [1, nil, 3]
        db.scalar("select array['x','y']::text[]").should eq ["x", "y"]
      end
    end

    it "rejects multi-dimensional arrays with a clear error" do
      with_db do |db|
        expect_raises(Mjollnir::Error, /multi-dimensional/) { db.query_one("select array[[1,2],[3,4]]::int4[]", as: Array(Int32)) }
      end
    end

    it "sends arrays as parameters in binary and as text literals" do
      with_db do |db|
        db.query_one("select $1::int4[]", [1, 2, 3], as: Array(Int32)).should eq [1, 2, 3]
        db.query_one("select $1::int8[]", [1_i64, nil, 3_i64], as: Array(Int64?)).should eq [1_i64, nil, 3_i64]
        db.query_one("select $1::text[]", ["a", "b \"q\" \\ c", nil], as: Array(String?)).should eq ["a", "b \"q\" \\ c", nil]
        db.query_one("select $1::float8[]", [1.5, 2.5], as: Array(Float64)).should eq [1.5, 2.5]
        db.query_one("select $1::bool[]", [true, false], as: Array(Bool)).should eq [true, false]
        db.query_one("select $1::numeric[]::text", [1, 2], as: String).should eq "{1,2}"
        db.query_one("select $1::date[]::text", ["2020-01-01"], as: String).should eq "{2020-01-01}"
        db.query_one("select $1::int4 = any($2::int4[])", 2, [1, 2, 3], as: Bool).should be_true
      end
    end
  end

  describe "queries" do
    it "returns rows affected and handles statements without results" do
      with_db do |db|
        db.exec "create temp table t_rows (id int primary key, v text)"
        db.exec("insert into t_rows values ($1, $2), ($3, $4)", 1, "a", 2, "b").rows_affected.should eq 2
        db.exec("update t_rows set v = 'z' where id > $1", 0).rows_affected.should eq 2
        db.exec("delete from t_rows where id = $1", 1).rows_affected.should eq 1
        db.query_all("select id, v from t_rows", as: {Int32, String}).should eq [{2, "z"}]
        db.exec("insert into t_rows values ($1, $2) returning id", 9, "r").rows_affected.should eq 1
      end
    end

    it "iterates rows with named and tuple reads and exposes column metadata" do
      with_db do |db|
        db.query("select 1 as one, 'two' as two, 3.5::float8 as three") do |rs|
          rs.column_count.should eq 3
          rs.column_names.should eq ["one", "two", "three"]
          rs.column_oid(0).should eq 23_u32
          rs.move_next.should be_true
          rs.read(Int32, String, Float64).should eq({1, "two", 3.5})
          rs.move_next.should be_false
        end
      end
    end

    it "handles an empty query and an empty result" do
      with_db do |db|
        db.query_all("select 1 where false", as: Int32).should eq([] of Int32)
        db.exec("").rows_affected.should eq 0
      end
    end

    it "supports partially read rows and early close without desynchronising" do
      with_db do |db|
        db.query("select g, g::text, g::float8 from generate_series(1, 5000) g") do |rs|
          rs.move_next
          rs.read(Int32).should eq 1 # leave the rest of the row unread
          rs.move_next
          rs.read(Int32).should eq 2
        end # closed with 4998 rows still in flight
        db.query_one("select 42", as: Int32).should eq 42
        db.query("select g from generate_series(1, 100000) g") { |rs| rs.move_next }
        db.scalar("select 'ok'").should eq "ok"
      end
    end

    it "raises when reading past the last column" do
      with_db do |db|
        db.query("select 1") do |rs|
          rs.move_next
          rs.read(Int32)
          expect_raises(Mjollnir::Error, /no more columns/) { rs.read(Int32) }
        end
      end
    end

    it "streams results larger than the receive buffer and a single value larger than it" do
      with_db do |db|
        sum = 0_i64
        count = 0
        db.query("select g::int4, repeat('x', 100) from generate_series(1, 200000) g") do |rs|
          rs.each do
            sum += rs.read(Int32)
            rs.read(String).bytesize.should eq 100
            count += 1
          end
        end
        count.should eq 200_000
        sum.should eq 200_000_i64 * 200_001 // 2
        big = db.query_one("select repeat('ab', 2000000)", as: String)
        big.bytesize.should eq 4_000_000
        big[-2..].should eq "ab"
        db.scalar("select 1").should eq 1
      end
    end

    it "checks the number of arguments" do
      with_db do |db|
        expect_raises(Mjollnir::Error, /wrong number of arguments: statement takes 2, got 1/) { db.query_one("select $1::int, $2::int", 1, as: Int32) }
        db.scalar("select 1").should eq 1
      end
    end
  end

  describe "errors" do
    it "raises PGError with SQLSTATE and keeps the connection usable" do
      with_conn do |c|
        ex = expect_raises(Mjollnir::PGError) { c.query_one("selec 1", as: Int32) }
        ex.code.should eq "42601"
        ex.severity.should eq "ERROR"
        c.query_one("select 1", as: Int32).should eq 1
        c.in_transaction?.should be_false
      end
    end

    it "exposes constraint details" do
      with_conn do |c|
        c.exec "create temp table t_uniq (id int constraint t_uniq_pk primary key)"
        c.exec "insert into t_uniq values (1)"
        ex = expect_raises(Mjollnir::PGError) { c.exec "insert into t_uniq values ($1)", 1 }
        ex.code.should eq "23505"
        ex.constraint.should eq "t_uniq_pk"
        ex.table.should eq "t_uniq"
        ex.detail.to_s.should contain("already exists")
        c.query_one("select count(*) from t_uniq", as: Int64).should eq 1
      end
    end

    it "reports errors that happen in the middle of a result stream" do
      with_conn do |c|
        c.query("select 1/(3 - g) from generate_series(1, 5) g") do |rs|
          rs.move_next.should be_true
          rs.read(Int32).should eq 0
          rs.move_next.should be_true
          rs.read(Int32).should eq 1
          expect_raises(Mjollnir::PGError, /division by zero/) { rs.move_next }
        end
        c.query_one("select 7", as: Int32).should eq 7
      end
    end

    it "recovers from a Parse error in a prepared statement" do
      with_conn do |c|
        expect_raises(Mjollnir::PGError, /does not exist/) { c.query_one("select * from no_such_table_xyz where a = $1", 1, as: Int32) }
        c.query_one("select 3", as: Int32).should eq 3
      end
    end

    it "delivers notices to the handler" do
      with_conn do |c|
        notices = [] of String
        c.on_notice { |n| notices << n.message.to_s }
        c.exec_all "do $$ begin raise notice 'hello %', 'there'; end $$"
        notices.should eq ["hello there"]
      end
    end
  end

  describe "transactions" do
    it "commits and rolls back" do
      with_db do |db|
        db.exec "create table if not exists t_tx (id int)"
        db.exec "truncate t_tx"
        db.transaction { |tx| tx.connection.exec("insert into t_tx values (1)") }
        db.transaction do |tx|
          tx.connection.exec("insert into t_tx values (2)")
          tx.rollback
        end
        db.query_all("select id from t_tx", as: Int32).should eq [1]
        expect_raises(Exception, /boom/) do
          db.transaction do |tx|
            tx.connection.exec("insert into t_tx values (3)")
            raise "boom"
          end
        end
        db.scalar("select count(*) from t_tx").should eq 1
        db.exec "drop table t_tx"
      end
    end

    it "supports nested transactions through savepoints" do
      with_db do |db|
        db.exec "create temp table t_sp2 (id int)"
        db.transaction do |outer|
          outer.exec "insert into t_sp2 values (1)"
          outer.transaction do |inner|
            inner.exec "insert into t_sp2 values (2)"
            inner.rollback
          end
          outer.exec "insert into t_sp2 values (3)"
          outer.transaction { |inner| inner.exec "insert into t_sp2 values (4)" }
        end
        db.query_all("select id from t_sp2 order by id", as: Int32).should eq [1, 3, 4]
      end
    end

    it "rolls back a savepoint after an error inside it and keeps the outer transaction" do
      with_db do |db|
        db.exec "create temp table t_sp3 (id int primary key)"
        db.transaction do |tx|
          tx.exec "insert into t_sp3 values (1)"
          expect_raises(Mjollnir::PGError) do
            tx.transaction { |inner| inner.exec "insert into t_sp3 values (1)" }
          end
          tx.exec "insert into t_sp3 values (2)" # outer transaction still usable
        end
        db.query_all("select id from t_sp3 order by id", as: Int32).should eq [1, 2]
      end
    end

    it "tracks transaction status and a failed transaction" do
      with_conn do |c|
        c.exec_all "begin"
        c.in_transaction?.should be_true
        expect_raises(Mjollnir::PGError) { c.exec "select 1/0" }
        c.in_transaction?.should be_true # aborted but still open
        expect_raises(Mjollnir::PGError, /aborted/) { c.exec "select 1" }
        c.exec_all "rollback"
        c.in_transaction?.should be_false
        c.query_one("select 1", as: Int32).should eq 1
      end
    end
  end

  describe "prepared statements" do
    it "reuses the server-side statement across executions and argument types" do
      with_conn do |c|
        c.exec "create temp table t_prep (id int, v text)"
        20.times { |i| c.exec "insert into t_prep values ($1, $2)", i, i.odd? ? nil : "v#{i}" }
        20.times do |i|
          row = c.query_one("select id, v from t_prep where id = $1", i, as: {Int32, String?})
          row.should eq({i, i.odd? ? nil : "v#{i}"})
        end
        # same SQL, now with a NULL then an Int64 argument
        c.query_all("select id from t_prep where id = $1", nil, as: Int32).should eq([] of Int32)
        c.query_one("select id from t_prep where id = $1", 5_i64, as: Int32).should eq 5
        # only one named statement should exist for the select
        c.query_one("select count(*) from pg_prepared_statements where statement like 'select id, v from t_prep%'", as: Int64).should eq 1
      end
    end

    it "evicts the oldest statement beyond statement_cache_size and closes it on the server" do
      with_db(URL + "?statement_cache_size=3&max_pool_size=1") do |db|
        10.times { |i| db.exec "select #{i}::int" }
        db.exec_all "select 1" # the Close messages ride along with the next request
        db.query_one("select count(*) from pg_prepared_statements", as: Int64).should be <= 4
      end
    end

    it "re-prepares after the result shape changes (cached plan must not change result type)" do
      with_conn do |c|
        c.exec "create temp table t_ddl (a int, b int)"
        c.exec "insert into t_ddl values (1, 2)"
        c.query_one("select * from t_ddl", as: {Int32, Int32}).should eq({1, 2})
        c.exec "alter table t_ddl add column c int default 3"
        c.query_one("select * from t_ddl", as: {Int32, Int32, Int32}).should eq({1, 2, 3})
      end
    end

    it "works with prepared_statements=false (unnamed statement per execution)" do
      with_db(URL + "?prepared_statements=false") do |db|
        3.times { |i| db.query_one("select $1::int4 * 2", i, as: Int32).should eq i * 2 }
        db.exec("create temp table t_unp (id int)")
        db.query_one("select count(*) from pg_prepared_statements", as: Int64).should eq 0
      end
    end

    it "serves many concurrent fibers through the pool" do
      with_db(URL + "?initial_pool_size=4&max_pool_size=4") do |db|
        ch = Channel(Int64).new
        8.times do |f|
          spawn do
            sum = 0_i64
            200.times { |i| sum += db.query_one("select $1::int8 + $2::int8", f, i, as: Int64) }
            ch.send sum
          end
        end
        total = 0_i64
        8.times { total += ch.receive }
        expected = (0...8).sum { |f| (0...200).sum { |i| (f + i).to_i64 } }
        total.should eq expected
      end
    end
  end

  describe "pool" do
    it "limits connections and raises PoolTimeout when none is free" do
      with_db(URL + "?max_pool_size=1&checkout_timeout=0.2") do |db|
        db.with_connection do |_|
          expect_raises(Mjollnir::PoolTimeout) { db.scalar("select 1") }
        end
        db.scalar("select 1").should eq 1
        db.size.should eq 1
      end
    end

    it "wakes a waiting fiber when a connection is returned" do
      with_db(URL + "?max_pool_size=1&checkout_timeout=5") do |db|
        ch = Channel(Int32).new
        db.with_connection do |c|
          spawn { ch.send db.query_one("select 7", as: Int32) }
          sleep 0.05.seconds
          c.exec "select 1"
        end
        ch.receive.should eq 7
      end
    end

    it "discards a connection returned inside a transaction" do
      with_db(URL + "?max_pool_size=1") do |db|
        first = db.with_connection { |c| c.exec_all "begin"; c.backend_pid }
        second = db.with_connection { |c| c.backend_pid }
        second.should_not eq first
        db.query_one("select count(*) from pg_stat_activity where pid = $1", first, as: Int64).should eq 0
      end
    end

    it "replaces a connection whose backend was killed" do
      with_db(URL + "?max_pool_size=1") do |db|
        pid = db.with_connection(&.backend_pid)
        killer = Mjollnir.connect(URL)
        killer.exec "select pg_terminate_backend($1)", pid
        killer.close
        sleep 0.1.seconds
        expect_raises(Mjollnir::ConnectionLost) { db.scalar("select 1") }
        db.scalar("select 1").should eq 1 # the pool opened a fresh connection
      end
    end

    it "opens initial_pool_size connections eagerly" do
      with_db(URL + "?initial_pool_size=3&max_pool_size=5") do |db|
        db.size.should eq 3
        db.idle_size.should eq 3
      end
    end
  end

  describe "connection safety" do
    it "refuses to run a second statement while a result set is open" do
      with_conn do |c|
        rs = c.run_query("select g from generate_series(1, 10) g", Tuple.new)
        expect_raises(Mjollnir::Error, /busy/) { c.exec "select 1" }
        rs.close
        c.query_one("select 1", as: Int32).should eq 1
      end
    end

    it "raises ConnectionLost on a closed connection" do
      conn = Mjollnir.connect(URL)
      conn.close
      conn.closed?.should be_true
      expect_raises(Mjollnir::ConnectionLost) { conn.exec "select 1" }
    end
  end

  describe "query API" do
    it "accepts arguments as an Array with args:" do
      with_db do |db|
        db.query_one("select $1::int4 + $2::int4", as: Int32, args: [2, 3]).should eq 5
        db.exec("create temp table t_args (a int, b text)")
        db.exec("insert into t_args values ($1, $2)", args: [1, "x"]).rows_affected.should eq 1
        db.query("select a from t_args where b = $1", args: ["x"]) { |rs| rs.each { rs.read(Int32).should eq 1 } }
      end
    end

    it "supports query_one?, scalar and NoResultsError" do
      with_db do |db|
        db.query_one?("select 1 where false", as: Int32).should be_nil
        db.query_one?("select 4", as: Int32).should eq 4
        db.query_one?("select 4, 'a'", as: {Int32, String}).should eq({4, "a"})
        expect_raises(Mjollnir::NoResultsError) { db.query_one("select 1 where false", as: Int32) }
        expect_raises(Mjollnir::NoResultsError) { db.scalar("select 1 where false") }
        db.scalar("select 'x'").should eq "x"
      end
    end

    it "reads named tuples, enums and types with from_rs" do
      with_db do |db|
        db.query("select 1 as a, 'b' as b") do |rs|
          rs.move_next
          rs.read(a: Int32, b: String).should eq({a: 1, b: "b"})
        end
        db.query_one("select 'green'::text", as: Color).should eq Color::Green
        db.query_one("select 1::int4", as: Color).should eq Color::Green
        db.query_one("select null::text", as: Color?).should be_nil
        p = db.query_one("select 5, 'Freya'", as: Person)
        {p.id, p.name}.should eq({5, "Freya"})
      end
    end

    it "returns the block value and rows_affected from ResultSet" do
      with_db do |db|
        db.exec "create temp table t_ra (a int)"
        db.query("insert into t_ra values (1), (2) returning a") do |rs|
          rs.each { }
          rs.rows_affected.should eq 2
        end
        db.query("select 1") { |rs| rs.move_next; rs.read(Int32) }.should eq 1
      end
    end
  end

  describe "exec_many" do
    it "inserts many rows in pipelined chunks" do
      with_conn do |c|
        c.exec "create temp table t_many (id int primary key, v text)"
        rows = (1..2050).map { |i| [i, "row #{i}"] }
        r = c.exec_many("insert into t_many values ($1, $2)", rows, chunk_size: 500)
        r.rows_affected.should eq 2050
        c.query_one("select count(*), sum(id) from t_many", as: {Int64, Int64}).should eq({2050_i64, 2050_i64 * 2051 // 2})
        c.query_one("select v from t_many where id = 2050", as: String).should eq "row 2050"
      end
    end

    it "counts rows for updates and handles zero rows" do
      with_conn do |c|
        c.exec "create temp table t_many2 (id int, n int)"
        c.exec_many("insert into t_many2 values ($1, 0)", [[1], [2], [3]], chunk_size: 2).rows_affected.should eq 3
        c.exec_many("update t_many2 set n = $2 where id = $1", [[1, 10], [3, 30], [99, 0]]).rows_affected.should eq 2
        c.exec_many("update t_many2 set n = $2 where id = $1", [] of Array(Int32)).rows_affected.should eq 0
        c.query_all("select n from t_many2 order by id", as: Int32).should eq [10, 0, 30]
      end
    end

    it "rolls back a failed chunk and leaves the connection usable" do
      with_conn do |c|
        c.exec "create temp table t_many3 (id int primary key)"
        ex = expect_raises(Mjollnir::PGError) { c.exec_many("insert into t_many3 values ($1)", [[1], [2], [2], [3]], chunk_size: 100) }
        ex.code.should eq "23505"
        c.query_one("select count(*) from t_many3", as: Int64).should eq 0 # whole chunk was one implicit transaction
        c.query_one("select 1", as: Int32).should eq 1
        # earlier chunks stay committed
        expect_raises(Mjollnir::PGError) { c.exec_many("insert into t_many3 values ($1)", [[1], [2], [2], [3]], chunk_size: 2) }
        c.query_one("select count(*) from t_many3", as: Int64).should eq 2
      end
    end

    it "is atomic as a whole inside an explicit transaction" do
      with_conn do |c|
        c.exec "create temp table t_many4 (id int primary key)"
        c.exec_all "begin"
        c.exec_many("insert into t_many4 values ($1)", [[1], [2]], chunk_size: 1)
        c.exec_all "rollback"
        c.query_one("select count(*) from t_many4", as: Int64).should eq 0
      end
    end
  end

  describe "exec_all" do
    it "runs several statements in one round trip" do
      with_conn do |c|
        c.exec_all "create temp table t_all (a int); insert into t_all values (1); insert into t_all values (2)"
        c.query_one("select count(*) from t_all", as: Int64).should eq 2
        expect_raises(Mjollnir::PGError) { c.exec_all "select 1; select 1/0; select 2" }
        c.query_one("select 1", as: Int32).should eq 1
      end
    end
  end

  describe Mjollnir::ConnInfo do
    it "parses URIs" do
      i = Mjollnir::ConnInfo.from_uri(URI.parse("mjollnir://u:p%40ss@db.example:6543/app?sslmode=require&application_name=x&search_path=a&max_pool_size=3"))
      i.host.should eq "db.example"
      i.port.should eq 6543
      i.user.should eq "u"
      i.password.should eq "p@ss"
      i.database.should eq "app"
      i.sslmode.should eq Mjollnir::SSLMode::Require
      i.application_name.should eq "x"
      i.options.should eq({"search_path" => "a"})
    end

    it "treats a host starting with / as a unix socket directory" do
      i = Mjollnir::ConnInfo.from_uri(URI.parse("mjollnir://u@%2Fvar%2Frun%2Fpostgresql/app"))
      i.unix_socket?.should be_true
      i.host.should eq "/var/run/postgresql"
    end
  end
end
