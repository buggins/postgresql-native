/++
postgresql-native in an ordinary program (blocking sockets): connect, run
statements with parameters, read rows into structs, insert structs, use a
transaction and a pipeline.

Run with `dub run :example-basic -- [connection string]`. The connection
string is a URI (`postgresql://user:password@host/dbname`) or a `key=value`
string; the `PG*` environment variables (`PGHOST`, `PGUSER`, `PGPASSWORD`,
`PGDATABASE`, ...) fill in what it leaves out, as for `psql`.
+/
module app;

import std.datetime.date : Date;
import std.stdio : writefln, writeln;
import std.typecons : Nullable;

import postgresql;

/// A row of the `books` table.
struct Book
{
    int id; /// The key.
    string title; /// The title.
    @column("published_on") Nullable!Date published; /// Column `published_on`; NULL for unpublished books.
    Decimal price; /// The price.
}

void main(string[] args)
{
    auto conn = new Connection(fromEnvironment(args.length > 1 ? args[1] : null));
    scope (exit)
        conn.close();
    writefln("Connected to PostgreSQL %s at %s (%s)", conn.serverVersion, conn.host,
            conn.isEncrypted ? "TLS " ~ conn.tlsVersion : "not encrypted");

    // Statements without parameters may hold several commands (simple protocol)
    conn.exec(
            "CREATE TEMP TABLE books (id int PRIMARY KEY, title text NOT NULL, published_on date,"
            ~ " price numeric(8, 2))");

    // Parameters: ? or $1, $2, ...; values are sent separately from the SQL
    conn.exec("INSERT INTO books VALUES (?, ?, ?, ?)", 1, "The D Programming Language", Date(2010, 6, 12),
            Decimal.fromString("49.99"));

    // Structs: fields map to columns by name (or @column); insert writes them in one statement
    conn.insert("books", [
        Book(2, "Programming in D", Nullable!Date(Date(2015, 1, 1)), Decimal.fromString("0")),
        Book(3, "A future book", Nullable!Date.init, Decimal.fromString("25.50")),
    ]);
    foreach (book; conn.query!Book("SELECT * FROM books WHERE price < ? ORDER BY id", 30))
        writefln("  %s: %s, %s, %s", book.id, book.title, book.published.isNull ? "unpublished"
                : book.published.get.toISOExtString, book.price);

    // Rows without structs: typed getters by index or name
    auto result = conn.query("SELECT title, length(title) AS len FROM books ORDER BY len DESC");
    foreach (row; result)
        writefln("  %-30s %s", row.getString("title"), row.getInt("len"));

    // Single values
    writeln("Books: ", conn.queryValue!long("SELECT count(*) FROM books"));

    // A transaction
    conn.begin();
    conn.exec("UPDATE books SET price = price * ? WHERE id = ?", Decimal.fromString("0.9"), 1);
    conn.commit();

    // A pipeline: several statements in one round trip
    auto p = conn.pipeline();
    p.add("UPDATE books SET price = price + 1 WHERE id = ?", 2);
    const total = p.add("SELECT sum(price) FROM books");
    auto results = p.run();
    writeln("Total price: ", results[total].rows[0].getDecimal(0));
}
