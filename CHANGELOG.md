# Changelog

All notable changes to postgresql-native are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
project uses [semantic versioning](https://semver.org/).

## Unreleased

### Added

- `hostaddr` (and `PGHOSTADDR`, `ConnectionOptions.hostAddress`, #19):
  connect to numeric addresses while the host names serve TLS name checks,
  the password file and messages (`Connection.host` is the name,
  `Connection.address` the address); one address per host for failover.
- Connection services (#19): `service` and `servicefile` keywords,
  `PGSERVICE` and `PGSERVICEFILE`; `pg_service.conf` sections from the
  user's file, then the system's (`PGSYSCONFDIR`). The service's keywords
  come after the connection string's and before the environment's, as in
  libpq.
- Unix-domain sockets (#19): a host that starts with `/` is the server's
  socket directory (`host=/var/run/postgresql` connects to
  `/var/run/postgresql/.s.PGSQL.5432`; in URIs percent-encoded,
  `postgresql://%2Fvar%2Frun%2Fpostgresql/db`), one that starts with `@` a
  Linux abstract socket (thread mode only). In thread and fiber mode, with
  failover between sockets and TCP hosts; cancel requests use the socket
  too. As in libpq, TLS is never used over a socket, whatever `sslmode`
  says. The default host stays `localhost` over TCP. A socket directory also
  matches `localhost` lines of the password file.
- `requirepeer` (and `PGREQUIREPEER`, `ConnectionOptions.requirePeer`, #19):
  the operating-system user the server must run as, checked on Unix-domain
  sockets.
- Certificate revocation lists (#19): `sslcrl` and `sslcrldir` (and
  `PGSSLCRL`, `PGSSLCRLDIR`, `ConnectionOptions.tls.crlFile`/`crlDir`);
  `~/.postgresql/root.crl` by default when it exists. The server's whole
  certificate chain is checked, as in libpq.

### Changed

- Requires dbwire 0.8 (CRLs, Unix-domain sockets).

## 0.4.0 (2026-11-06)

### Added

- SCRAM-SHA-256-PLUS channel binding (`tls-server-end-point`, #13): over
  TLS, logins bind the SCRAM exchange to the server's certificate, so a man
  in the middle with another certificate can't relay them.
  `channel_binding=prefer` (the default) uses it when the server offers it,
  `require` refuses logins without it, `disable` never uses it.
  `Connection.authMethod` reports `scramSha256Plus`.

### Changed

- dbwire 0.7 (`~>0.7.0`).
- `waitForNotification` waits on the socket (dbwire's `waitForData`)
  instead of checking every few milliseconds: a notification is returned as
  soon as it arrives.
- `timestamptz` text and `SysTime` local times follow the tz database's rules
  everywhere: the local mean time before a zone's first transition (e.g.
  Asia/Kathmandu before 1920) and daylight saving time after 2037 (from
  dbwire 0.7, buggins/dbwire#33). The integration tests compare them with the
  server's text from 1850 to 2200. Client and server each use their own tz
  database: when their tzdata releases differ, historical values revised in
  between (rare after 1970) differ too.

## 0.3.0 (2026-11-06)

### Added

- Parameter values known only at run time, for drivers such as ddbc's
  (#24): `Connection.query(sql, Variant[])`, `exec(sql, Variant[])`,
  `PreparedStatement.query(Variant[])` and `exec(Variant[])`; an empty
  `Variant` or `null` is NULL; `byte[]` values are sent as `bytea`.

### Changed

- Values of text types (`text`, `varchar`, `char(n)`, `name`, enums,
  `citext`) are read by the other getters as text-format values are:
  `getLong` of `'17'`, `getBool` of `'t'`, `getDate` of `'2026-11-06'`
  (before, only text-format values were parsed).

### Fixed

- `get!ulong` and the other unsigned integer conversions accepted negative
  values (a signed/unsigned comparison).

## 0.2.0 (2026-11-06)

### Added

- COPY and LISTEN/NOTIFY (#8): `copyIn` (`CopyIn`: raw `write`, `writeRow`
  and `writeStruct` in text, CSV and binary formats, 64 KiB messages, server
  errors noticed while writing, `finish`, `abort`), `copyInto` (column types
  looked up for binary rows), `copyInsert` (structs by binary COPY);
  `copyOut` (`CopyOut`: chunks, `readAll`/`readText`, rows parsed from text,
  CSV and binary data, `columnTypes` for typed getters); `listen`,
  `unlisten`, `unlistenAll`, `notify`, `pollNotifications`,
  `waitForNotification` (timeout, thread and fiber mode), `onNotification`.
- More types (#7): arrays of any element type and dimensions (lower bounds,
  NULL elements), ranges and multiranges, composite types and records,
  enums, domains, `inet`/`cidr`, `macaddr`/`macaddr8`, `bit`/`varbit`, the
  geometric types, `pg_lsn`, `hstore`, `citext`, PostGIS
  `geometry`/`geography`, decoded from binary with `getString` equal to the
  server's text; `money`, `xml`, `tsvector`, `tsquery` and the rest stay
  text. Types of the database are looked up in `pg_type` once per connection
  (`ColumnInfo.type`, `PgType`, `clearTypeCache`). `Value.get!T` (and
  `Row.get!T`) converts to any supported D type: D arrays (nested for more
  dimensions), `Range!T`, structs from composite values, `Inet`,
  `BitString`, `Point`..., `string[string]`; new getters `getArray`,
  `getRange`, `getMultirange`, `getRecord`, `getInet`, `getBitString`,
  `getHstore`. The same types work as parameters and in struct mapping.

### Changed

- Values of `inet`, `cidr`, `macaddr`, `macaddr8`, `bit`, `varbit`, the
  geometric types, `pg_lsn`, arrays, ranges, multiranges, composite types
  and enum arrays now come in binary format (`ColumnInfo.format`); their
  `getString` is unchanged (the server's text). `getVariant` holds `Inet`,
  `BitString` and the geometric structs for those types instead of their
  text, and `getBytes` of a `macaddr`/`macaddr8` gives its 6 or 8 bytes.
- The struct mapping attributes (`@column`, `@ignore`) moved to
  `postgresql.attributes`; `postgresql.mapping` and `postgresql` still
  export them.

### Fixed

- A notice or notification arriving alone, while the connection was idle or
  during `COPY FROM STDIN`, made the reader wait for another message.

## 0.1.0 (2026-11-06)

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
- High-level API, pool, connection strings (#6): struct mapping
  (`query!T`, `queryRow!T`, `queryValue!T`, `insert` with multi-row `INSERT`s
  of up to 1000 rows, atomic; `@column`, `@ignore`; enums by name or value,
  `Nullable`, `Variant`); `ConnectionPool` for threads and vibe.d fibers on
  dbwire's `PoolCore` (`pool_*` keywords), with `Connection.resetSession` on
  release (as `DISCARD ALL`, keeping the statement cache);
  `fromEnvironment` (the `PG*` variables, `PGTZ`); the password file
  (`passfile`, `~/.pgpass`); the default TLS files in `~/.postgresql`;
  `target_session_attrs`, `load_balance_hosts`, `ssl_min_protocol_version`,
  `ssl_max_protocol_version`; URIs with a user but no host
  (`postgresql://user@/db`). Integer enums are sent by name to non-numeric
  parameters. Examples for threads and vibe.d.
