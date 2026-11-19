<img width="461 " height="307" alt="Mjölnir Lightning Impact" src="https://github.com/user-attachments/assets/d4a758e3-5fa5-4581-8d32-176db2a14a53" />

# Mjollnir

A standalone PostgreSQL driver for Crystal. It has **no dependencies** beyond
Crystal's standard library.

Mjollnir speaks the PostgreSQL v3 wire protocol directly and owns everything
above it: the connection pool, statement cache, transactions, type codecs and
query API. It is built around things Crystal does well: native-speed pointer code,
compile-time specialisation, cheap value types and fibers on one event loop.

```crystal
require "mjollnir"

Mjollnir.open("mjollnir://app:secret@localhost/appdb") do |db|
  db.exec "create table if not exists users (id int8 primary key, name text, tags text[])"
  db.exec "insert into users values ($1, $2, $3)", 1, "Thor", ["hammer", "thunder"]

  id, name, tags = db.query_one(
    "select id, name, tags from users where id = $1", 1,
    as: {Int64, String, Array(String)})
end
```

New here? Start with the [user guide (Docs.md)](Docs.md); this README is the technical reference.

**Status: v1.0.** Tested on PostgreSQL 16 with Crystal 1.11.2 on Linux. The spec
suite (66 examples) passes against a live server. Read [Limitations](#limitations)
before adopting it.

## Contents

- [Install](#install)
- [Usage](#usage)
- [Design](#design)
- [Type mapping](#type-mapping)
- [Benchmarks](#benchmarks)
- [Limitations](#limitations)
- [Development](#development)

## Install

```yaml
# shard.yml
dependencies:
  mjollnir:
    github: eyszu/mjollnir
```

Requires Crystal `>= 1.11.0, < 2.0.0`. OpenSSL is needed at link time (SCRAM
authentication and TLS), as for any Crystal program using `openssl`.

## Usage

### Opening

```crystal
# A pool, closed when the block ends. This is what you normally want.
Mjollnir.open(url) { |db| ... }

# A pool you manage yourself
db = Mjollnir.pool(url)
db.close

# A single connection (one fiber at a time)
Mjollnir.connect(url) { |conn| ... }
```

URL: `mjollnir://user:pass@host:5432/dbname?param=value`

| Parameter | Meaning |
|---|---|
| `host`, `port`, `user`, `password`, path | Standard. Fall back to `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`. |
| host `%2Fvar%2Frun%2Fpostgresql` (or `?host=/var/run/postgresql`) | Unix socket directory. |
| `sslmode` | `disable` (default), `prefer`, `require` (encrypt, no certificate check, like libpq), `verify-full` (verify chain and host name). |
| `application_name`, `connect_timeout` (seconds) | |
| `prepared_statements` | `true` (default) or `false`, see [Prepared statements](#prepared-statements). |
| `statement_cache_size` | Prepared statements kept per connection (default 256, least recently *created* evicted first). |
| `max_pool_size` (10), `initial_pool_size` (0), `max_idle_pool_size` (= max), `checkout_timeout` (seconds, 5) | Pool. |
| anything else (e.g. `search_path`, `statement_timeout`) | Sent to the server as a startup run-time parameter. |

Authentication: trust, cleartext, md5 and SCRAM-SHA-256.

### Queries

`Pool`, `Connection` and `Transaction` share one API. Parameters are `$1`, `$2`,
... and are passed as a splat, which keeps their exact types known at compile
time. For a dynamic list use `args:`.

```crystal
db.exec("update users set name = $1 where id = $2", "Odin", 1).rows_affected

name           = db.query_one("select name from users where id = $1", 1, as: String)
id, name       = db.query_one("select id, name from users limit 1", as: {Int64, String})
maybe          = db.query_one?("select name from users where id = $1", 99, as: String)  # nil if no row
all            = db.query_all("select id, name from users", as: {Int64, String})
first_col      = db.scalar("select count(*) from users")                                  # untyped

db.query("select id, name from users") do |rs|
  rs.each { id, name = rs.read(Int64, String) }
end

db.exec "insert into users values ($1, $2, null)", args: [3, "Freya"]    # dynamic argument list
```

`query_one` raises `Mjollnir::NoResultsError` when there are no rows.

**Reading rows.** `rs.read(T)` reads the next column as `T` (`T?` allows NULL);
`rs.read(A, B, C)` returns a Tuple; `rs.read(id: Int32, name: String)` returns a
NamedTuple; `rs.read` with no type returns the untyped `Mjollnir::Value` union.
Beyond the [built-in types](#type-mapping), `read` also accepts:

- an `enum` (from a text column by name, or an integer column by value);
- a `JSON::Serializable` type (parsed from a json/jsonb column);
- any class defining `self.from_rs(rs : Mjollnir::ResultSet)`, which builds
  itself from the next columns:

```crystal
class Person
  getter id : Int32, name : String
  def initialize(@id, @name); end
  def self.from_rs(rs : Mjollnir::ResultSet)
    new(rs.read(Int32), rs.read(String))
  end
end

people = db.query_all("select id, name from users", as: Person)
```

A result set holds its connection until it is finished or closed. `query` with a
block closes it for you; closing early discards unread rows safely. Running
another statement on the same connection while one is open raises
`Mjollnir::Error`.

### Transactions

```crystal
db.transaction do |tx|
  tx.exec "insert into users values ($1, $2, null)", 2, "Loki"
  tx.transaction { |inner| inner.rollback }        # nested = savepoint
  tx.exec "insert into users values ($1, $2, null)", 3, "Tyr"
end                                                # COMMIT
```

Use the yielded `tx` (not `db`) inside the block so queries join the
transaction. The block commits when it returns, rolls back and re-raises when it
raises, and rolls back and returns `nil` when it calls `tx.rollback`. A database
error inside a nested block rolls back to its savepoint, so the outer transaction
stays usable.

### Batch execution

`exec_many` runs one statement with many argument sets, pipelined in chunks:
one write and one round trip per chunk (default 500 rows) instead of one per row.

```crystal
rows = [[1, "a"], [2, "b"], [3, "c"]]
db.transaction { |tx| tx.exec_many("insert into t (id, name) values ($1, $2)", rows, chunk_size: 500) }
```

Each chunk is one implicit transaction. If a row fails (say a unique violation),
that chunk is rolled back, earlier chunks stay committed, and `Mjollnir::PGError`
is raised. Wrap the call in `transaction`, as above, to make the whole batch atomic.

### Several statements at once

```crystal
db.exec_all "create temp table t (a int); insert into t values (1); insert into t values (2)"
```

One round trip, no parameters, no rows returned.

### JSON

```crystal
struct Doc
  include JSON::Serializable
  getter id : Int32
  getter tags : Array(String)
end

doc = db.query_one("select doc from docs where id = $1", 1, as: Doc)         # typed, no JSON::Any
any = db.query_one("select doc from docs where id = $1", 1, as: JSON::Any)
db.exec "insert into docs values ($1, $2)", 2, doc                           # serializable or JSON::Any as parameter
```

### Errors and notices

```crystal
begin
  db.exec "insert into users values ($1, 'x', null)", 1
rescue ex : Mjollnir::PGError
  ex.code         # "23505"  (SQLSTATE)
  ex.constraint   # "users_pkey"
  ex.detail; ex.hint; ex.table; ex.column; ex.severity; ex.position
end

conn.on_notice { |n| Log.warn { n.message } }
```

| Error | Raised when |
|---|---|
| `PGError` | The server returned an error (all fields available). |
| `ConnectionRefused` | A connection could not be established. |
| `ConnectionLost` | An established connection failed or was already closed. |
| `PoolTimeout` | No connection became free within `checkout_timeout`. |
| `NoResultsError` | `query_one` or `scalar` found no rows. |
| `TypeMismatchError` | A column cannot be read as the requested type, or NULL was read into a non-nilable type. |
| `EncodeError` | An argument cannot be encoded for the server's parameter type, including out-of-range integers. |
| `AuthError`, `ProtocolError`, `Error` | Authentication failure, malformed server data, other driver errors. |

All inherit `Mjollnir::Error`. A server error never desynchronises the
connection: the driver reads up to ReadyForQuery before raising, so the
connection stays usable.

### Pool behaviour

Connections are opened lazily up to `max_pool_size`. A caller that finds none
free waits up to `checkout_timeout`, then gets `PoolTimeout`. A connection
returned in a failed state, inside an open transaction or with an open result
set is closed and replaced instead of reused. **Failed queries are never retried
automatically**: after a lost connection you get `ConnectionLost` and the next
call uses a fresh connection, but whether to re-run a statement whose outcome is
unknown is your decision.

Also available: `pool.size`, `pool.idle_size`, `conn.server_version`,
`conn.server_parameter("TimeZone")`, `conn.backend_pid`, `conn.in_transaction?`,
`rs.column_names`, `rs.column_oid(i)`.

## Design

### Reading: zero-copy and pointer-based

The socket is read in 128 KiB chunks into one reusable buffer and backend
messages are parsed in place. A DataRow is never copied or wrapped:
`ResultSet#read` walks its fields with a pointer and decodes on demand, so:

- skipping columns costs nothing, and a half-read row needs no cleanup;
- the only allocations are the values you ask for (a `String`, a `Time`...);
- big-endian reads use the shift-and-or form that LLVM turns into a load and a
  `bswap`, and are correct for unaligned addresses.

Typed reads decode directly to the requested type with no intermediate union.
Result columns are requested in **binary**; types with no binary codec fall
back to text for just those columns.

### Writing: one buffer, one syscall

Frontend messages are assembled in a reusable buffer and sent with a single
`write`. Execute and Sync are pre-serialised constants, and the per-column
result-format list is built once per statement.

### Compile-time specialised parameters

Parameters arrive as a splat, so their types are known at compile time and the
Bind message is generated with the loop unrolled per call site. Each argument is
encoded for the type the **server** reports for that parameter (so an `Int32`
goes correctly to an `int2`, `int8` or `float8`, range-checked), and a `String`
is accepted for any type and parsed by the server. Dynamic `args:` lists go
through a runtime path with the same encoders.

### Prepared statements

With the default `prepared_statements=true`, the first execution of a SQL string
on a connection sends Parse and Describe and keeps the statement on the server
under a short generated name. Later executions send only Bind, Execute and Sync,
in one write. Statements are cached per connection, looked up first by the
`String` object's address (SQL written as a literal is the same object on every
call, so no hashing is needed) and otherwise by content.

- If the server forgets a statement (SQLSTATE `26000`) or its result shape
  changes after DDL (`cached plan must not change result type`), the driver
  re-prepares and retries once, outside a failed transaction.
- Evicted and closed statements queue a Close that rides along with the next
  request, so it costs no round trip.
- **Costs and trade-offs:** the first use of each distinct SQL string takes two
  round trips instead of one. Named statements are **not safe behind
  transaction-pooling proxies** (e.g. pgbouncer in transaction mode); use
  `prepared_statements=false` there. That mode uses the unnamed statement and
  re-prepares on every execution (two round trips per query), and it is not
  faster than the alternative; see the benchmark below.

### Pipelining

`exec_many` writes a chunk of Bind/Execute pairs followed by one Sync, then reads
the replies. The chunk size bounds how much is in flight, so the server can
never block on a full socket while the client is still writing.

### What Crystal is used for

| Crystal strength | Used for |
|---|---|
| Native code, pointer ops, `@[AlwaysInline]` | In-place message parsing and decoding |
| Value types (structs, tuples) | `MsgReader`, field tuples and `Field` metadata cost no heap allocation |
| Compile-time dispatch and macros | Unrolled per-call-site parameter encoding; `read(T)` resolved per type |
| Cheap allocation | One `String`/`Array` per value requested, nothing else per row |
| Fibers on one event loop | No driver threads or locks beyond the pool's; one fiber uses a connection at a time |

I have measured which of these matters most in only one case (named prepared
statements; see below). The others are design choices whose individual
contribution is not isolated.

## Type mapping

| PostgreSQL | Crystal (read) | Crystal (write) |
|---|---|---|
| `bool` | `Bool` | `Bool` |
| `int2` / `int4` / `int8` | `Int16` / `Int32` / `Int64` (smaller ints widen to larger Crystal ints) | any `Int`, range-checked against the server type |
| `oid` | `Int64` | `Int` |
| `float4` / `float8` | `Float32` / `Float64` (`float4` also reads as `Float64`) | `Float32`, `Float64` |
| `numeric` | `Mjollnir::Numeric` (exact; `to_s`, `to_f64`) | `Mjollnir::Numeric`, `Int`, `Float`, or `String` |
| `text`, `varchar`, `bpchar`, `name` | `String` | `String` |
| `bytea` | `Bytes` | `Bytes` |
| `uuid` | `UUID` | `UUID` or `String` |
| `date`, `timestamp`, `timestamptz` | `Time` (UTC) | `Time` (sent as UTC), or `String` |
| `json`, `jsonb` | `JSON::Any`, `String`, `JSON::PullParser`, any `JSON::Serializable` | `JSON::Any`, `JSON::Serializable` |
| one-dimensional arrays of bool, int2/4/8, float4/8, text/varchar/bpchar, uuid | `Array(T)`, `Array(T?)` | `Array(...)`, binary where possible, otherwise an array literal |
| anything else (`inet`, `interval`, `money`, geometric, enums, ranges, ...) | `String` (text format) | `String` |

Notes:

- `±infinity` timestamps and dates raise `Mjollnir::Error`; cast them to text in SQL.
- A `Time` parameter is sent as an instant in UTC. Into a `timestamp` (without time
  zone) column it stores the UTC wall-clock time.
- Reading `NULL` into a non-nilable type raises `TypeMismatchError`.

## Benchmarks

Mjollnir was measured against [will/crystal-pg](https://github.com/will/crystal-pg)
0.31.0 (commit `03106f9`, 2026-10-22, the repository's HEAD when cloned).

**Method.** One file, `bench/workloads.cr`, is compiled twice with `--release`:
once with Mjollnir (its own API) and once with crystal-pg (through crystal-db,
which crystal-pg requires). The two APIs are call-compatible for everything the
workloads use, so the workload bodies are the same code; the differences are the
`require`, how the pool is opened, and two marked spots (below). Round 0 is a
discarded warmup (it also absorbs cold-cache reads), then 7 timed rounds;
within each round the two drivers alternate who runs first. Every workload returns
a checksum, and **all 11 checksums are identical between drivers**. Reported time
is the median; per-run data is in `bench/results.json`.

**Environment.** Intel Xeon @ 2.10 GHz, **2 cores**, 8 GB RAM, Ubuntu 24.04.5,
kernel 6.18.44, Crystal 1.11.2, PostgreSQL 16.15. Client and server run on the
**same machine over loopback TCP** and share those two cores. Neither binary uses
`-Dpreview_mt`. Run 2026-11-18.

| workload | what it does | Mjollnir (ms) | crystal-pg (ms) | speedup |
|---|---|---:|---:|---:|
| `select_one` | 20,000 × `select $1::int8` | 870 | 1,546 | **1.78x** |
| `point_lookup` | 20,000 × primary-key lookup, 3 columns | 1,008 | 2,268 | **2.25x** |
| `pool_8_fibers` | 8 fibers × 2,500 lookups, pool of 8 | 428 | 778 | **1.82x** |
| `insert_loop_10k` | 10,000 single-row inserts in one transaction | 491 | 754 | **1.54x** |
| `insert_50k` ¹ | 50,000 inserts in one transaction | 219 | 3,829 | **17.5x** |
| `jsonb_any_20k` | 20,000 jsonb rows → `JSON::Any` | 27.5 | 30.7 | 1.12x |
| `jsonb_typed_20k` ² | 20,000 jsonb rows → struct | 23.4 | 29.5 | 1.26x |
| `scan_ints_1M` | 1M rows × 3 ints | 225 | 229 | 1.02x |
| `scan_mixed_200k` | 200k rows: int, float, text, bool, timestamptz, uuid | 88.5 | 87.3 | 0.99x |
| `int_arrays_50k` | 50,000 `int4[]` (20 elements) | 57.7 | 51.9 | 0.90x |
| `scan_text_300k` | 300k rows × 3 text columns | 152 | 130 | **0.85x** |

Peak RSS over a whole run: 17.4 MB (Mjollnir), 16.8 MB (crystal-pg).

¹ **Not the same code on both sides.** Mjollnir uses its own `exec_many`;
crystal-pg has no batch API, so it runs the plain loop. This compares a Mjollnir
feature against crystal-pg's only option. `insert_loop_10k` is the like-for-like
insert comparison.
² Mjollnir parses the struct directly (`rs.read(Doc)`); crystal-pg uses its idiom
`Doc.new(rs.read(JSON::PullParser))`.

### What explains the round-trip wins

crystal-pg sends Parse, Bind, Describe, Execute and Sync in one round trip on the
unnamed statement for every query, so PostgreSQL re-parses the SQL each time
(confirmed in its source, `src/pg/statement.cr`). Mjollnir prepares once per
connection and then sends only Bind, Execute and Sync.

To test how much that matters, I reran the two round-trip workloads on Mjollnir
with `prepared_statements=false` (3 runs each, fresh process):

| workload | prepared (default) | `prepared_statements=false` | crystal-pg |
|---|---:|---:|---:|
| `select_one` | 857 / 953 / 868 ms | 1,777 / 1,847 / 1,773 ms | 1,546 ms |
| `point_lookup` | 1,065 / 1,094 / 1,025 ms | 2,468 / 2,344 / 2,150 ms | 2,268 ms |

So the speedup on those workloads **depends on reusing named prepared
statements**: without it Mjollnir is at or slightly behind crystal-pg. The
compile-time parameter encoding and pointer-based decoding are not isolated by
this test, so I can't say how much of the remaining difference they account for.

### How to read the rest

- **Bulk decoding is roughly a tie, and Mjollnir is behind on text.** Scans are
  dominated by PostgreSQL producing rows and by allocating result `String`s, which
  both drivers do. Mjollnir is about 15% slower on `scan_text_300k` and 10% on
  `int_arrays_50k`. I haven't found the cause. A candidate for the text case is that
  Mjollnir copies each value from its receive buffer into a new `String`, but I did
  not test that. The `scan_ints` and `scan_mixed` differences are inside
  run-to-run noise (stdev 14–48 ms).
- **JSON** was initially 0.67x. The cause was parsing from an `IO::Memory`: Crystal's
  IO-based JSON lexer is slower than its string-based one, so Mjollnir copies the
  JSON text into a `String` first. The 1.1–1.3x now is a few standard deviations at
  most (stdev 3–8 ms).
- **Noise.** Standard deviations on the round-trip workloads are 30–95 ms, so
  anything near 1.0x is inconclusive; the 1.5x and larger differences are well
  outside it.
- **Cold cache.** The first run after a PostgreSQL restart is badly slow for
  whichever driver goes first (I saw 1.8 s versus 0.2 s on `scan_ints_1M`). That
  is the database reading tables, not the driver; the warmup round exists for this.
- **Limits of the setup.** One machine with two cores shared by client and server,
  loopback only, one data set, Crystal 1.11.2 (not the newest release), 7
  repetitions. Over a real network each saved round trip would matter more and
  decode differences less. I'd expect that, but did not measure it.

### Reproducing

```sh
createdb mjol && psql mjol -f bench/seed.sql           # ~1.6M rows of seed data
export CRYSTAL_PATH=/usr/lib/crystal/lib:$PWD/src:/path/to/crystal-pg/src:/path/to/crystal-db/src
crystal build --release -Dmjollnir bench/workloads.cr -o bench/bench_mjollnir
crystal build --release            bench/workloads.cr -o bench/bench_pg
unset CRYSTAL_PATH
BENCH_DSN="user:pass@host/db" REPS=7 bench/run.sh      # writes bench/results.json, results.md
```

Only the crystal-pg build needs crystal-db and crystal-pg; Mjollnir needs neither.
If you use `shards` for the crystal-pg side, drop the `CRYSTAL_PATH` override.
(The override lists the standard library first because crystal-db ships a
`spec.cr` that would otherwise shadow Crystal's own `spec`.)
`BENCH_EXTRA="&prepared_statements=false"` appends URL parameters, as used above.

## Limitations

Not implemented in v1.0:

- `COPY`, `LISTEN`/`NOTIFY`, logical replication, large objects.
- Multi-dimensional arrays (clear error); arrays of other element types arrive as text.
- Binary codecs for `interval`, `inet`/`cidr`, `money`, geometric types, ranges,
  hstore: these arrive as `String`.
- Reading `±infinity` timestamps as `Time`.
- Client certificates, `.pgpass`, SASLprep normalisation of non-ASCII SCRAM passwords.
- Query cancellation; connection health checks and maximum connection lifetime in
  the pool.
- Compatibility with crystal-db code (`DB.open`, `DB::Serializable`, `DB.mapping`,
  `rs.read` on `DB::ResultSet`). Mjollnir's API is deliberately similar but is its own.
- Last-insert-id style results (PostgreSQL has none; use `RETURNING`).

Behavioural differences to know about:

- The first use of each distinct SQL string costs an extra round trip.
- Binary parameter encoding follows the server-declared type. An argument whose
  Crystal type has no binary form for that SQL type is sent as text via `to_s`,
  and the server decides whether it parses.
- A `Connection` is for one fiber at a time and is not safe to share; use the pool.
- Tested only against PostgreSQL 16 on Linux.

## Development

```sh
createdb mjol    # role mjol / password mjol, or set MJOLLNIR_URL
crystal spec
```

Optional spec environment variables:

| Variable | Enables |
|---|---|
| `MJOLLNIR_URL` | Connection URL for the main suite (default `mjollnir://mjol:mjol@127.0.0.1/mjol`) |
| `MJOLLNIR_MD5_URL`, `MJOLLNIR_CLEARTEXT_URL` | md5 and cleartext authentication specs (need matching `pg_hba.conf` rules) |
| `MJOLLNIR_TEST_UNIX` | Unix-socket spec |

The TLS spec expects a server with `ssl = on`.

```
src/mjollnir.cr          entry points: Mjollnir.open / pool / connect
src/mjollnir/
  queries.cr     the query API shared by Pool, Connection, Transaction
  pool.cr        fiber-safe connection pool
  connection.cr  session, statement cache, transactions
  statement.cr   prepare / bind / execute, exec_many, re-prepare logic
  result_set.cr  row streaming and typed reads
  wire.cr        protocol framing, startup/auth, zero-copy read buffer
  buffer.cr      big-endian primitives, write buffer, message reader
  scram.cr       SCRAM-SHA-256
  decode.cr      binary decoders        encode.cr   parameter encoders
  numeric.cr     exact numeric          oid.cr      type OIDs and column kinds
  conninfo.cr    URL parsing            error.cr    error classes
```

## License

MIT
