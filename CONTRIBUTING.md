# Contributing to postgresql-native

Thank you for your interest in contributing.

## Workflow

Every change goes through an issue and a pull request; nothing is pushed to
`main` directly. Open an issue first (or pick one from the
[roadmap](https://github.com/buggins/postgresql-native/issues/11)), work on a
feature branch, and mention `Closes #N` in the pull request.

## Development setup

- A D compiler with frontend **2.097 or newer**: DMD 2.097+ or LDC 1.27+.
- [dub](https://code.dlang.org).
- For integration tests: PostgreSQL in Docker, for example:

  ```sh
  docker run -d --name pgnative-18 -p 15418:5432 -e POSTGRES_USER=testuser \
      -e POSTGRES_PASSWORD=Test_password123 -e POSTGRES_DB=testdb postgres:18
  ```

  The tests cover PostgreSQL 13, 14, 16 and 18 (`postgres:13`, ...).

## Building and testing

```sh
dub build                          # library (thread mode, no C dependencies)
dub test                           # unit tests, no server needed
dub run :integration-tests-phobos  # integration tests, threads
dub run :integration-tests-vibe    # the same tests in vibe.d tasks
dub run :integration-tests-vibe1   # ... with vibe-core 1.x
```

Integration tests that need a server run when `POSTGRES_HOST` is set
(`host:port`), with `POSTGRES_DB` (default `testdb`), `POSTGRES_USER` (default
`testuser`) and `POSTGRES_PASSWORD`:

```sh
POSTGRES_HOST=localhost:15418 POSTGRES_PASSWORD=Test_password123 dub run :integration-tests-phobos
```

## Code style and checks

CI runs these checks, so run them before sending a pull request:

```sh
dub run dscanner@0.15.2 -- --styleCheck .                   # static analysis
dub run dfmt@0.15.2 -- --inplace $(git ls-files '*.d')      # formatting
dub build -b docs                                           # documentation builds
```

- Formatting follows `dfmt`, configured in `.editorconfig`: Allman braces, 4-space indentation.
- **Document every public symbol with a Ddoc comment.** D-Scanner reports undocumented public declarations.
- **Add unit tests next to the code they test.** A unittest preceded by `///` becomes a usage example in the generated docs.
- Prefer `@safe`. Keep `@trusted` blocks small, with a comment explaining why each one is safe.
- Anything that can block goes through dbwire's I/O backends, never directly through `std.socket`, `core.sync` or vibe.d.
- vibe.d-specific code belongs under `version (Have_vibe_core)`. The default build must not depend on vibe-core.
- Don't use language or library features newer than frontend 2.097.

## Licensing of contributions

postgresql-native is licensed under the [Boost Software License 1.0](LICENSE). By contributing, you agree that your contributions are licensed under the same terms.

- **The protocol is publicly documented** in the PostgreSQL manual ("Frontend/Backend Protocol"). The implementation is written from that documentation and from the behaviour of real servers.
- **Other clients are reference only**: reading libpq (PostgreSQL License), pgx (MIT), Npgsql (PostgreSQL License), pgjdbc (BSD-2-Clause), asyncpg (Apache-2.0) or psycopg (LGPL) to understand the protocol is fine; copying or translating their code is not, and line-by-line translation counts as copying. Reproducing wire-format facts is fine.
- Test data (golden bytes) comes from real servers, not from other clients' test suites.
- Third-party code or data needs the maintainer's agreement before it is added.
