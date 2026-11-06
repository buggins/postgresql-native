/++
The attributes of struct mapping (`@column`, `@ignore`) and the field lists
they give: used for rows (`Connection.query!T`), composite values
(`Value.get!T`) and inserts.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module postgresql.attributes;

import std.traits : FieldNameTuple, getUDAs, hasUDA;

/// The value of a `@column("name")` attribute.
struct ColumnName
{
    /// The column name.
    string name;
}

/// The type of the `@ignore` attribute.
struct IgnoreField
{
}

/// UDA: maps a field to the column `name` (instead of the field's name).
ColumnName column(string name) @safe pure nothrow
{
    return ColumnName(name);
}

/// UDA: leaves a field out of the mapping.
enum ignore = IgnoreField();

/// The names of the mapped fields of `T` (not `@ignore`d), in field order.
template mappedFields(T) if (is(T == struct))
{
    enum string[] mappedFields = () {
        string[] names;
        static foreach (name; FieldNameTuple!T)
        {
            static if (name.length && !hasUDA!(__traits(getMember, T, name), IgnoreField))
                names ~= name;
        }
        return names;
    }();
}

/// The column names of the mapped fields of `T`, in field order.
template columnNames(T) if (is(T == struct))
{
    enum string[] columnNames = () {
        string[] names;
        static foreach (name; mappedFields!T)
        {
            static if (hasUDA!(__traits(getMember, T, name), ColumnName))
                names ~= getUDAs!(__traits(getMember, T, name), ColumnName)[0].name;
            else
                names ~= name;
        }
        return names;
    }();
}

///
@safe unittest
{
    static struct S
    {
        int id;
        @column("full_name") string name;
        @ignore int cache;
    }

    static assert(columnNames!S == ["id", "full_name"]);
}

/++
The position of `name` in `names`: the exact name, else the first that
differs only in case; -1 if none.
+/
ptrdiff_t findName(const(string)[] names, string name) @safe pure
{
    import std.uni : icmp;

    foreach (i, n; names)
        if (n == name)
            return i;
    foreach (i, n; names)
        if (icmp(n, name) == 0)
            return i;
    return -1;
}
