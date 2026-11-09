# AGENTS.md

Guidance for AI coding agents working on **postgresql-native**, a native D client for PostgreSQL.

## Project at a glance

- **What:** a pure-D client for PostgreSQL over the **frontend/backend protocol 3.x** (TCP, port 5432; TLS through SSLRequest or direct TLS), for PostgreSQL 13–18 (tested; older servers probably work), with blocking (thread) and vibe.d (fiber) I/O. dub package `postgresql-native`, root module `postgresql`.
- **Repo:** `git@github.com:buggins/postgresql-native.git`, default branch `main`. Author Vadim Lopatin (GitHub `buggins`). License BSL-1.0.
- **Status:** 0.5.0 prepared 2026-11-07 (#19: hostaddr, services, Unix-domain sockets, requirepeer, CRLs; dbwire 0.8); 0.4.0 = dbwire 0.7: channel binding, waitForData, tz rules; 0.3.0 = Variant[] parameters for the ddbc driver (P8), 0.2.0 = P0–P7, 0.1.0 = P0–P5; roadmap issue #11 lists milestones P0–P9 (one issue each, #1–#10). P0 (scaffold), P1 (connect, TLS, authentication, simple queries), P2 (extended-protocol results, binary types, getters), P3 (parameters, statement cache, prepared statements), P4 (transactions, cancel, timeouts, pipelines) P5 (struct mapping, pool, connection strings, examples), P6 (arrays, ranges, composites, network, geometric, extension types) and P7 (COPY, LISTEN/NOTIFY), P8 (ddbc driver, in ddbc 0.11.0) done. Next: P9 hibernated (postponed until code.dlang.org lists the current ddbc).
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
dub run :bench -b release [-- --filter copyOut/]           # benchmarks (doc/benchmarks.md); compare the min column
```

Integration tests: a `void function()` that throws on failure in an `integrationtests.*` module, listed in `allTests` (`integration-tests/source/integrationtests/harness.d`); mode-specific ones in `threadTests` (`integration-tests-phobos/source/threadtests.d`) and `vibeTests` (`integration-tests-vibe/source/vibetests.d`). The server comes from `POSTGRES_HOST` (`host:port`), `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` (`integrationtests.server`); these are deliberately not libpq's `PG*` variables, which `fromEnvironment` reads. Tests that change process environment variables (`HOME`, `PG*`) restore them.

Run lint and format before committing D code. dfmt 0.15.2 mangles lambdas with attributes (`() nothrow {` → `() nothrow{`): use named nested functions. It merges `@safe return` into `@safereturn`: avoid the `return` attribute. Run dfmt twice when it changes files. `dub.selections.json` files are git-ignored (a root one listing vibe-core would enable vibe support silently).

`integration-tests/setup-server.sh <container>` prepares a server of the official image: TLS with the test certificates in `integration-tests/tls` (CA `ca.pem`, server certificate for `localhost` and `127.0.0.1`, client certificate `CN=certuser`, an unrelated `other-ca.pem`, CRLs `crl-none.pem`/`crls/` and `crl-revoked.pem` revoking the server certificate; regenerate them all with `sh make-test-certs.sh` there, then rerun `setup-server.sh` on existing containers), users `scramuser`, `md5user`, `clearuser` (passwords `<name>_pw`), `trustuser`, `tlsuser` (hostssl only), `certuser` (client certificate), `saslpuser` (a password SASLprep changes), and the matching `pg_hba.conf`. Tests that need it run when `POSTGRES_SETUP=1` (CI sets it). The Unix-domain socket tests run when `POSTGRES_SOCKET_DIR` names the container's `/var/run/postgresql` mounted on the host (CI: `/tmp/pgsocket`; keep the path short, socket paths are limited to about 100 bytes); `POSTGRES_SOCKET_PORT` is the server's own port (default 5432). The socket's owner is the container's `postgres` user (uid 999), which the host may know under another name: `requirepeer` tests use the host's name for that uid.

## Layout

```
source/postgresql/
  package.d            public imports, version constants, postgresqlHasVibe
  connection.d         Connection: hosts/failover, SSLRequest or direct TLS, startup, authentication,
                       simple query (exec, query), response reading, async messages (notices, ParameterStatus,
                       notifications), close; AuthMethod, Notification
  auth.d               SCRAM-SHA-256 client (+ -PLUS data: tls-server-end-point), MD5, SASLprep
  settings.d           ConnectionOptions, SslMode, ...; URI and key=value parsing (libpq keywords), require_auth
  result.d             ColumnInfo (RowDescription), Row (values + getter shortcuts), QueryResult (streamed rows)
  value.d              Value: one value, binary or text, and its typed getters (getString = the server's text)
  params.d             Param, encodeParam (D value → binary or text for the server's parameter type), ? rewriting
  statement.d          StatementInfo, StatementCache (LRU by SQL text), PreparedStatement, argument encoders
  pipeline.d           Pipeline, PipelineMode, PipelineResult (run by Connection.runPipeline)
  attributes.d         @column, @ignore, mappedFields, columnNames, findName (used by mapping and Value.get!S)
  mapping.d            struct mapping: readValue (= Value.get!T), RowRange (query!T), multi-row insert SQL and encoder
  copy.d               CopyIn (COPY FROM STDIN writer: text/CSV/binary rows), CopyOut (COPY TO STDOUT reader:
                       chunks, rows), CopyFormat, text/CSV line parsers
  pool.d               ConnectionPool, PooledConnection (session reset on release) over dbwire's PoolCore
  userfiles.d          the password file (.pgpass) and the default TLS files in ~/.postgresql
  types/               oids.d (built-in OIDs, which are decoded from binary), pgtype.d (PgType: kind, element, fields,
                       codec; the built-in registry), numeric.d (binary numeric, exact text, Decimal), floats.d
                       (shortest float text as the server prints it), temporal.d (date/time/timestamp(tz)/interval),
                       textformat.d (array/record/range/multirange/hstore text: parsing and quoting), network.d
                       (Inet, MAC addresses), geometric.d, bitstring.d, ranges.d (Range!T)
  exception.d          ServerMessage (error/notice fields), ServerException + dbwire's exceptions
  protocol/            codes.d (message types, auth codes, request codes), messages.d (framing: Message,
                       MessageBody, MessageBuilder, MessageStream)
integration-tests/     shared harness (dub subpackage `:integration-tests`), setup-server.sh, tls/ (test certificates)
integration-tests-phobos/, integration-tests-vibe/, integration-tests-vibe1/   runners
examples/              basic (`:example-basic`), vibe (`:example-vibe`); connect with fromEnvironment(args[1])
bench/                 benchmarks (`:bench`, local runs only): runner.d (timing, GC stats), fakeserver.d (in-memory
                       server: a Transport answering the frontend messages), cases.d; results in doc/benchmarks.md
doc/                   hand-written documentation (benchmarks.md)
```

Hot paths (#35): a `Message` body is a slice of the reader's buffer, valid until the next read; `Row` values are
slices of one copy of the DataRow (rows over 16 KiB copy each value, so a kept small value doesn't keep a large one;
null = NULL, empty values are never null; no shared arena: a kept value keeps only its row);
parameters are written straight into the Bind message (`putParam`, `ParamEncoder` writes format codes and values;
`encodeParam` is a wrapper over it); `MessageBuilder` writes by index into reused memory and can't be copied.

## Protocol behaviour learned from real servers

Checked on 13, 14, 16 and 18 (official Docker images).

- **NegotiateProtocolVersion:** asked for 3.2, PostgreSQL 13 answers with the full version `0x00030000`, not only the minor version as the protocol documentation says; both forms are accepted. 18 accepts 3.2 (no NegotiateProtocolVersion).
- **pg_hba rejections** are FATAL errors with SQLSTATE 28000 (`no pg_hba.conf entry ...`, `pg_hba.conf rejects connection ... no encryption`); `sslmode=allow` retries with TLS on any server error of the unencrypted attempt. Wrong passwords: 28P01; unknown database: 3D000.
- **Direct TLS** to a server before 17: the server closes the connection during the handshake.
- **SASLprep:** the server stores the prepared form of a password (`I\u00ADX\u00A0pass` → `IX pass`); both forms then log in.
- **The image's defaults:** 14+ store passwords as SCRAM (`password_encryption`), 13 as MD5; an `md5` pg_hba rule uses SCRAM for a SCRAM-stored password. PostgreSQL 18 warns that MD5 passwords are deprecated.
- **pg_terminate_backend** of the own session: FATAL 57P01, then the server closes the connection.
- **query()** = Parse (unnamed) + Describe statement + Flush, then Bind with per-column result formats + Execute + Sync. After an error before the Bind the client sends Sync and reads to ReadyForQuery. Parse refuses several statements (42601).
- **Parameters and statements:** Parse with no parameter types; ParameterDescription gives the inferred types (`SELECT $1` alone: text; `$1 + $2` alone: "operator is not unique", needs casts). Cached statements are named `pgn_s<n>`, prepared ones `pgn_p<n>`. Close of a statement that doesn't exist is not an error, so pending Close messages go at the start of the next extended batch. A cached `SELECT *` after `ALTER TABLE` fails at Bind with 0A000 ("cached plan must not change result type"); a statement dropped by `DISCARD ALL`/`DEALLOCATE ALL` gives 26000: outside a transaction block the client parses again and retries once; inside one the error stands (the block is failed). Command tags `DISCARD ALL` and `DEALLOCATE ALL` clear the cache.
- **Transactions:** a read-only block refuses DDL and writes to permanent tables (25006) but allows writes to temporary tables. `COMMIT` of a failed block rolls back (tag `ROLLBACK`). Statements in a failed block: 25P02.
- **Cancel:** CancelRequest (code 80877102, pid, key) on a new connection; the server answers nothing and closes it. Sent over TLS (SSLRequest or direct, like the session) when the session is encrypted. The cancelled statement fails with 57014; a cancel arriving while the session is idle is ignored. `statement_timeout` also gives 57014.
- **Pipelines:** statements between two Syncs form one implicit transaction (outside an explicit block): after an error the server skips to the Sync and the earlier statements are rolled back. A Sync after each statement makes them independent; each Sync gets its ReadyForQuery.
- **Float text** (12+, `extra_float_digits=1`): shortest exact digits, plain notation for decimal exponents -4 ≤ X < 15 (`float8`) / 6 (`float4`), else `d.ddde+XX` (two exponent digits at least). A decimal exactly halfway between two doubles is not used even when round-half-even would read it back (`-3.6681927456064224e+16`, not `-3.668192745606422e+16`).
- **Text forms:** `bool::text` is `true`/`false`, but a bool column's text is `t`/`f`; `bytea` is hex (`\x00ff`); `"char"` with the high bit is `\ooo`, the zero byte empty. Interval (postgres style): `1 year 2 mons 3 days 04:05:06.789`, plural unless 1 (`-1 days`), a `+` before a positive part that follows a negative one. Dates `0044-03-15 BC`, years past 9999 unpadded; `timestamptz` offsets `+05:45`, `+00`, historical `+05:41:16`. Interval infinities from 17; numeric infinities from 14. PostgreSQL 13 and 14 refuse the largest interval literal (`2562047788:00:54.775807`).
- **Session reset (pool):** `DISCARD ALL` can't run in a multi-statement simple query (implicit transaction block), the rest of its parts can: the pool sends `CLOSE ALL; SET SESSION AUTHORIZATION DEFAULT; RESET ALL; UNLISTEN *; SELECT pg_advisory_unlock_all(); DISCARD SEQUENCES; DISCARD TEMP` (all but `DEALLOCATE ALL`, so the statement cache stays valid). `RESET ALL` goes back to the startup-packet values (`statement_timeout`, `TimeZone` given at startup stay). Cached plans are re-planned when `search_path` changes.
- **target_session_attrs:** PostgreSQL 14+ report `in_hot_standby` and `default_transaction_read_only` (ParameterStatus); older servers are asked (`SHOW transaction_read_only`, `pg_is_in_recovery()`). `default_transaction_read_only=on` (e.g. `options=-c ...`) makes a primary count as read-only.
- **Types of the database:** `Connection.resolveColumns` looks dynamic OIDs up in `pg_type` (statement `pgn_types`, prepared once per session; re-prepared after DISCARD/DEALLOCATE ALL) between the describe and the Bind, so the result format can be chosen per column; element, field, base and subtype OIDs are looked up in the same way until all are known. Arrays are told by `typelem <> 0 AND typlen = -1`; multiranges (`typtype 'm'`, `pg_range.rngmultitypid`) from 14 only, so the query differs by version. The anonymous `record` is read as text (field types unknown).
- **RowDescription of a domain column** carries the base type's OID; inside arrays and records the domain's OID appears (`posint[]` is its own array type; record fields carry the declared type).
- **Text forms:** array elements are quoted when empty, `NULL` (any case), or containing `{}",\`, the delimiter or space, with `\` escapes; `box[]` uses `;`. Record fields and range bounds are quoted when empty or containing parentheses (and brackets for ranges), `,`, `"`, `\` or space, with `"` and `\` doubled; a NULL field is empty. Multiranges `{[1,3),[5,7)}`. `hstore`: `"k"=>"v", "k2"=>NULL`. `inet::text` (`network_show`) always shows the prefix, unlike the column output: compare with the simple protocol's output. IPv6 output: longest run of ≥ 2 zero groups as `::`, dotted IPv4 tail only for `::a.b.c.d` (run of 6 from 0) and `::ffff:a.b.c.d`. PostGIS `geometry`/`geography`: binary is EWKB, text is its uppercase hex. Geometric types use float8 text (`NaN`, `Infinity`).
- **COPY:** a simple Query with `COPY ... FROM STDIN` gets CopyInResponse (overall format 0/1, column count, per-column formats; no types); the client sends CopyData, then CopyDone or CopyFail (→ ErrorResponse 57014 "COPY from stdin failed") and reads CommandComplete `COPY n` + ReadyForQuery. On an error during the copy the server sends ErrorResponse + ReadyForQuery at once and drops further CopyData/CopyDone, so the writer checks `dataAvailable` before each 64 KiB message. Notices (e.g. from triggers) also arrive during COPY IN: read one message at a time there (`readMessage`), never `nextMessage`, which waits for a non-asynchronous message. COPY TO sends one CopyData per row (the binary header and trailer in their own messages, parsed from a buffer anyway). Binary COPY needs every value in its binary form: numeric text is converted (`encodeNumericText`), jsonb gets the version byte.
- **Notifications:** NotificationResponse arrives with any response, or alone while idle; `waitForNotification` polls `serverDataAvailable` (MessageStream buffer + `Transport.dataAvailable`, which for TLS decrypts and is true only for application data) then waits with dbwire's `waitForData` (`WaitableTransport`, dbwire 0.7).
- **Time zones:** `timestamptz` text uses the session's `TimeZone` (ParameterStatus) through dbwire's `resolveTimeZone`, which since dbwire 0.7 reads TZif files as RFC 8536 says (local mean time before a zone's first transition, the footer's rules after the last one), as the server does; the tests compare fixed instants from 1850 to 2200 and random ones from 1970 (tzdata releases revise history: the PG13 image has tzdata 2025b, which puts Europe/Dublin at +01 in September 1925, later releases at +00).

## Local environment

- WSL2 Linux. **LDC 1.36.0** (`ldc2`); DMD is not installed. Test the minimum frontend with LDC 1.27.1 (download `https://github.com/ldc-developers/ldc/releases/download/v1.27.1/ldc2-1.27.1-linux-x86_64.tar.xz` into the scratchpad, run dub with `--compiler=<path>/bin/ldc2`).
- PostgreSQL in Docker: containers `pgnative-18`, `pgnative-16`, `pgnative-14`, `pgnative-13` (`postgres:<version>`, ports **15418**, 15416, 15414, 15413), prepared with `setup-server.sh`; user `testuser` / `Test_password123`, database `testdb`. `psql` is inside the containers: `docker exec -it pgnative-18 psql -U testuser -d testdb`. PostGIS: `pgnative-postgis` (`postgis/postgis:17-3.5`, port 15417, not prepared by the setup script; `testPostgis` runs where the extension is available).
- The local `grep` is ugrep, which treats files with odd bytes as binary and prints nothing: use `grep -a` on wire dumps.

## Conventions

- `@safe` by default; small commented `@trusted` blocks only in I/O and reinterpret-cast hot paths.
- `Variant` copies, assignments and destruction are `@system`. Parameters are taken by `auto ref` down to `putParam`/`putVariant` (`ref const Variant`), so a `Variant` argument is never copied; only `ArgsHolder` (pipelines) copies one, in a commented trusted lambda. `Connection.queryRow` and `insert` copy or assign struct values: they sit before the class's `@safe:` label so they infer their attributes; keep them there (a template under `@safe:` is bound to `@safe`), and don't wrap them in trusted lambdas.
- **Every public symbol gets a Ddoc comment**; documented unittests as usage examples.
- Every type gets golden-byte unit tests and server round trips in both I/O modes; cover NULLs, extremes, non-ASCII text, time zones, infinities and special values (NaN, ±infinity dates/timestamps).

## D idioms and review lessons

Learned from the review of the MySQL 8 work in mysql-native (mysql-d/mysql-native#288, 2026-11). All of these work on the minimum frontend 2.097; checked with LDC 1.27.1.

- **`BigInt` and bytes: never go through hex or decimal strings.**
  - Bytes to `BigInt`: `BigInt(false, bytes)` takes any finite range of unsigned integers, most significant first.
  - `BigInt` to words or bytes: `value.getDigit!uint(i)` or `getDigit!ulong(i)` for `i` below `uintLength` or `ulongLength`, least significant first. dbwire's `WideInt.fromBigInt` does this.
  - Modular exponentiation: `std.bigint.powmod`.
  - `format("%x", bigint)` groups digits with `_` until Phobos 2.114 (dlang/phobos#11051).
- **Enums for protocol names.** For a fixed set of wire strings such as plugin names, use a `ubyte` enum whose members are spelled exactly like the wire names; the protocol's own spelling beats camelCase here.
  - `to!string` then gives the name to send. It returns the stored literal and doesn't allocate for a valid member, but it isn't `nothrow` or `@nogc`.
  - To parse untrusted input, loop over the members: `static foreach (m; __traits(allMembers, E)) if (name == m) return __traits(getMember, E, m);`. This is `nothrow @nogc` and compares the packet slice directly, with no `idup`. Don't use `to!E(name)`, which throws `ConvException` on unknown names.
  - Each name then appears once, instead of in a parse table and a format table that can drift apart.
  - With a `string`-based enum, `to!string` returns the member's identifier, not its value.
- **Small idioms:**
  - Test byte vectors: `cast(const(ubyte)[]) std.conv.hexString!"0a1b..."` instead of hand-written hex decoding.
  - Strip leading zero bytes with `find!(b => b != 0)`.
  - Copy (`idup`) a slice only where it must outlive the buffer; an error message built inside `enforce` is lazy, so copying there is fine.
- **Function attributes** (`@safe`, `@trusted`, `pure`, `nothrow`, `@nogc`, `scope`). Sources: the D spec (function.html, attribute.html), the D blog's memory-safety series, and the D forum consensus. Behaviour checked with LDC 1.27.1 and 1.36 (2026-11-08).
  - **Inference.** Templates, `auto` functions, nested functions and lambdas infer `@safe`, `pure`, `nothrow` and `@nogc`. Other functions infer nothing, even when their body is visible.
    - Write the attributes on ordinary functions, public API first.
    - Leave them off templates. An attribute written on a template binds every instantiation (an `@safe` template rejects a `T` whose copy is `@system`).
    - Lock in what a template infers with an attributed unittest that instantiates it with plain types, e.g. `@safe pure nothrow @nogc unittest`.
  - **`@safe:` at module scope** covers everything after it, templates included; they still infer the other attributes. `pure`, `nothrow` and `@nogc` don't propagate into struct and class bodies.
  - **`@trusted` promises a safe interface.** For every argument a `@safe` caller can pass, the function must not corrupt memory or create an unsafe value, such as a dangling pointer or a `bool` other than 0 or 1. The compiler doesn't check the body.
    - Keep the trusted part as small as possible: trust the one `@system` call, e.g. `(() @trusted => v.get!T)()`, with a comment saying why it is safe.
    - A trusted lambda makes the enclosing function part of the review. Whatever the lambda relies on, such as a length checked a few lines earlier, must stay true when that function changes.
    - A `cast(ubyte[])` view of values without indirections is fine for reading. Writing arbitrary bytes into `bool` or enum values through such a view creates invalid values; normalize them before `@safe` code sees them.
  - **Never mark a template `@trusted` if its body copies, constructs or destroys a `T`.** The attribute hides `T`'s `@system` postblit, copy constructor or destructor. Checked: `V wrap(T)(ref T v) @trusted { T copy = v; ... }` compiles in `@safe` code for a struct with a `@system` postblit. Trust only the `@system` call inside, which lets inference catch `T`, or constrain `T` (`!hasIndirections!T`, `!hasElaborateCopyConstructor!T`).
  - **`nothrow`**: only `Error`s may escape.
    - Wrap calls that can't actually throw in `std.exception.assumeWontThrow`, or in `try ... catch (Exception e) assert(0, e.msg);`.
    - Never catch `Error` or `Throwable` to make code `nothrow`.
  - **`@nogc`** forbids `new`, array appending and concatenation, closures that escape, and `throw new`. Use it for leaf hot paths (codecs, parsers); error paths that throw stay outside it.
  - **`debug` statements** may break `pure`, `nothrow` and `@nogc`, which helps temporary logging. They compile only with `-debug`; don't leave them in committed code.
  - **`scope` and `return scope`** are checked only in `@safe` code compiled with `-preview=dip1000`, which is still not the default (D 2.113, August 2026).
    - Without that switch, `scope` is an unchecked promise. With it, callers may pass stack memory to a `scope` parameter, so a `@trusted` or `@system` function that keeps such a parameter has a memory bug.
    - dbwire, clickhoused and postgresql-native are dip1000-clean on current compilers: CI runs their unit tests with `-preview=dip1000` on dmd-latest and ldc-latest (dbwire#50, clickhoused#71, postgresql-native#37). Older Phobos isn't: 2.097's `std.socket` has no `scope` annotations. oracle-native and mssql-native haven't been checked yet. Don't add `scope` speculatively.
- **Changes to someone else's code: keep the diff small.** Keep the existing structure, and change the input instead of the cases. For example, when MySQL 8.4 inserted a `Language` column after `Type` in `SHOW PROCEDURE STATUS` (5.7, 8.0 and MariaDB don't have it; the manual doesn't list it), the fix kept the old switch on column numbers: skip column 3 when there are 12 columns, and shift the later indexes down by one.
- **Check facts before writing them down.** Verify server behaviour on the real servers, since manuals lag behind. Take CI failure reasons from the job logs, not from memory. A wrong reason in a commit message had to be corrected during that review.
- **CI facts (November 2026):**
  - GitHub retired the `ubuntu-20.04` runners. When a matrix tests old compilers, pin a concrete image instead of `ubuntu-latest`, and prefer the oldest one still offered: `ubuntu-22.04` today (likely until mid-2027). The mysql-native reviewers asked for that as the most conservative choice, and old compilers down to dmd 2.097 / ldc 1.27 pass on it.
  - `macos-latest` is macOS 26 on arm64. There:
    - `setup-dlang` installs no DMD;
    - `setup-dlang@v1` requests `ldc2-1.28.1-osx-aarch64.tar.xz`, while LDC names the file `osx-arm64`, so the download fails with a 404.
  - `macos-15-intel` runs dmd-latest, dmd 2.098.1 and LDC 1.28.1. On macOS 15, even Intel, the dmd 2.101.2 binary doesn't run and LDC 1.31.0's dub crashes (SIGSEGV).
  - With `setup-dlang@v2.0.0`, programs built by LDC 1.30, 1.35 or 1.40.1 crash (segfault, even hello world) on `macos-latest`, `macos-15` and `macos-15-intel`. LDC 1.41.0 is the oldest that works there, so our CI tests ldc-latest and 1.41.0 on macOS, and the older LDCs on Linux.
  - `WebFreak001/dub-upgrade@v0.1.1` uses GitHub's retired cache service ("getCacheEntry failed"); v0.2.0 works.
