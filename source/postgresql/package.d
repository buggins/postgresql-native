/++
Native PostgreSQL client library for D.

postgresql-native talks to PostgreSQL over its frontend/backend protocol and
works both with blocking Phobos sockets (ordinary threads) and with vibe-core
sockets (vibe.d fibers), through [dbwire](https://github.com/buggins/dbwire).

This is an unofficial project, not affiliated with the PostgreSQL Global
Development Group.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors:   Vadim Lopatin
+/
module postgresql;

public import postgresql.connection;
public import postgresql.exception;
public import postgresql.protocol.codes : TransactionStatus, protocol30, protocol32;
public import postgresql.result;
public import postgresql.settings;
public import postgresql.types.temporal : Interval;
public import postgresql.types.oids : Oid;
public import postgresql.types.pgtype : PgType, TypeKind;
public import postgresql.types.ranges : Range;
public import postgresql.types.network : Inet;
public import postgresql.types.bitstring : BitString;
public import postgresql.types.geometric : Box, Circle, Line, LineSegment, Path, Point, Polygon;
public import postgresql.types.textformat : HstorePair;
public import postgresql.value;
public import postgresql.statement : PreparedStatement;
public import postgresql.pipeline;
public import postgresql.copy : CopyFormat, CopyIn, CopyOut, parseCsvLine, parseTextLine;
public import postgresql.mapping : column, ignore, RowRange, sqlColumnName;
public import postgresql.pool;
public import postgresql.params : Param, encodeParam, rewritePlaceholders;
public import dbwire.types.decimal : Decimal;

/// Library version.
enum uint postgresqlVersionMajor = 0;
/// ditto
enum uint postgresqlVersionMinor = 4;
/// ditto
enum uint postgresqlVersionPatch = 0;

/// Library version as a string, e.g. `"0.1.0"`.
enum string postgresqlVersion = versionString(postgresqlVersionMajor, postgresqlVersionMinor,
            postgresqlVersionPatch);

/// Default `application_name` reported to the server.
enum string postgresqlClientName = "postgresql-native";

version (Have_vibe_core)
    private enum bool hasVibeCore = true;
else
    private enum bool hasVibeCore = false;

/++
True when vibe-core support is compiled in.

dub defines `Have_vibe_core` when vibe-core is anywhere in the application's
dependency graph. postgresql-native then supports fiber mode in addition to
the always-available thread mode.
+/
enum bool postgresqlHasVibe = hasVibeCore;

private string versionString(uint major, uint minor, uint patch) pure @safe
{
    import std.conv : to;

    return major.to!string ~ "." ~ minor.to!string ~ "." ~ patch.to!string;
}

///
@safe unittest
{
    import std.algorithm.searching : count;

    assert(postgresqlVersion.count('.') == 2 && postgresqlClientName == "postgresql-native");
}
