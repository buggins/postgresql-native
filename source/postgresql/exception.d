/++
Exceptions thrown by postgresql-native, and the fields of server errors and notices.

All of them derive from `dbwire.exception.DbException`:
$(UL
    $(LI `ServerException`: the server reported an error (ErrorResponse). After
        an `ERROR` the connection stays usable; after `FATAL` or `PANIC` the
        server closes it.)
    $(LI `ConnectionException`: network failure or timeout. The connection is closed.)
    $(LI `ProtocolException`: malformed or unexpected data from the server. The connection is closed.)
    $(LI `ClientException`: invalid use of the library, invalid options, or an unsupported feature.)
)

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module postgresql.exception;

public import dbwire.exception : ClientException, ConnectionException, DbException, ProtocolException;

import postgresql.protocol.messages : MessageBody;

/++
The fields of an ErrorResponse or a NoticeResponse. Fields the server didn't
send are empty (positions and line numbers 0).

See_Also: the PostgreSQL manual, "Error and Notice Message Fields".
+/
struct ServerMessage
{
    /// Severity, possibly localized: `ERROR`, `FATAL`, `PANIC`, `WARNING`, `NOTICE`, `DEBUG`, `INFO`, `LOG`.
    string severity;
    /// Severity, never localized (PostgreSQL 9.6 and later; else the same as `severity`).
    string severityNonLocalized;
    /// The SQLSTATE code, e.g. `42P01` (undefined table) or `28P01` (invalid password).
    string sqlState;
    /// The primary message.
    string message;
    /// An optional secondary message with more detail.
    string detail;
    /// An optional suggestion what to do.
    string hint;
    /// 1-based character position in the query where the error is, or 0.
    int position;
    /// 1-based position in an internally generated query (`internalQuery`), or 0.
    int internalPosition;
    /// The internally generated query (e.g. by a PL/pgSQL function) that failed.
    string internalQuery;
    /// Context: a call stack of PL/pgSQL functions and internal queries.
    string where;
    /// Schema of the object the error is about.
    string schemaName;
    /// Table the error is about.
    string tableName;
    /// Column the error is about.
    string columnName;
    /// Data type the error is about.
    string dataTypeName;
    /// Constraint the error is about.
    string constraintName;
    /// Server source file that reported it.
    string file;
    /// Line in that file, or 0.
    int line;
    /// Server routine that reported it.
    string routine;

    /// Whether the server ends the session after this error (`FATAL` or `PANIC`).
    @property bool isFatal() const @safe pure nothrow
    {
        const s = severityNonLocalized.length ? severityNonLocalized : severity;
        return s == "FATAL" || s == "PANIC";
    }

    /// The message as psql prints it: `ERROR:  relation "x" does not exist`, with detail and hint lines.
    string toString() const @safe pure
    {
        string text = (severity.length ? severity : "ERROR") ~ ":  " ~ message;
        if (detail.length)
            text ~= "\nDETAIL:  " ~ detail;
        if (hint.length)
            text ~= "\nHINT:  " ~ hint;
        return text;
    }

    /++
    Parses the body of an ErrorResponse or NoticeResponse: (code byte, string)
    pairs ending with a zero byte. Unknown codes are skipped, as the protocol asks.

    Throws: `ProtocolException` if the body is malformed.
    +/
    static ServerMessage parse(MessageBody body) @safe
    {
        static int number(string s) @safe pure nothrow @nogc
        {
            int n;
            foreach (c; s)
            {
                if (c < '0' || c > '9' || n > (int.max - (c - '0')) / 10)
                    return 0;
                n = n * 10 + (c - '0');
            }
            return n;
        }

        ServerMessage m;
        for (;;)
        {
            const code = body.readByte();
            if (code == 0)
                break;
            const value = body.readCString();
            switch (code)
            {
            case 'S':
                m.severity = value;
                break;
            case 'V':
                m.severityNonLocalized = value;
                break;
            case 'C':
                m.sqlState = value;
                break;
            case 'M':
                m.message = value;
                break;
            case 'D':
                m.detail = value;
                break;
            case 'H':
                m.hint = value;
                break;
            case 'P':
                m.position = number(value);
                break;
            case 'p':
                m.internalPosition = number(value);
                break;
            case 'q':
                m.internalQuery = value;
                break;
            case 'W':
                m.where = value;
                break;
            case 's':
                m.schemaName = value;
                break;
            case 't':
                m.tableName = value;
                break;
            case 'c':
                m.columnName = value;
                break;
            case 'd':
                m.dataTypeName = value;
                break;
            case 'n':
                m.constraintName = value;
                break;
            case 'F':
                m.file = value;
                break;
            case 'L':
                m.line = number(value);
                break;
            case 'R':
                m.routine = value;
                break;
            default:
                break;
            }
        }
        return m;
    }
}

///
@safe unittest
{
    static immutable ubyte[] body = cast(immutable(ubyte)[])(
            "SERROR\0VERROR\0C42P01\0"
            ~ "Mrelation \"nope\" does not exist\0P15\0Fparse_relation.c\0L1449\0Zfuture\0\0");
    const m = ServerMessage.parse(MessageBody(body, 'E'));
    assert(m.sqlState == "42P01" && m.position == 15 && m.line == 1449 && !m.isFatal);
    assert(m.toString() == `ERROR:  relation "nope" does not exist`);
}

/++
An error reported by the server, e.g. a syntax error, a constraint violation
or a failed login. All the fields of the ErrorResponse are in `error`.

After an `ERROR` the connection stays usable (a transaction block, if any, is
failed until rolled back); after `FATAL` or `PANIC` the server has closed it.
+/
class ServerException : DbException
{
    /// The error's fields.
    ServerMessage error;

    /++
    Creates the exception for `error`.

    Params:
        error = the parsed ErrorResponse.
        file = source file (filled in automatically).
        line = source line (filled in automatically).
    +/
    this(ServerMessage error, string file = __FILE__, size_t line = __LINE__) @safe pure
    {
        super(error.toString(), file, line);
        this.error = error;
    }

    /// The SQLSTATE code, e.g. `23505` (unique violation).
    @property string sqlState() const @safe pure nothrow
    {
        return error.sqlState;
    }
}

///
@safe unittest
{
    ServerMessage m;
    m.severity = "FATAL";
    m.sqlState = "28P01";
    m.message = "password authentication failed for user \"x\"";
    auto e = new ServerException(m);
    assert(e.sqlState == "28P01" && e.error.isFatal && e.msg == `FATAL:  password authentication failed for user "x"`);
}
