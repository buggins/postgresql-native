/++
OIDs of the built-in data types (from `pg_type`; they are the same in every
PostgreSQL database and version).

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module postgresql.types.oids;

/// Built-in type OIDs.
enum Oid : uint
{
    bool_ = 16, ///
    bytea = 17, ///
    char_ = 18, /// `"char"`: a single byte
    name = 19, ///
    int8 = 20, ///
    int2 = 21, ///
    int4 = 23, ///
    text = 25, ///
    oid = 26, ///
    json = 114, ///
    xml = 142, ///
    float4 = 700, ///
    float8 = 701, ///
    unknown = 705, ///
    bpchar = 1042, /// `char(n)`
    varchar = 1043, ///
    date = 1082, ///
    time = 1083, ///
    timestamp = 1114, ///
    timestamptz = 1184, ///
    interval = 1186, ///
    timetz = 1266, ///
    numeric = 1700, ///
    uuid = 2950, ///
    jsonb = 3802, ///
}

/// Whether values of type `oid` are decoded from the binary format (else they are requested as text).
bool hasBinaryDecoder(uint oid) @safe pure nothrow @nogc
{
    switch (oid)
    {
    case Oid.bool_, Oid.bytea, Oid.char_, Oid.name, Oid.int8, Oid.int2, Oid.int4, Oid.text, Oid.oid, Oid.json,
        Oid.float4, Oid.float8, Oid.bpchar, Oid.varchar, Oid.date, Oid.time, Oid.timestamp, Oid.timestamptz,
        Oid.interval, Oid.timetz, Oid.numeric, Oid.uuid, Oid.jsonb:
        return true;
    default:
        return false;
    }
}
