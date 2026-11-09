/++
The user's files that libpq reads too: the password file (`~/.pgpass`) and
the default TLS files in `~/.postgresql`.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module postgresql.userfiles;

import postgresql.exception : ClientException;

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
private enum uint groupRead = 32; // 0040

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

/++
Checks a private key file as libpq does on POSIX systems: a regular file that,
owned by the current user, neither group nor others may access, or, owned by
root, that only the group may read. Files of other owners aren't checked.

Throws: `ClientException` otherwise.
+/
package void checkPrivateKeyFile(string file)
{
    version (Posix)
    {
        import core.sys.posix.sys.stat : S_IFMT, S_IFREG;
        import std.file : DirEntry, FileException;

        uint mode, owner;
        try
        {
            const stat = DirEntry(file).statBuf;
            mode = stat.st_mode;
            owner = stat.st_uid;
        }
        catch (FileException)
            return; // reported when the key is loaded
        if ((mode & S_IFMT) != S_IFREG)
            throw new ClientException("The private key file " ~ file ~ " is not a regular file");
        import core.sys.posix.unistd : geteuid;

        // libpq's rule; a client running as root gets the stricter one for its own (root's) files
        const uint allowed = owner == geteuid() ? 0 : owner == 0 ? groupRead : octal077;
        if ((mode & octal077 & ~allowed) != 0)
            throw new ClientException("The private key file " ~ file ~ " has group or world access; "
                    ~ "it must have permissions u=rw (0600) or less if owned by the current user, "
                    ~ "or u=rw,g=r (0640) or less if owned by root");
    }
}

version (Posix) unittest
{
    import std.conv : to;
    import std.exception : assertThrown;
    import std.file : remove, setAttributes, tempDir, write;
    import std.path : buildPath;
    import std.process : thisProcessID;

    const file = buildPath(tempDir, "pgnative-key-" ~ thisProcessID.to!string);
    write(file, "key");
    scope (exit)
        remove(file);
    setAttributes(file, octal!"600");
    checkPrivateKeyFile(file);
    setAttributes(file, octal!"640");
    assertThrown!ClientException(checkPrivateKeyFile(file));
    checkPrivateKeyFile(buildPath(tempDir, "pgnative-no-such-key"));
    assertThrown!ClientException(checkPrivateKeyFile(tempDir));
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

/++
The keywords of the connection service `name` (libpq's `service`): the
`[name]` section of the first service file that has it, the user's
(`serviceFile`, else `PGSERVICEFILE`, else `~/.pg_service.conf`, or
`%APPDATA%\postgresql\.pg_service.conf` on Windows) before the system's
(`pg_service.conf` in `PGSYSCONFDIR`, else in `/etc/postgresql-common`,
`/etc/sysconfig/pgsql` or `/etc`).

Throws: `ClientException` if no file defines the service, or its section
is malformed.
+/
package string[string] serviceParams(string name, string serviceFile)
{
    import std.path : buildPath;
    import std.process : environment;

    string[] files;
    if (serviceFile.length)
        files ~= serviceFile;
    else if (const env = environment.get("PGSERVICEFILE"))
        files ~= env;
    else
    {
        version (Windows)
        {
            const dir = environment.get("APPDATA");
            if (dir.length)
                files ~= buildPath(dir, "postgresql", ".pg_service.conf");
        }
        else
        {
            const home = environment.get("HOME");
            if (home.length)
                files ~= buildPath(home, ".pg_service.conf");
        }
    }
    if (const dir = environment.get("PGSYSCONFDIR"))
        files ~= buildPath(dir, "pg_service.conf");
    else
        foreach (dir; ["/etc/postgresql-common", "/etc/sysconfig/pgsql", "/etc"])
            files ~= buildPath(dir, "pg_service.conf");
    foreach (file; files)
    {
        string text;
        if (!readIfExists(file, text))
            continue;
        string[string] params;
        if (parseServiceFile(text, name, file, params))
            return params;
    }
    throw new ClientException("Definition of service '" ~ name ~ "' not found");
}

private bool readIfExists(string file, out string text)
{
    import std.file : exists, FileException, isFile, readText;
    import std.utf : UTFException;

    try
    {
        if (!exists(file) || !isFile(file))
            return false;
        text = readText(file);
        return true;
    }
    catch (FileException)
        return false;
    catch (UTFException)
        throw new ClientException("The service file " ~ file ~ " is not UTF-8");
}

/++
Reads the section `[name]` of a service file into `params`: `key=value`
lines (the value is the rest of the line), `#` comments, blank lines.
Returns: whether the file has the section.
Throws: `ClientException` for a malformed line in the section.
+/
package bool parseServiceFile(string text, string name, string file, ref string[string] params) pure
{
    import std.string : indexOf, lineSplitter, strip;

    bool inSection, found;
    foreach (raw; text.lineSplitter)
    {
        const line = raw.strip;
        if (line.length == 0 || line[0] == '#')
            continue;
        if (line[0] == '[')
        {
            if (found)
                break; // the section ended
            const close = line.indexOf(']');
            if (close < 0)
                throw new ClientException("Syntax error in service file " ~ file ~ ": " ~ line);
            inSection = line[1 .. close] == name;
            found = inSection;
            continue;
        }
        if (!inSection)
            continue;
        const eq = line.indexOf('=');
        if (eq <= 0)
            throw new ClientException("Syntax error in service file " ~ file ~ ": " ~ line);
        const key = line[0 .. eq].strip;
        if (key == "service" || key == "servicefile")
            throw new ClientException("Nested service specifications are not supported in service file " ~ file);
        params[key] = line[eq + 1 .. $].strip;
    }
    return found;
}

///
unittest
{
    import std.exception : assertThrown;

    const text = "# comment\n[other]\nhost=x\n\n[sales]\nhost = db1,db2\ndbname=sales\n  sslmode=verify-full\n"
        ~ "application_name=a = b\n[later]\nhost=y\n";
    string[string] p;
    assert(parseServiceFile(text, "sales", "f", p));
    assert(p == [
        "host": "db1,db2",
        "dbname": "sales",
        "sslmode": "verify-full",
        "application_name": "a = b"
    ]);
    string[string] none;
    assert(!parseServiceFile(text, "missing", "f", none) && none.length == 0);
    assertThrown!ClientException(parseServiceFile("[s]\nnonsense\n", "s", "f", none));
    assertThrown!ClientException(parseServiceFile("[s]\nservice=t\n", "s", "f", none));
}

unittest
{
    import std.conv : to;
    import std.exception : assertThrown;
    import std.file : remove, tempDir, write;
    import std.path : buildPath;
    import std.process : thisProcessID;

    const file = buildPath(tempDir, "pgn-service-" ~ thisProcessID.to!string);
    write(file, "[test]\nhost=svc.example\nport=6000\n");
    scope (exit)
        remove(file);
    assert(serviceParams("test", file) == ["host": "svc.example", "port": "6000"]);
    assertThrown!ClientException(serviceParams("no-such-service", file));
}
