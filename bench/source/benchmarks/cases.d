/++
Benchmark cases: the client's work for queries, parameters, inserts, value
conversions and COPY, against the in-memory `FakeServer`.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module benchmarks.cases;

import core.time : Duration;
import std.datetime.date : Date;
import std.variant : Variant;

import postgresql;
import dbwire.io.transport : Transport;

import benchmarks.fakeserver;
import benchmarks.runner : BenchCase, Prepared;

/// All cases.
BenchCase[] allCases()
{
    return queryCases() ~ paramCases() ~ valueCases() ~ copyCases();
}

private:

enum Oid : uint
{
    bool_ = 16,
    int8 = 20,
    int4 = 23,
    text = 25,
    float8 = 701,
    inet = 869,
    int4Array = 1007,
    textArray = 1009,
    date = 1082,
    timestamptz = 1184,
    interval = 1186,
    numeric = 1700,
    uuid = 2950,
}

// A connection to a new fake server.
Connection connect(FakeServer server)
{
    ConnectionOptions o;
    o.host = "fake";
    o.user = "bench";
    o.sslMode = SslMode.disable;
    Transport factory(string, ushort, Duration) @safe
    {
        return server;
    }

    o.transportFactory = &factory;
    return new Connection(o);
}

immutable(ubyte)[] bytes(string s)
{
    return cast(immutable(ubyte)[]) s;
}

immutable(ubyte)[] doubleBytes(double d)
{
    return be64(*cast(long*)&d);
}

// The ten columns of the query cases: int4, int8, text, float8, bool, timestamptz, numeric, uuid, date, text.
Column[] tenColumns()
{
    // numeric 12345.678: 3 base-10000 groups, weight 1, scale 3
    const numeric = be16(3) ~ be16(1) ~ be16(0) ~ be16(3) ~ be16(1) ~ be16(2345) ~ be16(6780);
    immutable(ubyte)[] uuid = [
        0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0
    ];
    return [
        Column("id", Oid.int4, 4, bytes("123456"), be32(123_456)),
        Column("big", Oid.int8, 8, bytes("1234567890123"), be64(1_234_567_890_123)),
        Column("name", Oid.text, -1, bytes("a product name"), bytes("a product name")),
        Column("price", Oid.float8, 8, bytes("19.99"), doubleBytes(19.99)),
        Column("active", Oid.bool_, 1, bytes("t"), [1]),
        Column("created", Oid.timestamptz, 8, bytes("2026-11-09 12:34:56.789+00"), be64(816_093_296_789_000)),
        Column("amount", Oid.numeric, -1, bytes("12345.678"), numeric),
        Column("key", Oid.uuid, 16, bytes("12345678-9abc-def0-1234-56789abcdef0"), uuid),
        Column("day", Oid.date, 4, bytes("2026-11-09"), be32(9809)),
        Column("note", Oid.text, -1, bytes("some longer text in the last column"),
                bytes("some longer text in the last column")),
    ];
}

struct Product
{
    int id;
    long big;
    string name;
    double price;
    bool active;
    SysTime created;
    Decimal amount;
    UUID key;
    Date day;
    string note;
}

import std.datetime.systime : SysTime;
import std.uuid : UUID;
import dbwire.types.decimal : Decimal;

BenchCase queryCase(string name, size_t defaultRows, void delegate(Connection, size_t) work,
        void delegate(FakeServer) setup = null)
{
    Prepared prepare(size_t rows)
    {
        auto server = new FakeServer;
        server.columns = tenColumns();
        if (setup !is null)
            setup(server);
        auto conn = connect(server);
        server.rowsPerExecute = rows;
        return Prepared(rows, 0, () => work(conn, rows));
    }

    return BenchCase(name, &prepare, defaultRows);
}

BenchCase[] queryCases()
{
    void iterate(Connection conn, size_t)
    {
        size_t n;
        foreach (row; conn.query("SELECT * FROM products"))
            n += row.length;
    }

    void getters(Connection conn, size_t)
    {
        long sum;
        foreach (row; conn.query("SELECT * FROM products"))
        {
            sum += row.getInt(0) + row.getLong(1) + row.getString(2).length + cast(long) row.getDouble(3);
            sum += row.getBool(4) + row.getSysTime(5).stdTime + row.getDecimal(6).scale;
            sum += row.getUUID(7).data[0] + row.getDate(8).day + row.getString(9).length;
        }
    }

    void byName(Connection conn, size_t)
    {
        long sum;
        foreach (row; conn.query("SELECT * FROM products"))
            sum += row.getInt("id") + row.getString("name").length + row.getString("note").length;
    }

    void structs(Connection conn, size_t)
    {
        size_t n;
        foreach (p; conn.query!Product("SELECT * FROM products"))
            n += p.id;
    }

    void simple(Connection conn, size_t)
    {
        size_t n;
        foreach (row; conn.querySimple("SELECT * FROM products"))
            n += row.getString(2).length;
    }

    // 1000 calls on a result of `rows` rows
    void value(Connection conn, size_t)
    {
        long sum;
        foreach (i; 0 .. 1000)
            sum += conn.queryValue!int("SELECT id FROM products WHERE id > $1", i);
    }

    void execRows(Connection conn, size_t)
    {
        ulong sum;
        foreach (i; 0 .. 1000)
            sum += conn.exec("SELECT * FROM products WHERE id > $1", i);
    }

    return [
        queryCase("query/iterate 10 columns", 100_000, &iterate),
        queryCase("query/getters 10 columns", 100_000, &getters),
        queryCase("query/3 getters by name", 100_000, &byName),
        queryCase("query/struct 10 fields", 100_000, &structs),
        queryCase("query/simple protocol getString", 100_000, &simple),
        queryCase("query/1000 queryValue on N rows", 100, &value),
        queryCase("query/1000 exec on N rows", 100, &execRows),
    ];
}

BenchCase paramCase(string name, size_t defaultRows, uint[] types, void delegate(Connection, size_t) work)
{
    Prepared prepare(size_t rows)
    {
        auto server = new FakeServer;
        server.columns = tenColumns();
        server.paramTypes = types;
        auto conn = connect(server);
        return Prepared(rows, 0, () => work(conn, rows));
    }

    return BenchCase(name, &prepare, defaultRows);
}

struct Item
{
    int id;
    long quantity;
    string name;
    double price;
    bool active;
}

BenchCase[] paramCases()
{
    void ints(Connection conn, size_t rows)
    {
        foreach (i; 0 .. rows)
            conn.exec("UPDATE t SET a = $1, b = $2, c = $3, d = $4 WHERE id = $5", 1, 2, 3, cast(int) i, 5);
    }

    void questionMarks(Connection conn, size_t rows)
    {
        foreach (i; 0 .. rows)
            conn.exec(
                    "UPDATE inventory SET quantity = quantity - ?, updated = now() WHERE warehouse = ? "
                    ~ "AND item = ?", 1, 2, cast(int) i);
    }

    void mixed(Connection conn, size_t rows)
    {
        const day = Date(2026, 11, 9); // const: checks that const arguments work
        foreach (i; 0 .. rows)
            conn.exec("UPDATE t SET a = $1, b = $2, c = $3, d = $4, e = $5 WHERE id = $6", cast(int) i, 2L,
                    "name", 1.5, day, true);
    }

    void variants(Connection conn, size_t rows)
    {
        auto args = [
            Variant(1), Variant(2L), Variant("name"), Variant(1.5), Variant(Date(2026, 11, 9))
        ];
        foreach (i; 0 .. rows)
            conn.exec("UPDATE t SET a = $1, b = $2, c = $3, d = $4, e = $5", args);
    }

    void array(Connection conn, size_t rows)
    {
        auto values = new int[1000];
        foreach (i, ref v; values)
            v = cast(int) i;
        foreach (i; 0 .. rows)
            conn.exec("UPDATE t SET a = $1", values);
    }

    void insert(Connection conn, size_t rows)
    {
        auto items = new Item[rows];
        foreach (i, ref item; items)
            item = Item(cast(int) i, i * 10, "item name", 1.25, true);
        conn.insert("items", items);
    }

    void rewrite(Connection, size_t rows)
    {
        size_t n, total;
        foreach (i; 0 .. rows)
            total += rewritePlaceholders(
                    "UPDATE inventory SET quantity = quantity - ?, updated = now() "
                    ~ "WHERE warehouse = ? AND item = ?", n).length;
    }

    return [
        paramCase("params/exec 5 int4", 100_000, [Oid.int4], &ints),
        paramCase("params/exec 3 ? placeholders", 100_000, [Oid.int4], &questionMarks),
        paramCase("params/exec 6 mixed types", 100_000, [
            Oid.int4, Oid.int8, Oid.text, Oid.float8, Oid.date, Oid.bool_
        ], &mixed),
        paramCase("params/exec 5 Variant", 100_000, [
            Oid.int4, Oid.int8, Oid.text, Oid.float8, Oid.date
        ], &variants),
        paramCase("params/exec int4[1000]", 1000, [Oid.int4Array], &array),
        paramCase("params/insert 5 fields", 100_000, [
            Oid.int4, Oid.int8, Oid.text, Oid.float8, Oid.bool_
        ], &insert),
        paramCase("params/rewritePlaceholders 100 chars", 1_000_000, [Oid.int4], &rewrite),
    ];
}

BenchCase valueCase(string name, Column column, void delegate(const Row) read, bool simple = false)
{
    Prepared prepare(size_t rows)
    {
        auto server = new FakeServer;
        server.columns = [column];
        server.rowsPerExecute = rows;
        auto conn = connect(server);
        void run()
        {
            if (simple)
                foreach (row; conn.querySimple("SELECT v FROM t"))
                    read(row);
            else
                foreach (row; conn.query("SELECT v FROM t"))
                    read(row);
        }

        return Prepared(rows, 0, &run);
    }

    return BenchCase(name, &prepare, 100_000);
}

BenchCase[] valueCases()
{
    const numeric = Column("v", Oid.numeric, -1, bytes("12345.678"), be16(3) ~ be16(1) ~ be16(
            0) ~ be16(3) ~ be16(1)
            ~ be16(2345) ~ be16(6780));
    const timestamp = Column("v", Oid.timestamptz, 8, bytes("2026-11-09 12:34:56.789+00"), be64(816_093_296_789_000));
    const inet = Column("v", Oid.inet, -1, bytes("192.168.1.20/24"), [2, 24, 0, 4, 192, 168, 1, 20]);
    immutable(ubyte)[] ints = be32(1) ~ be32(0) ~ be32(Oid.int4) ~ be32(100) ~ be32(1);
    string intsText = "{";
    foreach (i; 0 .. 100)
    {
        ints ~= be32(4) ~ be32(i);
        intsText ~= (i ? "," : "") ~ cast(char)('0' + i % 10);
    }
    intsText ~= "}";
    const intArray = Column("v", Oid.int4Array, -1, bytes(intsText), ints);
    const textArray = Column("v", Oid.textArray, -1, bytes(`{"a b","c\"d",plain,NULL,"x,y"}`), null);

    size_t sink;
    return [
        valueCase("value/numeric getString", numeric, (const Row r) { sink += r.getString(0).length; }),
        valueCase("value/numeric getDouble", numeric, (const Row r) {
            sink += cast(size_t) r.getDouble(0);
        }),
        valueCase("value/numeric getDecimal", numeric, (const Row r) {
            sink += cast(size_t) r.getDecimal(0).scale;
        }),
        valueCase("value/numeric getLong", Column("v", Oid.numeric, -1, bytes("12345"), be16(2) ~ be16(
                1) ~ be16(0)
                ~ be16(0) ~ be16(1) ~ be16(2345)), (const Row r) { sink += cast(size_t) r.getLong(0); }),
        valueCase("value/timestamptz getString", timestamp, (const Row r) {
            sink += r.getString(0).length;
        }),
        valueCase("value/inet getString", inet, (const Row r) { sink += r.getString(0).length; }),
        valueCase("value/int4[100] get!(int[])", intArray, (const Row r) {
            sink += r.get!(int[])(0).length;
        }),
        valueCase("value/int4[100] getString", intArray, (const Row r) {
            sink += r.getString(0).length;
        }),
        valueCase("value/text int4[100] get!(int[])", intArray, (const Row r) {
            sink += r.get!(int[])(0).length;
        }, true),
        valueCase("value/text text[5] get!(string[])", textArray, (const Row r) {
            sink += r.get!(string[])(0).length;
        }, true),
    ];
}

BenchCase[] copyCases()
{
    BenchCase copyInCase(string name, CopyFormat format)
    {
        Prepared prepare(size_t rows)
        {
            auto server = new FakeServer;
            auto conn = connect(server);
            void run()
            {
                auto copy = conn.copyIn("COPY items FROM STDIN", format);
                foreach (i; 0 .. rows)
                    copy.writeRow(cast(int) i, "a name with\ttab", 19.99, "some longer text in a column", true);
                copy.finish();
            }

            return Prepared(rows, 0, &run);
        }

        return BenchCase(name, &prepare, 100_000);
    }

    BenchCase copyRawCase()
    {
        Prepared prepare(size_t rows)
        {
            auto server = new FakeServer;
            auto conn = connect(server);
            auto line = cast(immutable(ubyte)[]) "123\tsome text\t19.99\tmore text in a column\tt\n";
            void run()
            {
                auto copy = conn.copyIn("COPY items FROM STDIN");
                foreach (i; 0 .. rows)
                    copy.write(line);
                copy.finish();
            }

            return Prepared(rows, rows * line.length, &run);
        }

        return BenchCase("copyIn/write raw lines", &prepare, 1_000_000);
    }

    BenchCase copyOutCase(string name, string sql, CopyFormat format, bool getters)
    {
        Prepared prepare(size_t rows)
        {
            auto server = new FakeServer;
            server.copyRows = rows;
            server.copyTextRow = format == CopyFormat.csv
                ? bytes("123456,\"a \"\"quoted\"\" name\",19.99,some longer text in a column,t\n") : bytes(
                        "123456\ta name\\twith tab\t19.99\tsome longer text in a column\tt\n");
            server.copyBinaryRow = be16(5) ~ be32(4) ~ be32(123_456) ~ be32(6) ~ bytes("a name") ~ be32(
                    8)
                ~ doubleBytes(19.99) ~ be32(28) ~ bytes("some longer text in a column") ~ be32(1) ~ bytes("\x01");
            auto conn = connect(server);
            const size_t rowBytes = format == CopyFormat.binary ? server.copyBinaryRow.length
                : server.copyTextRow.length;
            void run()
            {
                auto copy = conn.copyOut(sql, format);
                copy.columnTypes([Oid.int4, Oid.text, Oid.float8, Oid.text, Oid.bool_]);
                size_t n;
                foreach (row; copy)
                    n += getters ? row.getInt(0) + row.getString(1).length + row.getString(3).length : row.length;
            }

            return Prepared(rows, rows * rowBytes, &run);
        }

        return BenchCase(name, &prepare, 100_000);
    }

    return [
        copyInCase("copyIn/text writeRow 5 fields", CopyFormat.text),
        copyInCase("copyIn/csv writeRow 5 fields", CopyFormat.csv),
        copyRawCase(),
        copyOutCase("copyOut/text rows", "COPY items TO STDOUT", CopyFormat.text, false),
        copyOutCase("copyOut/text rows getters", "COPY items TO STDOUT", CopyFormat.text, true),
        copyOutCase("copyOut/csv rows", "COPY items TO STDOUT (FORMAT csv)", CopyFormat.csv, false),
        copyOutCase("copyOut/binary rows", "COPY items TO STDOUT (FORMAT binary)", CopyFormat.binary, false),
        copyOutCase("copyOut/binary rows getters", "COPY items TO STDOUT (FORMAT binary)", CopyFormat.binary,
                true),
    ];
}
