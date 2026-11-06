# postgresql-native

A native client for **PostgreSQL** in D: the PostgreSQL frontend/backend
protocol over TCP, written in pure D, for ordinary threads (blocking sockets)
and vibe.d fibers. No libpq, no C libraries at build time.

> **Status: 0.1.0.** The API may still change before 1.0; the plan is tracked
> in the [roadmap issue](https://github.com/buggins/postgresql-native/issues/11),
> changes in the [changelog](CHANGELOG.md).

Add it to your `dub.json`:

```json
"dependencies": {
    "postgresql-native": "~>0.1.0"
}
```

```d
import postgresql;
import std.stdio;

void main()
{
    auto conn = new Connection("postgresql://app:secret@localhost/sales");
    // or "host=localhost dbname=sales user=app", or fromEnvironment() for the PG* variables
    scope (exit)
        conn.close();
    conn.exec("CREATE TABLE notes (id int PRIMARY KEY, text text)");
    conn.exec("INSERT INTO notes VALUES (?, ?)", 1, "first");
    foreach (row; conn.query("SELECT id, text FROM notes WHERE id >= $1 ORDER BY id", 1))
        writeln(row.getInt(0), " ", row.getString("text"));
}
```

Features:

- PostgreSQL 13 to 18 (tested on 13, 14, 16 and 18), protocol 3.0 and 3.2;
- password logins with SCRAM-SHA-256 (with SASLprep), MD5 or cleartext,
  `require_auth`; TLS with certificate verification, client certificates,
  libpq's `sslmode` values and PostgreSQL 17's direct TLS;
- libpq-style connection strings (`postgresql://` URIs and `key=value`) with
  libpq's keywords, the `PG*` environment variables, the password file
  (`~/.pgpass`), the default TLS files in `~/.postgresql`; several hosts with
  failover, `target_session_attrs` and `load_balance_hosts`;
- queries with parameters (`$1`, `$2`, … or `?`), binary formats, a statement
  cache, prepared statements, several result sets, transactions and
  savepoints, cancellation, `statement_timeout`, notices, pipelines;
- the common types, read and sent exactly: integers, floating point, `numeric`
  (as exact decimals), text, `bytea`, `bool`, `date`, `time`, `timetz`,
  `timestamp` and `timestamptz` (with microseconds), `interval`, `uuid`,
  `json`/`jsonb`; other types as text;
- struct mapping and a connection pool, in thread and fiber mode.

Later: arrays, ranges, composite types, network and geometric types, `COPY`,
`LISTEN`/`NOTIFY` helpers, a [ddbc](https://github.com/buggins/ddbc) driver
and [hibernated](https://github.com/buggins/hibernated) support. SCRAM channel
binding is implemented and switches on with the next dbwire release (it needs
the server's certificate from the TLS layer). GSSAPI, SSPI and Unix-domain
sockets are not supported.

It builds on [dbwire](https://github.com/buggins/dbwire), the pure-D building
blocks shared with [clickhoused](https://github.com/buggins/clickhoused),
[mssql-native](https://github.com/buggins/mssql-native) and
[oracle-native](https://github.com/buggins/oracle-native): transports for
threads and fibers, TLS with OpenSSL loaded at run time, cryptography for the
password exchange, exact decimals, connection pools.

Requires a D frontend 2.097 or newer (DMD 2.097+, LDC 1.27+).

## Tests

```sh
dub test                                   # unit tests, no server needed
docker run -d --name pgnative-18 -p 15418:5432 -e POSTGRES_USER=testuser \
    -e POSTGRES_PASSWORD=Test_password123 -e POSTGRES_DB=testdb postgres:18
POSTGRES_HOST=localhost:15418 POSTGRES_PASSWORD=Test_password123 \
    dub run :integration-tests-phobos      # or :integration-tests-vibe (vibe-core 2.x), :integration-tests-vibe1 (1.x)
```

`sh integration-tests/setup-server.sh pgnative-18` adds TLS and a user per
authentication method; then set `POSTGRES_SETUP=1` to run those tests too
(see [CONTRIBUTING.md](CONTRIBUTING.md)).

## Connecting

```d
auto conn = new Connection("postgresql://app@db1:5432,db2:5432/sales?sslmode=verify-full"
    ~ "&sslrootcert=/etc/ssl/db-ca.pem&target_session_attrs=read-write");
auto conn2 = new Connection("host=db1 dbname=sales user=app application_name=report");
auto conn3 = new Connection(fromEnvironment());   // PGHOST, PGUSER, PGDATABASE, PGSSLMODE, ...
```

Keywords are libpq's: `host`, `port` (several, comma-separated, for
failover), `dbname`, `user`, `password`, `passfile`, `options`,
`application_name`, `connect_timeout`, `sslmode` (`disable`, `allow`,
`prefer` (the default), `require`, `verify-ca`, `verify-full`),
`sslnegotiation`, `sslrootcert` (`system` for the system's store), `sslcert`,
`sslkey`, `sslpassword`, `ssl_min_protocol_version`,
`ssl_max_protocol_version`, `channel_binding`, `require_auth`,
`max_protocol_version`, `target_session_attrs` (`any`, `read-write`,
`read-only`, `primary`, `standby`, `prefer-standby`), `load_balance_hosts`
(`disable`, `random`); and this library's `statement_cache_size`,
`rewrite_placeholders`, `io_mode`. `ConnectionOptions` has them all as fields,
plus the timeouts, `statementTimeout` and run-time parameters for the startup
message.

`ConnectionOptions.parse` reads only the string; `fromEnvironment` starts from
the `PG*` variables, as `psql` does. Without a password, one from the password
file is used when the server asks (`passfile`, `PGPASSFILE`, else
`~/.pgpass`; `%APPDATA%\postgresql\pgpass.conf` on Windows). The TLS files
default to `root.crt`, `postgresql.crt` and `postgresql.key` in
`~/.postgresql` when they exist; with `root.crt`, `sslmode=require` verifies
the certificate. When no CA is given, `verify-ca` and `verify-full` use the
system's trusted certificates.

Without TLS (`sslmode=disable`, or `prefer` with a server without TLS), the
session travels in clear; SCRAM still keeps the password itself off the
network.

## Parameters and statements

```d
conn.exec("UPDATE notes SET text = ? WHERE id = ?", "1st", 1);       // ? becomes $1, $2
auto r = conn.query("SELECT * FROM notes WHERE id = ANY($1::int[])", "{1,2}");
const n = conn.exec("DELETE FROM notes WHERE text IS NULL");          // simple protocol, rows affected

auto stmt = conn.prepare("INSERT INTO notes VALUES ($1, $2)");
foreach (i; 2 .. 10)
    stmt.exec(i, "note");
```

Values are encoded for the parameter types the server infers from the SQL:
binary when the D type matches the column type (integers, with range checks;
floats; `bool`; `ubyte[]` for `bytea`; `Date`, `TimeOfDay`, `DateTime`,
`SysTime`, `Duration`, `Interval`, `UUID`), otherwise as text the server
parses (`Decimal`, strings for any type, `json`); `null` and `Nullable` send
NULL, `Variant` its value. Integer enums go as their value to numeric
parameters and as their member name to others (text, PostgreSQL enum types).
Add a cast (`$1::int8`) where the server can't infer a type. `?` is rewritten
outside quotes, comments and dollar quotes; write `??` for a literal `?`, or
switch the rewriting off (`rewrite_placeholders=false`) for jsonb's `?`
operators.

Statements with parameters are kept prepared per connection, by SQL text
(`statement_cache_size`, default 100; 0 behind PgBouncer in transaction mode
before 1.21), so running one again takes one round trip.

## Transactions, cancel, pipelines

```d
conn.begin(IsolationLevel.serializable);
conn.exec("INSERT INTO notes VALUES (?, ?)", 20, "x");
conn.savepoint("sp");
conn.rollbackTo("sp");
conn.commit();

// from another thread or vibe.d task: stops the running statement (SQLSTATE 57014)
conn.cancel();

auto p = conn.pipeline();                        // one round trip for all
p.add("INSERT INTO notes VALUES (?, ?)", 30, "y");
const q = p.add("SELECT count(*) FROM notes");
auto results = p.run();                          // one implicit transaction; PipelineMode.independent: each on its own
writeln(results[q].rows[0].getLong(0));
```

## Structs

```d
struct Order
{
    int id;
    @column("customer_name") string customer;
    Decimal amount;
    Nullable!DateTime shipped;
    Status status;                               // a D enum: PostgreSQL enum or text by name, integers by value
    @ignore string note;
}

conn.insert("orders", orders);                   // multi-row INSERTs, atomic
foreach (o; conn.query!Order("SELECT * FROM orders WHERE amount > ?", 5))
    writeln(o.customer, " ", o.amount);
auto first = conn.queryRow!Order("SELECT * FROM orders WHERE id = ?", 1);
auto total = conn.queryValue!long("SELECT count(*) FROM orders");
```

Fields map to columns by name (exact, else ignoring case); extra result
columns are ignored. `insert` writes up to 1000 rows per statement; outside a
transaction block, an insert of several statements runs in a transaction of
its own. Column names that are plain identifiers are folded to lower case, as
PostgreSQL folds unquoted names.

## Connection pool and vibe.d

```d
auto pool = new ConnectionPool("postgresql://app:secret@db/sales?pool_max=8");
{
    auto conn = pool.lockConnection();   // waits while all 8 are in use
    conn.exec("UPDATE stats SET hits = hits + 1");
}                                        // back to the pool
```

The same code runs in threads (blocking sockets) and in vibe.d tasks, where
waiting for the server suspends only the task: the I/O mode follows the
caller (`ConnectionOptions.ioMode`). A returned connection gets its session
reset (`Connection.resetSession`: an open transaction rolled back, settings,
temporary tables, advisory locks and `LISTEN`s cleared) while its prepared
statements stay. Pool keywords: `pool_max`, `pool_wait_timeout`,
`pool_max_idle_time`, `pool_max_lifetime`, `pool_ping_after_idle`. See
`examples/` (`dub run :example-basic`, `dub run :example-vibe`).

## Reading values

`Row` getters convert a column to D types (`getLong`, `getInt`, `getBool`,
`getDouble`, `getDecimal`, `getString`, `getBytes`, `getDate`,
`getTimeOfDay`, `getDateTime`, `getSysTime`, `getMicrosecondsOfSecond`,
`getDuration`, `getInterval`, `getUUID`, `getVariant`), by index or column
name. NULL throws, except for `getString`, `getBytes` and `getVariant`
(`isNull` tells).

| PostgreSQL type | Natural D type (`getVariant`) | Notes |
|---|---|---|
| `int2`, `int4`, `int8`, `oid` | `short`, `int`, `long`, `uint` | |
| `numeric` | `Decimal` (exact, 76 digits) | NaN, infinities and longer values: `getString` |
| `float4`, `float8` | `float`, `double` | text: shortest exact, as the server writes it |
| `text`, `varchar`, `char(n)`, `name` | `string` | UTF-8 |
| `bytea` | `ubyte[]` | text: `\x…` hexadecimal |
| `bool` | `bool` | text `t` / `f` |
| `date` | `Date` | infinities: `getString` |
| `time` / `timetz` | `TimeOfDay` / `string` | microseconds with `getMicrosecondsOfSecond` |
| `timestamp` | `DateTime` | microseconds with `getMicrosecondsOfSecond`, `getSysTime` (UTC) |
| `timestamptz` | `SysTime` | text in the session's `TimeZone` |
| `interval` | `Interval` (months, days, microseconds) | `getDuration` when it has no months |
| `uuid` | `UUID` | |
| `json`, `jsonb`, other types | `string` | the server's text |

`getString` gives exactly the text PostgreSQL prints for every type. Time
zones use the system's time zone database (Windows has none: `timestamptz`
text then shows UTC).

## Disclaimer

This is an unofficial project, not affiliated with, endorsed or sponsored by
the PostgreSQL Global Development Group. "PostgreSQL" and "Postgres" are
trademarks of the PostgreSQL Community Association of Canada. The client is an
independent implementation of the publicly documented PostgreSQL
frontend/backend protocol.

## License

[Boost Software License 1.0](LICENSE).
