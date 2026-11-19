# Mjollnir User Guide

How to use Mjollnir, a standalone PostgreSQL driver for Crystal. This guide is
task-oriented: read it top to bottom once, then use the contents as a lookup.
For design details and benchmarks see [README.md](README.md).

## Contents

1. [Getting started](#1-getting-started)
2. [Connecting](#2-connecting)
3. [Running queries](#3-running-queries)
4. [Passing parameters](#4-passing-parameters)
5. [Reading results](#5-reading-results)
6. [Transactions](#6-transactions)
7. [Inserting lots of rows](#7-inserting-lots-of-rows)
8. [Working with specific types](#8-working-with-specific-types)
9. [Errors](#9-errors)
10. [The connection pool](#10-the-connection-pool)
11. [Production checklist](#11-production-checklist)
12. [Troubleshooting](#12-troubleshooting)
13. [Moving from crystal-pg / crystal-db](#13-moving-from-crystal-pg--crystal-db)
14. [Cheat sheet](#14-cheat-sheet)

---

## 1. Getting started

**Requirements:** Crystal 1.11 or newer (below 2.0), OpenSSL available at link
time, and a reachable PostgreSQL server. Mjollnir has no other dependencies.

**Add it to your project** in `shard.yml`, then run `shards install`:

```yaml
dependencies:
  mjollnir:
    github: eyszu/mjollnir          # or github: <your fork>/mjollnir
```

**Your first program:**

```crystal
require "mjollnir"

Mjollnir.open("mjollnir://app:secret@localhost/appdb") do |db|
  db.exec "create table if not exists users (id int8 primary key, name text)"
  db.exec "insert into users values ($1, $2)", 1, "Thor"

  name = db.query_one("select name from users where id = $1", 1, as: String)
  puts name # => Thor
end
```

`Mjollnir.open` with a block opens a connection pool, gives it to you as `db`,
and closes it when the block ends.

---

## 2. Connecting

### The URL

```
mjollnir://user:password@host:port/database?option=value
```

Missing parts fall back to the standard PostgreSQL environment variables
(`PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`). Percent-encode
special characters in the password (`p@ss` becomes `p%40ss`).

### Three ways to open

```crystal
# 1. A pool, closed automatically. Best for scripts and most programs.
Mjollnir.open(url) do |db|
  db.exec "select 1"
end

# 2. A pool you keep for the life of your program (e.g. a web server).
DB_POOL = Mjollnir.pool(url)
# ... use DB_POOL anywhere ...
DB_POOL.close # at shutdown

# 3. One connection, for a single fiber.
Mjollnir.connect(url) do |conn|
  conn.exec "select 1"
end
```

Use a pool whenever more than one fiber talks to the database. A single
`Connection` must only be used by one fiber at a time.

### URL options

| Option | Default | What it does |
|---|---|---|
| `sslmode` | `disable` | `disable`, `prefer`, `require`, or `verify-full`. See [TLS](#tls). |
| `application_name` | none | Shown in `pg_stat_activity`. |
| `connect_timeout` | none | Seconds to wait when connecting. |
| `max_pool_size` | 10 | Most connections the pool will open. |
| `initial_pool_size` | 0 | Connections opened immediately. |
| `max_idle_pool_size` | same as max | Idle connections kept; extras are closed. |
| `checkout_timeout` | 5 | Seconds to wait for a free connection. |
| `prepared_statements` | `true` | Set `false` behind transaction-pooling proxies. |
| `statement_cache_size` | 256 | Prepared statements kept per connection. |
| anything else | | Sent to PostgreSQL as a session setting, e.g. `search_path=app,public` or `statement_timeout=5000`. |

```crystal
url = "mjollnir://app:secret@db.internal/appdb" \
      "?application_name=billing&max_pool_size=20&statement_timeout=5000"
```

### Unix sockets

Percent-encode the socket directory as the host:

```crystal
Mjollnir.open("mjollnir://app:secret@%2Fvar%2Frun%2Fpostgresql/appdb") { |db| ... }
```

### TLS

- `sslmode=require` encrypts the connection but does **not** check the server's
  certificate (same as `psql`'s `require`). It protects against passive
  eavesdropping, not an active attacker.
- `sslmode=verify-full` also verifies the certificate chain and host name. Use
  this for anything crossing an untrusted network.
- `sslmode=prefer` uses TLS if the server offers it, otherwise plaintext.

### Authentication

Trust, cleartext password, md5 and SCRAM-SHA-256 (the PostgreSQL 14+ default)
are supported automatically; nothing to configure.

---

## 3. Running queries

Everything below works the same on a pool (`db`), a connection, or a
transaction (`tx`), so examples use `db`.

| Method | Use it to | Returns |
|---|---|---|
| `exec(sql, *params)` | Run a statement, ignore rows (INSERT/UPDATE/DELETE/DDL) | `ExecResult` with `rows_affected` |
| `query_one(sql, *params, as:)` | Get exactly one row | the row; raises `NoResultsError` if none |
| `query_one?(sql, *params, as:)` | Get one row or nothing | the row or `nil` |
| `query_all(sql, *params, as:)` | Get every row | `Array` |
| `scalar(sql, *params)` | Get the first column of the first row, untyped | a `Mjollnir::Value` |
| `query(sql, *params) { \|rs\| ... }` | Stream rows yourself | the block's value |
| `exec_all(sql)` | Run several `;`-separated statements, no parameters | `nil` |

```crystal
# Changes
result = db.exec("update users set name = $1 where id = $2", "Odin", 1)
puts result.rows_affected

# One row, as a single type or as a tuple of types
count = db.query_one("select count(*) from users", as: Int64)
id, name = db.query_one("select id, name from users limit 1", as: {Int64, String})

# Maybe one row
nick = db.query_one?("select name from users where id = $1", 99, as: String) # nil if missing

# Many rows
rows = db.query_all("select id, name from users order by id", as: {Int64, String})
rows.each { |id, name| puts "#{id}: #{name}" }

# Setup scripts: many statements, one round trip
db.exec_all <<-SQL
  create table if not exists a (id int);
  create table if not exists b (id int);
SQL
```

**Write queries as plain string literals when you can.** Mjollnir remembers each
distinct SQL string per connection and reuses the prepared statement. Building SQL
with interpolation (`"... where id = #{id}"`) creates a new statement every time
and fills the cache with one-off entries. Use `$1`, `$2` parameters instead.

---

## 4. Passing parameters

Use `$1`, `$2`, ... in the SQL and pass the values after it:

```crystal
db.exec "insert into users (id, name, active) values ($1, $2, $3)", 7, "Freya", true
```

Values are encoded for the type PostgreSQL expects, not just the Crystal type:

```crystal
db.exec "insert into t (small, big, ratio) values ($1, $2, $3)", 5, 5, 5 # int2, int8, float8
```

An integer that doesn't fit its column raises `Mjollnir::EncodeError` before
anything is sent.

**Any value can be passed as a `String`** and PostgreSQL parses it. This is the
easy way to handle types Mjollnir has no special support for:

```crystal
db.exec "insert into hosts (addr, seen) values ($1, $2)", "10.0.0.1", "2026-11-19"  # inet, date
db.exec "insert into items (kind) values ($1)", "weapon"                              # an enum
```

**`nil` is NULL:**

```crystal
db.exec "update users set nickname = $1 where id = $2", nil, 1
```

**Dynamic parameter lists** (when the number of parameters is only known at run
time) use `args:` with an array:

```crystal
ids = [1, 7]                                              # built at run time
placeholders = (1..ids.size).map { |i| "$#{i}" }.join(", ")
db.query_all("select name from users where id in (#{placeholders}) order by id",
  args: ids, as: String)
```

`args:` accepts any array of supported values. Prefer the normal splat form when
the parameters are fixed, because it is checked at compile time. (For a list of
values in an `IN` test, the array form below is simpler.)

**Lists in `WHERE ... IN`:** pass an array and use `= any(...)`:

```crystal
ids = [1, 2, 3]
db.query_all("select name from users where id = any($1)", ids, as: String)
```

---

## 5. Reading results

### Shortcuts

`as:` takes one type or a tuple of types, matching the selected columns in order:

```crystal
db.query_all("select id, name, score from players", as: {Int64, String, Float64})
```

### Streaming with `query`

Use `query` to process big results without holding them all in memory:

```crystal
total = 0_i64
db.query("select id, amount from payments") do |rs|
  rs.each do
    id, amount = rs.read(Int64, Int64)
    total += amount
  end
end
```

Inside the block:

- `rs.each { ... }` runs once per row. (Or loop with `while rs.move_next`.)
- `rs.read(T)` reads the next column as `T`. Use `T?` if the column can be NULL.
- `rs.read(A, B, C)` reads several columns into a tuple.
- `rs.read(id: Int64, name: String)` reads into a named tuple.
- `rs.read` with no type returns the value untyped.
- `rs.column_names`, `rs.column_count` describe the result.

Rows are read as you go, so you can stop early. Leaving the block discards the
rest safely.

### NULLs

Reading NULL into a non-nilable type raises `TypeMismatchError`. Ask for the
nilable type:

```crystal
name = db.query_one("select nickname from users where id = $1", 1, as: String?)
```

### Your own classes

Give a class a `from_rs` method that reads its columns in order, and use it as
the `as:` type:

```crystal
class User
  getter id : Int64
  getter name : String

  def initialize(@id, @name); end

  def self.from_rs(rs : Mjollnir::ResultSet)
    new(rs.read(Int64), rs.read(String))
  end
end

users = db.query_all("select id, name from users", as: User)
```

### Enums

A Crystal `enum` reads from a text column by name, or from an integer column by value.

```crystal
enum Role
  Admin
  Member
end

role = db.query_one("select role from users where id = $1", 1, as: Role)
```

### One rule: finish the result before running another query

A `ResultSet` holds its connection. Don't call `db`-level methods **from inside**
a `query` block expecting them to run on the same connection; with a pool they
take a different connection, which is fine, but on a single `Connection` or inside
a `transaction` it raises `Mjollnir::Error` ("connection is busy"). Collect what you
need first (`query_all`), then run the next query.

---

## 6. Transactions

```crystal
db.transaction do |tx|
  tx.exec "update accounts set balance = balance - $1 where id = $2", 100, 1
  tx.exec "update accounts set balance = balance + $1 where id = $2", 100, 2
end # COMMIT
```

- The block **commits** when it finishes normally.
- It **rolls back and re-raises** if anything inside raises.
- `tx.rollback` rolls back and ends the block quietly (the call returns `nil`).

**Always use `tx` (not `db`) inside the block.** Calls on `db` run on a different
connection and are not part of the transaction.

### Nested transactions

A `transaction` inside a `transaction` is a savepoint:

```crystal
db.transaction do |tx|
  tx.exec "insert into log values ($1)", "start"

  begin
    tx.transaction do |inner|
      inner.exec "insert into risky values ($1)", 1 # might violate a constraint
    end
  rescue ex : Mjollnir::PGError
    # only the inner part was undone; the outer transaction is still usable
  end

  tx.exec "insert into log values ($1)", "end"
end
```

### Returning a value

The block's value comes back out:

```crystal
new_id = db.transaction do |tx|
  tx.query_one("insert into users (name) values ($1) returning id", "Tyr", as: Int64)
end
```

(It is `nil` if the block called `tx.rollback`.)

### Keep transactions short

An open transaction holds a connection and any locks until it ends. Don't do
slow work (HTTP calls, big computations) inside one.

---

## 7. Inserting lots of rows

Calling `exec` once per row costs a network round trip each time. `exec_many`
sends rows in batches:

```crystal
rows = [[1, "Thor"], [2, "Odin"], [3, "Loki"]]

db.transaction do |tx|
  tx.exec_many("insert into users (id, name) values ($1, $2)", rows)
end
```

- Default batch is 500 rows (`chunk_size:` changes it).
- Each batch succeeds or fails as a unit. If any row fails, that batch is rolled
  back, batches already sent stay, and you get a `PGError`.
- **Wrap it in `transaction` to make the whole load all-or-nothing**, as above.
- `rows_affected` on the result is the total across batches.
- Works for UPDATE and DELETE too: one statement, many parameter sets.

For millions of rows, `COPY` would be faster, but Mjollnir doesn't support it yet.

---

## 8. Working with specific types

| PostgreSQL | Crystal | Notes |
|---|---|---|
| `bool` | `Bool` | |
| `int2`, `int4`, `int8` | `Int16`, `Int32`, `Int64` | A smaller column reads into a larger Crystal int (`int4` into `Int64`). The reverse raises. |
| `float4`, `float8` | `Float32`, `Float64` | |
| `numeric` | `Mjollnir::Numeric` | Exact. `to_s` gives the precise text, `to_f64` converts. |
| `text`, `varchar`, `char(n)` | `String` | |
| `bytea` | `Bytes` | |
| `uuid` | `UUID` | |
| `date`, `timestamp`, `timestamptz` | `Time` | Always UTC. |
| `json`, `jsonb` | `JSON::Any`, `String`, or your own `JSON::Serializable` type | |
| one-dimensional arrays | `Array(T)`, `Array(T?)` | bool, ints, floats, text, uuid. |
| anything else | `String` | `inet`, `interval`, `money`, enums, ranges, geometry... |

### Money and exact decimals

Don't read `numeric` into a float if exactness matters:

```crystal
price = db.query_one("select price from items where id = $1", 1, as: Mjollnir::Numeric)
puts price # exactly what PostgreSQL stores, e.g. 19.99
```

### Times

```crystal
created = db.query_one("select created_at from users where id = $1", 1, as: Time) # UTC
db.exec "update users set seen = $1 where id = $2", Time.utc, 1
```

A `Time` is sent as an exact instant. Infinite timestamps (`'infinity'`) raise an
error; cast them to text in SQL if your data has them
(`select created_at::text ...`).

### JSON

```crystal
struct Profile
  include JSON::Serializable
  getter theme : String
  getter langs : Array(String)
end

# Read straight into your type...
profile = db.query_one("select data from users where id = $1", 1, as: Profile)

# ...or as a generic value
any = db.query_one("select data from users where id = $1", 1, as: JSON::Any)
puts any["theme"]

# Write either kind
db.exec "update users set data = $1 where id = $2", profile, 1
```

### Arrays

```crystal
tags = db.query_one("select tags from posts where id = $1", 1, as: Array(String))
maybe = db.query_one("select scores from posts where id = $1", 1, as: Array(Int32?)) # NULL elements allowed

db.exec "update posts set tags = $1 where id = $2", ["crystal", "postgres"], 1
```

Multi-dimensional arrays aren't supported; they raise a clear error.

### Types without special support

Read as `String`, write as `String`:

```crystal
addr = db.query_one("select addr from hosts where id = $1", 1, as: String) # "10.0.0.1/32"
```

Or cast in SQL to something supported: `select duration::text`, `select ip::text`.

---

## 9. Errors

Everything Mjollnir raises inherits from `Mjollnir::Error`.

| Error | Meaning | Typical response |
|---|---|---|
| `PGError` | PostgreSQL rejected the statement | Inspect `code`, fix the data or SQL |
| `NoResultsError` | `query_one` or `scalar` found no row | Use `query_one?` |
| `TypeMismatchError` | Column can't be read as the requested type, or NULL into a non-nilable | Fix the type, add `?` |
| `EncodeError` | Argument doesn't fit the parameter, e.g. integer out of range | Fix the value |
| `PoolTimeout` | No free connection within `checkout_timeout` | Raise `max_pool_size` or find the slow caller |
| `ConnectionRefused` | Couldn't connect | Check host, port, credentials, TLS |
| `ConnectionLost` | The connection broke mid-use | Retry at your level if it is safe to |
| `AuthError` | Authentication failed or unsupported method | Check user, password, `pg_hba.conf` |

### Handling database errors by SQLSTATE

`PGError#code` is the five-character SQLSTATE, the stable way to react to a
specific failure:

```crystal
begin
  db.exec "insert into users (id, email) values ($1, $2)", 1, "a@example.com"
rescue ex : Mjollnir::PGError
  case ex.code
  when "23505" # unique_violation
    puts "already exists (constraint: #{ex.constraint})"
  when "23503" # foreign_key_violation
    puts "referenced row missing"
  when "40001", "40P01" # serialization_failure, deadlock_detected
    # safe to retry the whole transaction
  else
    raise ex
  end
end
```

Other useful fields: `message`, `severity`, `detail`, `hint`, `table`,
`column`, `constraint`, `position`.

After a `PGError` the connection is fine and keeps working (inside a
transaction, PostgreSQL itself refuses further statements until you roll back,
which `transaction` does for you).

### Retries

Mjollnir **never retries a failed query for you.** After `ConnectionLost` you
can't know whether the statement ran. The pool replaces the broken connection, so
the *next* call works, but whether to re-run is your decision. Retrying is safe
for reads and for transactions that hit `40001`/`40P01`; be careful with
anything that isn't idempotent.

### Server notices

```crystal
Mjollnir.connect(url) do |conn|
  conn.on_notice { |n| puts "NOTICE: #{n.message}" }
  conn.exec_all "do $$ begin raise notice 'hello'; end $$"
end
```

---

## 10. The connection pool

A pool opens connections on demand up to `max_pool_size` and lends one to each
call. When a fiber needs a connection and all are busy, it waits up to
`checkout_timeout` seconds, then gets `PoolTimeout`.

```crystal
db = Mjollnir.pool("mjollnir://app:secret@localhost/appdb?max_pool_size=10")

10.times do |i|
  spawn do
    puts db.query_one("select $1::int4 * 2", i, as: Int32)
  end
end
```

**Holding one connection across several calls.** Use `with_connection` when
several statements must run on the same session, such as work on a temporary
table (temporary tables live in one session):

```crystal
db.with_connection do |conn|
  conn.exec "create temp table scratch (n int)"
  conn.exec "insert into scratch values ($1)", 41
  conn.exec "update scratch set n = n + 1"
  total = conn.query_one("select sum(n) from scratch", as: Int64)
  conn.exec "drop table scratch"   # the session goes back to the pool, so tidy up
  total                            # => 42
end
```

**What the pool does for you:**

- A connection returned while still inside a transaction, or with an unfinished
  result set, is closed and replaced rather than handed to the next caller.
- Broken connections are discarded, not reused.
- Idle connections beyond `max_idle_pool_size` are closed.

**Inspect it:** `db.size` (connections open) and `db.idle_size`.

**Sizing:** each connection is a PostgreSQL backend process, so don't make the
pool bigger than you need. A few more connections than the number of fibers doing
concurrent database work is plenty. Remember PostgreSQL's own `max_connections`
limit when several services share one server.

**Shutdown:** call `db.close`. Idle connections close immediately; busy ones close
as they are returned.

---

## 11. Production checklist

- **Use `sslmode=verify-full`** across any network you don't fully control.
- **Set `application_name`** so you can recognise your connections in `pg_stat_activity`.
- **Set `statement_timeout`** (as a URL option) so a runaway query can't hang a
  connection forever.
- **Pick `max_pool_size` deliberately**, and set a `checkout_timeout` you can live with.
- **Use `$1` parameters, never string interpolation**, for values. It is both
  faster (statement reuse) and the way to avoid SQL injection.
- **Keep transactions short** and use `tx`, not `db`, inside them.
- **Wrap bulk loads in `transaction`** with `exec_many`.
- **Behind PgBouncer in transaction mode** (or any proxy that moves your session
  between server connections), add `prepared_statements=false`. Named prepared
  statements don't survive that. Expect lower speed in this mode, so prefer
  session pooling when you can.
- **Handle `ConnectionLost`** at the level where you know whether a retry is safe.
- **Close the pool on shutdown.**
- **Remember this is v0.1.** It has been tested against PostgreSQL 16 only;
  run your own tests against the server version you deploy. See "Not supported yet"
  in the README.

---

## 12. Troubleshooting

**`Mjollnir::ConnectionRefused`**
Nothing is listening, or TLS/startup failed. Check host and port, that PostgreSQL
accepts TCP (`listen_addresses`), and `sslmode`. The error message carries the
underlying cause.

**`Mjollnir::PGError ... password authentication failed` (code `28P01`)**
Wrong user or password. Also check the matching `pg_hba.conf` line and that you
percent-encoded special characters in the password.

**`Mjollnir::AuthError: server requested a password but none was given`**
The URL has no password and `PGPASSWORD` isn't set.

**`Mjollnir::PGError ... no pg_hba.conf entry` (code `28000`)**
The server isn't configured to accept this user, database, address or TLS mode.
Fix `pg_hba.conf` on the server.

**`Mjollnir::PoolTimeout`**
Every connection was busy for longer than `checkout_timeout`. Common causes: a
transaction left open or very slow, a `query` block that never finishes, or too
small a pool. Look in `pg_stat_activity` for `idle in transaction` sessions.

**`Mjollnir::Error: connection is busy: finish or close the open result set first`**
You ran a statement on a connection (or inside a `transaction`) while a `query`
block was still reading from it. Use `query_all` to collect rows first, or run
the second statement after the block.

**`Mjollnir::TypeMismatchError: column 0 (x) is NULL, which cannot be read as ...`**
The value is NULL. Read it as a nilable type (`String?`) or make the column
`NOT NULL`.

**`Mjollnir::TypeMismatchError: ... is int8 ..., which cannot be read as Int32`**
The column is wider than the type you asked for. Read as `Int64`.

**`Mjollnir::EncodeError: ... out of range for int2`**
You passed a value too large for the column the server expects.

**`PGError: ... prepared statement "mj1" does not exist` or `already exists`**
Almost always a proxy (PgBouncer in transaction mode) moving your session
between server connections. Use `prepared_statements=false`.

**`PGError: could not determine data type of parameter $1` (code `42P18`)**
PostgreSQL can't infer the type of a parameter that is only compared to NULL or
otherwise has nothing to infer from, such as `select $1 is null`. Cast it:
`select $1::int4 is null`.

**Queries slower than expected**
Check you are using literal SQL with parameters (not interpolated SQL), that the
pool isn't too small, and run `explain analyze` on the query itself; most slow
queries are the database's work, not the driver's.

---

## 13. Moving from crystal-pg / crystal-db

Mjollnir's API is intentionally close to crystal-db's, but it is a separate
library. Most code changes are mechanical.

| crystal-pg / crystal-db | Mjollnir |
|---|---|
| `require "pg"` | `require "mjollnir"` |
| `DB.open("postgres://...")` | `Mjollnir.open("mjollnir://...")` |
| `db.exec`, `db.query_one`, `db.query_all`, `db.scalar` | same names and argument style |
| `db.query(sql, args) { \|rs\| rs.each { rs.read(...) } }` | same |
| `db.transaction do \|tx\| tx.connection.exec ... end` | `db.transaction do \|tx\| tx.exec ... end` (`tx.connection` also exists) |
| `db.using_connection { \|conn\| ... }` | `db.with_connection { \|conn\| ... }` |
| `result.rows_affected` | same |
| `PG::Error`, `DB::Error` | `Mjollnir::PGError`, `Mjollnir::Error` |
| `include DB::Serializable` / `DB.mapping` | a `self.from_rs(rs)` method, see [Your own classes](#your-own-classes) |
| `db.query_each(sql) { ... }` | `db.query(sql) { \|rs\| rs.each { ... } }` |
| `Doc.new(rs.read(JSON::PullParser))` | `rs.read(Doc)` also works (the old form does too) |

Things that behave differently:

- **Statements are prepared and cached** per connection. First use of a query is
  one extra round trip; every repeat is cheaper. Behind a transaction-pooling
  proxy set `prepared_statements=false`.
- **No automatic retries.** crystal-db's pool retries some connection failures
  for you; Mjollnir raises `ConnectionLost` and leaves the decision to you.
- **`ConnectionLost`** replaces `DB::ConnectionLost`.
- **Type reads are stricter about NULL**: non-nilable reads of NULL raise
  `TypeMismatchError`.
- **Not available yet:** `COPY`, `LISTEN/NOTIFY`, and binary codecs for
  `interval`/`inet` (those come back as `String`).

---

## 14. Cheat sheet

```crystal
require "mjollnir"

# Open
Mjollnir.open(url) { |db| ... }        # pool, auto-closed
db = Mjollnir.pool(url); db.close      # pool you manage
Mjollnir.connect(url) { |conn| ... }   # single connection

# Run
db.exec(sql, *params)                  # => ExecResult (.rows_affected)
db.exec_all(sql)                       # several statements, no params
db.exec_many(sql, rows, chunk_size: 500)

# Read
db.query_one(sql, *params, as: T)      # one row, raises if none
db.query_one?(sql, *params, as: T)     # one row or nil
db.query_all(sql, *params, as: T)      # Array(T)
db.scalar(sql, *params)                # untyped first value
db.query(sql, *params) { |rs| rs.each { rs.read(Int32, String) } }

# `as:` accepts: Int32  String?  {Int64, String}  MyClass(from_rs)  MyEnum  MyJsonType

# Transactions (use tx inside)
db.transaction { |tx| tx.exec ...; tx.transaction { |inner| inner.rollback } }

# Errors
rescue ex : Mjollnir::PGError   # ex.code, ex.constraint, ex.detail ...
```

For the full type table, internals and benchmarks, see [README.md](README.md).
