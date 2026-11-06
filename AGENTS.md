# AGENTS.md

Guidance for AI coding agents working on **postgresql-native**, a native D client for PostgreSQL.

## Project at a glance

- **What:** a pure-D client for PostgreSQL over the **frontend/backend protocol 3.x** (TCP, port 5432; TLS through SSLRequest or direct TLS), for PostgreSQL 13–18 (tested; older servers probably work), with blocking (thread) and vibe.d (fiber) I/O. dub package `postgresql-native`, root module `postgresql`.
- **Repo:** `git@github.com:buggins/postgresql-native.git`, default branch `main`. Author Vadim Lopatin (GitHub `buggins`). License BSL-1.0.
- **Status:** under development; roadmap issue #11 lists milestones P0–P9 (one issue each, #1–#10). P0 (scaffold) and P1 (connect, TLS, authentication, simple queries) done.
- **Builds on dbwire** (`../dbwire`, 0.6): `dbwire:types` (exceptions, `Decimal`), `:io` (transports, I/O backends, buffers), `:tls` (OpenSSL loaded at run time; ALPN for direct TLS), `:client` (DSN, failover, pool core), `:crypto` (PBKDF2 for SCRAM, secure random). Anything not protocol-specific is added to dbwire (issue + PR there), not here.
- **Sibling projects:** `../oracle-native` and `../mssql-native` (the closest models: message layer over a byte stream, result streaming, parameters, pool, mapping, tests) and `../clickhoused`. Follow their structure, API style, tests and conventions (their `AGENTS.md`).
- **`PLAN.md` (local and optional):** the design plan (protocol overview, types, API, milestones, decisions) is a local, untracked file (excluded through `.git/info/exclude`). If present, read it before design-level changes and keep it up to date; never `git add` it.

## Workflow

- **Every change goes through an issue and a pull request. Never push to `main` directly.** One feature branch per issue; the PR says `Closes #N`. The author merges.
- Commit, push and open PRs only when the user asks. Releases and tags only on request (version constants in `source/postgresql/package.d` and `CHANGELOG.md`; the author pushes the `vX.Y.Z` tag).

## Key design rules

1. **Pure D, zero C dependencies by default.** OpenSSL is loaded at run time through dbwire for TLS only; SCRAM and MD5 use Phobos and dbwire's pure-D crypto. No libpq.
2. **Dual I/O.** Anything that can block goes through dbwire's `IoBackend`/`Transport`; never call `std.socket`, `core.sync`, `Thread.sleep` or vibe APIs from protocol, connection or pool code. vibe code under `version (Have_vibe_core)`.
3. **Runtime interfaces, not templates**, for what a `Connection` holds; `Connection` stays one non-templated class (for the ddbc driver).
4. **Connection invariants** (as in the sibling projects): one call at a time; a result holds the connection until drained or closed; cancel is the only call allowed from another thread or task; a broken stream or a FATAL error poisons the connection, which is never returned to a pool.
5. **Robust decoding:** malformed or truncated input throws `ProtocolException`; never crash, never allocate from an unchecked length (message lengths come from the server).
6. **Version checks:** behaviour that depends on the server (protocol 3.2 on 18, direct TLS on 17, numeric ±Infinity on 14, `in_hot_standby` on 14, ...) is checked against the negotiated protocol version or `server_version`, with constants named after the release.
7. **Text:** the client always sends `client_encoding=UTF8` (and `DateStyle=ISO`), so all text is UTF-8.

## Licensing rules (important)

- **The protocol is publicly documented** (PostgreSQL manual, "Frontend/Backend Protocol" and "Message Formats"). Write from the manual and from facts verified against real servers (golden bytes). The binary formats of the types are the server's `*send`/`*recv` functions: facts may be taken from the server source (PostgreSQL License), not code.
- **Other clients are reference only — never copy or translate their code:** libpq (PostgreSQL License), pgx (MIT), Npgsql (PostgreSQL License), pgjdbc (BSD-2-Clause), asyncpg (Apache-2.0), psycopg (LGPL). Line-by-line translation counts as copying. Wire-format facts are fine to reproduce.
- **`buggins/postgresql-native-old`** (2016) is a translation of pgjdbc: never use it, not even as a reference.
- If any third-party code or data seems necessary, **stop and ask the user first**.
- The README says the project is unofficial and not affiliated with the PostgreSQL Global Development Group, and notes the trademark.

## Decisions (2026-11-06)

PostgreSQL 13–18 tested (CI on 13, 14, 16, 18); default `sslmode=prefer` as libpq (verify-ca/verify-full verify the certificate); native `$n` placeholders plus `?` rewritten to `$n` outside quotes, dollar quotes and comments (on by default, can be switched off for the jsonb `?` operators); binary formats for the built-in types; `numeric` as dbwire `Decimal` when it fits (longer values: dbwire decimal types later); the ddbc driver becomes a new configuration beside ddbc's libpq one.

## Commands

The recipe format is **`dub.json`**.

```sh
dub build                                                  # library
dub test                                                   # unit tests
dub run dscanner@0.15.2 -- --styleCheck .                  # lint (CI fails on any warning)
dub run dfmt@0.15.2 -- --inplace $(git ls-files '*.d')     # format (CI fails if this changes files)
dub build -b docs                                          # docs into /docs/ (git-ignored)
dub run :integration-tests-phobos                          # integration tests, threads
dub run :integration-tests-vibe                            # the same tests in vibe.d tasks
dub run :integration-tests-vibe1                           # ... with vibe-core 1.x
POSTGRES_HOST=localhost:15418 POSTGRES_PASSWORD=Test_password123 dub run :integration-tests-phobos
sh integration-tests/setup-server.sh pgnative-18      # TLS + a user per authentication method, then add:
POSTGRES_SETUP=1
```

Integration tests: a `void function()` that throws on failure in an `integrationtests.*` module, listed in `allTests` (`integration-tests/source/integrationtests/harness.d`); mode-specific ones in `threadTests` (`integration-tests-phobos/source/threadtests.d`) and `vibeTests` (`integration-tests-vibe/source/vibetests.d`). The server comes from `POSTGRES_HOST` (`host:port`), `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` (`integrationtests.server`); these are deliberately not libpq's `PG*` variables, which the library reads as defaults.

Run lint and format before committing D code. dfmt 0.15.2 mangles lambdas with attributes (`() nothrow {` → `() nothrow{`): use named nested functions. It merges `@safe return` into `@safereturn`: avoid the `return` attribute. Run dfmt twice when it changes files. `dub.selections.json` files are git-ignored (a root one listing vibe-core would enable vibe support silently).

`integration-tests/setup-server.sh <container>` prepares a server of the official image: TLS with the test certificates in `integration-tests/tls` (CA `ca.pem`, server certificate for `localhost` and `127.0.0.1`, client certificate `CN=certuser`, an unrelated `other-ca.pem`), users `scramuser`, `md5user`, `clearuser` (passwords `<name>_pw`), `trustuser`, `tlsuser` (hostssl only), `certuser` (client certificate), `saslpuser` (a password SASLprep changes), and the matching `pg_hba.conf`. Tests that need it run when `POSTGRES_SETUP=1` (CI sets it).

## Layout

```
source/postgresql/
  package.d            public imports, version constants, postgresqlHasVibe
  connection.d         Connection: hosts/failover, SSLRequest or direct TLS, startup, authentication,
                       simple query (exec, query), response reading, async messages (notices, ParameterStatus,
                       notifications), close; AuthMethod, Notification
  auth.d               SCRAM-SHA-256 client (+ -PLUS data: tls-server-end-point), MD5, SASLprep
  settings.d           ConnectionOptions, SslMode, ...; URI and key=value parsing (libpq keywords), require_auth
  result.d             ColumnInfo (RowDescription), Row (text values for now), QueryResult (streamed rows)
  exception.d          ServerMessage (error/notice fields), ServerException + dbwire's exceptions
  protocol/            codes.d (message types, auth codes, request codes), messages.d (framing: Message,
                       MessageBody, MessageBuilder, MessageStream)
integration-tests/     shared harness (dub subpackage `:integration-tests`), setup-server.sh, tls/ (test certificates)
integration-tests-phobos/, integration-tests-vibe/, integration-tests-vibe1/   runners
```

## Protocol behaviour learned from real servers

Checked on 13, 14, 16 and 18 (official Docker images).

- **NegotiateProtocolVersion:** asked for 3.2, PostgreSQL 13 answers with the full version `0x00030000`, not only the minor version as the protocol documentation says; both forms are accepted. 18 accepts 3.2 (no NegotiateProtocolVersion).
- **pg_hba rejections** are FATAL errors with SQLSTATE 28000 (`no pg_hba.conf entry ...`, `pg_hba.conf rejects connection ... no encryption`); `sslmode=allow` retries with TLS on any server error of the unencrypted attempt. Wrong passwords: 28P01; unknown database: 3D000.
- **Direct TLS** to a server before 17: the server closes the connection during the handshake.
- **SASLprep:** the server stores the prepared form of a password (`I\u00ADX\u00A0pass` → `IX pass`); both forms then log in.
- **The image's defaults:** 14+ store passwords as SCRAM (`password_encryption`), 13 as MD5; an `md5` pg_hba rule uses SCRAM for a SCRAM-stored password. PostgreSQL 18 warns that MD5 passwords are deprecated.
- **pg_terminate_backend** of the own session: FATAL 57P01, then the server closes the connection.

## Local environment

- WSL2 Linux. **LDC 1.36.0** (`ldc2`); DMD is not installed. Test the minimum frontend with LDC 1.27.1 (download `https://github.com/ldc-developers/ldc/releases/download/v1.27.1/ldc2-1.27.1-linux-x86_64.tar.xz` into the scratchpad, run dub with `--compiler=<path>/bin/ldc2`).
- PostgreSQL in Docker: containers `pgnative-18`, `pgnative-16`, `pgnative-14`, `pgnative-13` (`postgres:<version>`, ports **15418**, 15416, 15414, 15413), prepared with `setup-server.sh`; user `testuser` / `Test_password123`, database `testdb`. `psql` is inside the containers: `docker exec -it pgnative-18 psql -U testuser -d testdb`.
- The local `grep` is ugrep, which treats files with odd bytes as binary and prints nothing: use `grep -a` on wire dumps.

## Conventions

- `@safe` by default; small commented `@trusted` blocks only in I/O and reinterpret-cast hot paths.
- **Every public symbol gets a Ddoc comment**; documented unittests as usage examples.
- Every type gets golden-byte unit tests and server round trips in both I/O modes; cover NULLs, extremes, non-ASCII text, time zones, infinities and special values (NaN, ±infinity dates/timestamps).
