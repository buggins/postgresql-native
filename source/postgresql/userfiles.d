/++
The user's files that libpq reads too: the password file (`~/.pgpass`) and
the default TLS files in `~/.postgresql`.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module postgresql.userfiles;

@safe:

/++
The password for a connection from a password file: the first line whose
host, port, database and user fields match (`*` matches anything); null if
none does, or the file is missing, unreadable, or (POSIX) readable by the
group or others.

Params:
    file = the password file; empty for the default (`defaultPassFile`).
    host = the host connected to.
    port = its port.
    database = the database.
    user = the user name.
+/
package string passwordFromFile(string file, string host, ushort port, string database, string user)
{
    import std.conv : to;
    import std.file : FileException, readText;
    import std.string : lineSplitter;
    import std.utf : UTFException;

    if (file.length == 0)
        file = defaultPassFile();
    if (file.length == 0 || !isPrivateFile(file))
        return null;
    string text;
    try
        text = readText(file);
    catch (FileException)
        return null;
    catch (UTFException)
        return null;
    const wanted = [host, port.to!string, database, user];
    foreach (line; text.lineSplitter)
    {
        if (line.length == 0 || line[0] == '#')
            continue;
        string[] fields;
        if (!splitPassLine(line, fields))
            continue;
        bool matches = true;
        foreach (i; 0 .. 4)
            matches = matches && (fields[i] == "*" || fields[i] == wanted[i]);
        if (matches)
            return fields[4];
    }
    return null;
}

/// Splits a password file line into its 5 fields, unescaping `\x`; false if it has fewer fields.
private bool splitPassLine(const(char)[] line, out string[] fields) pure
{
    char[] current;
    bool escaped;
    foreach (c; line)
    {
        if (escaped)
        {
            current ~= c;
            escaped = false;
        }
        else if (c == '\\')
            escaped = true;
        else if (c == ':' && fields.length < 4)
        {
            fields ~= current.idup;
            current = null;
        }
        else
            current ~= c;
    }
    if (fields.length < 4)
        return false;
    fields ~= current.idup;
    return true;
}

unittest
{
    string[] f;
    assert(splitPassLine(`h:5432:db:u:p\:w\\d:x`, f) && f == ["h", "5432", "db", "u", `p:w\d:x`]);
    assert(splitPassLine(`a\:b:*:*:*:`, f) && f == ["a:b", "*", "*", "*", ""]);
    assert(!splitPassLine("h:5432:db:u", f));
}

unittest
{
    import std.file : remove, tempDir, write;
    import std.path : buildPath;
    import std.process : thisProcessID;
    import std.conv : to;

    const path = buildPath(tempDir, "pgn-pgpass-" ~ thisProcessID.to!string);
    write(path, "# comment\nother:5432:*:app:wrong\n*:5432:sales:app:s\\:cret\n*:*:*:*:fallback\n");
    scope (exit)
        remove(path);
    makePrivate(path);
    assert(passwordFromFile(path, "db", 5432, "sales", "app") == "s:cret");
    assert(passwordFromFile(path, "other", 5432, "x", "app") == "wrong");
    assert(passwordFromFile(path, "db", 5433, "sales", "app") == "fallback");
    assert(passwordFromFile(path ~ ".missing", "db", 5432, "sales", "app") is null);
    version (Posix)
    {
        import std.file : setAttributes;

        setAttributes(path, octal!"644");
        assert(passwordFromFile(path, "db", 5432, "sales", "app") is null, "readable by others: ignored");
    }
}

version (unittest) private void makePrivate(string path)
{
    version (Posix)
    {
        import std.file : setAttributes;

        setAttributes(path, octal!"600");
    }
}

version (unittest) private import std.conv : octal;

/// Whether `file` is a regular file that only its owner may access (always true outside POSIX).
private bool isPrivateFile(string file)
{
    import std.file : FileException, getAttributes;

    version (Posix)
    {
        import core.sys.posix.sys.stat : S_IFMT, S_IFREG;

        try
        {
            const mode = getAttributes(file);
            return (mode & S_IFMT) == S_IFREG && (mode & octal077) == 0;
        }
        catch (FileException)
            return false;
    }
    else
    {
        import std.file : exists, isFile;

        try
            return exists(file) && isFile(file);
        catch (FileException)
            return false;
    }
}

private enum uint octal077 = 63; // group and others: rwx

/// The default password file: `~/.pgpass`, or `%APPDATA%\postgresql\pgpass.conf` on Windows; empty if unknown.
string defaultPassFile()
{
    import std.path : buildPath;
    import std.process : environment;

    version (Windows)
    {
        const dir = environment.get("APPDATA");
        return dir.length ? buildPath(dir, "postgresql", "pgpass.conf") : null;
    }
    else
    {
        const home = environment.get("HOME");
        return home.length ? buildPath(home, ".pgpass") : null;
    }
}

/++
The user's PostgreSQL directory with the default TLS files: `~/.postgresql`,
or `%APPDATA%\postgresql` on Windows; empty if unknown.
+/
string userDirectory()
{
    import std.path : buildPath;
    import std.process : environment;

    version (Windows)
    {
        const dir = environment.get("APPDATA");
        return dir.length ? buildPath(dir, "postgresql") : null;
    }
    else
    {
        const home = environment.get("HOME");
        return home.length ? buildPath(home, ".postgresql") : null;
    }
}

/// `name` in the user's PostgreSQL directory if that file exists; else null.
package string userFile(string name)
{
    import std.file : exists, FileException;
    import std.path : buildPath;

    const dir = userDirectory();
    if (dir.length == 0)
        return null;
    const path = buildPath(dir, name);
    try
        return exists(path) ? path : null;
    catch (FileException)
        return null;
}
