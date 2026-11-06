# postgresql-native

A native client for **PostgreSQL** in D: the PostgreSQL frontend/backend
protocol over TCP, written in pure D, for ordinary threads (blocking sockets)
and vibe.d fibers. No libpq, no C libraries at build time.

> **Status: under development.** Nothing is released yet; the plan is tracked
> in the [roadmap issue](https://github.com/buggins/postgresql-native/issues/11).

Planned for the first release (0.1.0):

- PostgreSQL 13 to 18 (tested on each), and probably older servers;
- password logins with SCRAM-SHA-256 (including channel binding), MD5 or
  cleartext; TLS with certificate verification, libpq's `sslmode` values, and
  PostgreSQL 17's direct TLS;
- libpq-style connection strings (`postgresql://` URIs and `key=value`),
  `PG*` environment variables and `.pgpass`; several hosts with failover and
  `target_session_attrs`;
- queries and parameters (`$1`, `$2`, … or `?`), binary formats, a statement
  cache, transactions, cancellation, notices, pipelining;
- the common types, read and sent exactly: integers, floating point, `numeric`
  (as exact decimals), text, `bytea`, `bool`, `date`, `time`, `timestamp` and
  `timestamptz` (with microseconds), `interval`, `uuid`, `json`/`jsonb`;
- a connection pool and struct mapping, in thread and fiber mode.

Later: arrays, ranges, composite and enum types, network and geometric types,
`COPY`, `LISTEN`/`NOTIFY`, a [ddbc](https://github.com/buggins/ddbc) driver and
[hibernated](https://github.com/buggins/hibernated) support.

It builds on [dbwire](https://github.com/buggins/dbwire), the pure-D building
blocks shared with [clickhoused](https://github.com/buggins/clickhoused),
[mssql-native](https://github.com/buggins/mssql-native) and
[oracle-native](https://github.com/buggins/oracle-native): transports for
threads and fibers, TLS with OpenSSL loaded at run time, cryptography for the
password exchange, exact decimals, connection pools.

Requires a D frontend 2.097 or newer (DMD 2.097+, LDC 1.27+).

## Disclaimer

This is an unofficial project, not affiliated with, endorsed or sponsored by
the PostgreSQL Global Development Group. "PostgreSQL" and "Postgres" are
trademarks of the PostgreSQL Community Association of Canada. The client is an
independent implementation of the publicly documented PostgreSQL
frontend/backend protocol.

## License

[Boost Software License 1.0](LICENSE).
