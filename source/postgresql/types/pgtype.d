/++
What the client knows about PostgreSQL data types: the built-in ones (same
OIDs in every database), and those of a database (enums, composite types,
domains, their arrays and ranges, extension types), which a connection looks
up in `pg_type` when it first meets their OIDs.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module postgresql.types.pgtype;

import postgresql.types.oids : Oid;

@safe:

/// The kinds of data types (`pg_type.typtype`, arrays told apart).
enum TypeKind
{
    /// A base (scalar) type.
    base,
    /// An array of `PgType.element`.
    array,
    /// A range of `PgType.element` (the subtype).
    range,
    /// A multirange: a set of ranges of type `PgType.element`.
    multirange,
    /// A composite type (a table's row type, `CREATE TYPE ... AS (...)`) or `record`.
    composite,
    /// An enum type: values are their labels.
    enum_,
    /// A domain over `PgType.element`.
    domain,
    /// A pseudo-type (`void`, `unknown`, ...).
    pseudo,
}

/// A data type: its OID, name, kind and parts.
final class PgType
{
    /// The type's OID.
    uint oid;
    /// Its name (`pg_type.typname`), e.g. `int4`, `_int4` (its array), `mood`.
    string name;
    /// Its kind.
    TypeKind kind;
    /// The element type of an array, the subtype of a range, the range type of a multirange, the base of a domain.
    PgType element;
    /// The delimiter between array elements of this type in text (`;` for `box`, else `,`).
    char delimiter = ',';
    /// The field names of a composite type (empty for `record`).
    string[] fieldNames;
    /// The field types of a composite type.
    PgType[] fieldTypes;
    /++
    The OID of the built-in type whose decoder reads this type's values:
    the type itself for built-in base types, the base type's for domains,
    `text` for enums and `citext`, `hstoreCodec` for `hstore`,
    `postgisCodec` for PostGIS `geometry` and `geography`, 0 if none.
    +/
    uint codec;

    /// Makes a type.
    this(uint oid, string name, TypeKind kind, PgType element = null, char delimiter = ',') pure nothrow
    {
        this.oid = oid;
        this.name = name;
        this.kind = kind;
        this.element = element;
        this.delimiter = delimiter;
        if (kind == TypeKind.base)
        {
            if (name == "citext")
                codec = Oid.text;
            else if (name == "hstore")
                codec = hstoreCodec;
            else if (name == "geometry" || name == "geography")
                codec = postgisCodec;
            else
                codec = oid;
        }
        else if (kind == TypeKind.enum_)
            codec = Oid.text;
        else if (kind == TypeKind.domain && element !is null)
            codec = element.codec;
    }

    /++
    Whether the client decodes values of this type in binary format (else
    they are asked for as text): base types with a decoder, enums, and
    arrays, ranges, multiranges, domains and composite types made of such
    types. The anonymous `record` is read as text.
    +/
    @property bool binaryDecodable() const pure nothrow
    {
        final switch (kind)
        {
        case TypeKind.base:
            return hasBinaryCodec(codec);
        case TypeKind.enum_:
            return true;
        case TypeKind.array, TypeKind.range, TypeKind.multirange, TypeKind.domain:
            return element !is null && element.binaryDecodable;
        case TypeKind.composite:
            if (fieldTypes.length == 0)
                return false;
            foreach (f; fieldTypes)
                if (f is null || !f.binaryDecodable)
                    return false;
            return true;
        case TypeKind.pseudo:
            return false;
        }
    }

    /// The type with domains replaced by their base types.
    @property const(PgType) withoutDomain() const pure nothrow
    {
        return kind == TypeKind.domain && element !is null ? element.withoutDomain : this;
    }
}

/// `PgType.codec` of `hstore` (an extension type, with an OID per database).
enum uint hstoreCodec = 0xFFFF_FF01;

/// `PgType.codec` of PostGIS `geometry` and `geography`: EWKB in binary, its hexadecimal digits as text.
enum uint postgisCodec = 0xFFFF_FF02;

/// Whether `codec` (a built-in OID or `hstoreCodec`) has a binary decoder.
bool hasBinaryCodec(uint codec) pure nothrow @nogc
{
    import postgresql.types.oids : hasBinaryDecoder;

    return codec == hstoreCodec || codec == postgisCodec || hasBinaryDecoder(codec);
}

/// The built-in type with OID `oid`, or null.
PgType builtinType(uint oid) @trusted nothrow
{
    // the table is built once and never changed afterwards
    if (auto t = oid in builtins)
        return cast(PgType)*t;
    return null;
}

///
unittest
{
    assert(builtinType(Oid.int4).name == "int4" && builtinType(Oid.int4).binaryDecodable);
    const ints = builtinType(1007);
    assert(ints.kind == TypeKind.array && ints.element.oid == Oid.int4 && ints.binaryDecodable);
    assert(builtinType(3904).kind == TypeKind.range && builtinType(3904).element.oid == Oid.int4);
    assert(builtinType(4451).kind == TypeKind.multirange && builtinType(4451).element.oid == 3904);
    assert(builtinType(1020).element.delimiter == ';'); // box[]
    assert(!builtinType(790).binaryDecodable && builtinType(791).kind == TypeKind.array); // money, money[]
    assert(!builtinType(2249).binaryDecodable); // record
    assert(builtinType(123_456) is null);
}

private __gshared immutable(PgType)[uint] builtins;

shared static this() @trusted
{
    PgType[uint] table;
    void base(uint oid, string name, uint arrayOid, char delimiter = ',')
    {
        auto t = new PgType(oid, name, TypeKind.base, null, delimiter);
        table[oid] = t;
        if (arrayOid)
            table[arrayOid] = new PgType(arrayOid, "_" ~ name, TypeKind.array, t);
    }

    // OID, name, array OID (pg_type of PostgreSQL 13 to 18)
    base(16, "bool", 1000);
    base(17, "bytea", 1001);
    base(18, "char", 1002);
    base(19, "name", 1003);
    base(20, "int8", 1016);
    base(21, "int2", 1005);
    base(22, "int2vector", 1006);
    base(23, "int4", 1007);
    base(24, "regproc", 1008);
    base(25, "text", 1009);
    base(26, "oid", 1028);
    base(27, "tid", 1010);
    base(28, "xid", 1011);
    base(29, "cid", 1012);
    base(30, "oidvector", 1013);
    base(114, "json", 199);
    base(142, "xml", 143);
    base(600, "point", 1017);
    base(601, "lseg", 1018);
    base(602, "path", 1019);
    base(603, "box", 1020, ';');
    base(604, "polygon", 1027);
    base(628, "line", 629);
    base(650, "cidr", 651);
    base(700, "float4", 1021);
    base(701, "float8", 1022);
    base(718, "circle", 719);
    base(774, "macaddr8", 775);
    base(790, "money", 791);
    base(829, "macaddr", 1040);
    base(869, "inet", 1041);
    base(1033, "aclitem", 1034);
    base(1042, "bpchar", 1014);
    base(1043, "varchar", 1015);
    base(1082, "date", 1182);
    base(1083, "time", 1183);
    base(1114, "timestamp", 1115);
    base(1184, "timestamptz", 1185);
    base(1186, "interval", 1187);
    base(1266, "timetz", 1270);
    base(1560, "bit", 1561);
    base(1562, "varbit", 1563);
    base(1700, "numeric", 1231);
    base(1790, "refcursor", 2201);
    base(2202, "regprocedure", 2207);
    base(2203, "regoper", 2208);
    base(2204, "regoperator", 2209);
    base(2205, "regclass", 2210);
    base(2206, "regtype", 2211);
    base(2950, "uuid", 2951);
    base(2970, "txid_snapshot", 2949);
    base(3220, "pg_lsn", 3221);
    base(3614, "tsvector", 3643);
    base(3615, "tsquery", 3645);
    base(3734, "regconfig", 3735);
    base(3769, "regdictionary", 3770);
    base(3802, "jsonb", 3807);
    base(4072, "jsonpath", 4073);
    base(4089, "regnamespace", 4090);
    base(4096, "regrole", 4097);
    base(4191, "regcollation", 4192);
    base(5038, "pg_snapshot", 5039);
    base(5069, "xid8", 271);
    table[705] = new PgType(705, "unknown", TypeKind.pseudo);
    table[705].codec = Oid.unknown;

    void range(uint oid, string name, uint subtype, uint arrayOid, uint multiOid, string multiName,
            uint multiArrayOid)
    {
        auto r = new PgType(oid, name, TypeKind.range, table[subtype]);
        table[oid] = r;
        table[arrayOid] = new PgType(arrayOid, "_" ~ name, TypeKind.array, r);
        auto m = new PgType(multiOid, multiName, TypeKind.multirange, r);
        table[multiOid] = m;
        table[multiArrayOid] = new PgType(multiArrayOid, "_" ~ multiName, TypeKind.array, m);
    }

    range(3904, "int4range", 23, 3905, 4451, "int4multirange", 6150);
    range(3906, "numrange", 1700, 3907, 4532, "nummultirange", 6151);
    range(3908, "tsrange", 1114, 3909, 4533, "tsmultirange", 6152);
    range(3910, "tstzrange", 1184, 3911, 4534, "tstzmultirange", 6153);
    range(3912, "daterange", 1082, 3913, 4535, "datemultirange", 6155);
    range(3926, "int8range", 20, 3927, 4536, "int8multirange", 6157);

    auto record = new PgType(2249, "record", TypeKind.composite);
    table[2249] = record;
    table[2287] = new PgType(2287, "_record", TypeKind.array, record);

    builtins = cast(immutable(PgType)[uint]) table; // not changed after this
}
