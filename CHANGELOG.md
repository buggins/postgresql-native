# Changelog

All notable changes to postgresql-native are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
project uses [semantic versioning](https://semver.org/).

## Unreleased

### Added

- Repository scaffold (#1): dub package `postgresql-native` (module
  `postgresql`) on dbwire 0.6, CI on Linux, Windows and macOS with DMD and LDC
  down to frontend 2.097, integration test runners (threads, vibe.d fibers,
  vibe-core 1.x) against PostgreSQL 13, 14, 16 and 18, lint and documentation
  checks.
- Connecting (#2): the startup message (protocol 3.0, or 3.2 with
  `max_protocol_version=3.2`, negotiated down by older servers); TLS through
  SSLRequest or direct TLS (PostgreSQL 17+, ALPN `postgresql`) with libpq's
  `sslmode` values, certificate verification and client certificates;
  SCRAM-SHA-256 (with SASLprep), MD5 and cleartext passwords, `require_auth`
  and `channel_binding` options; connection strings as URIs and `key=value`
  with libpq's keywords; failover over several hosts; simple queries with
  streamed text rows, command tags and affected-row counts; errors and notices
  with all their fields; transaction status, run-time parameters reported by
  the server.
- Results and basic types (#3): `query` runs one statement with the extended
  protocol (parse and describe, then bind and execute) and requests the binary
  format for the types it decodes: `bool`, `int2`/`int4`/`int8`, `oid`,
  `float4`/`float8`, `numeric` (exact, as dbwire `Decimal` when it fits; NaN
  and infinities), text types, `bytea`, `"char"`, `uuid`, `json`/`jsonb`,
  `date`, `time`, `timetz`, `timestamp`, `timestamptz` (microseconds,
  infinities, BC years) and `interval`; other types come as text.
  `querySimple` keeps the simple protocol (several statements, text values).
  Typed getters on rows and values (`getString` gives the server's own text
  for every decoded type, `getLong`, `getDouble`, `getDecimal`, `getBytes`,
  `getDate`, `getDateTime`, `getSysTime`, `getTimeOfDay`, `getDuration`,
  `getInterval`, `getUUID`, `getVariant`, ...), which also parse text values.
- Parameters and statements (#4): `query`/`exec` with parameter values
  (`$1`... or `?`, rewritten outside quotes, dollar quotes and comments; `??`
  is a literal `?`; option `rewritePlaceholders`). Values are encoded for the
  parameter types the server infers: binary when the D type matches (integers
  range-checked, floats, `bool`, `bytea`, dates, times, timestamps,
  intervals, `uuid`), otherwise text the server parses (`Decimal`, strings
  for any type); `null`/`Nullable`/`Variant` supported. A per-connection
  statement cache (`statementCacheSize`, default 100; 0 for the unnamed
  statement) makes repeated SQL one round trip; evicted statements are closed
  with the next request, and statements invalidated by schema changes or
  `DISCARD ALL` are parsed again. `prepare` returns a `PreparedStatement`.
  `QueryResult.nextResult` moves through the result sets of a multi-statement
  `querySimple`.
- Statements in depth (#5): transactions (`begin` with isolation level,
  read-only and deferrable; `commit`, `rollback`, savepoints,
  `setSessionDefaults`, `inTransaction`, `transactionFailed`); `cancel()` from
  another thread or task through a CancelRequest on a second connection
  (encrypted like the session, protocol 3.2 keys included);
  `statementTimeout` (the server's `statement_timeout`); pipelines
  (`Connection.pipeline`): statements sent together, parsed in one round trip
  when new, answered in order, as one implicit transaction or independently.
