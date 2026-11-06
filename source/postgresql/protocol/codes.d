/++
Constants of the PostgreSQL frontend/backend protocol: protocol versions,
special request codes, message types and authentication request codes.

See_Also: the PostgreSQL manual, "Frontend/Backend Protocol" and "Message Formats".

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module postgresql.protocol.codes;

/// Protocol version 3.0 (major in the high 16 bits, minor in the low 16 bits).
enum uint protocol30 = 3 << 16;
/// Protocol version 3.2 (PostgreSQL 18): longer cancel keys.
enum uint protocol32 = (3 << 16) | 2;

/// Codes sent in place of a protocol version, before a startup message.
enum RequestCode : uint
{
    /// Asks the server to cancel the query of another connection.
    cancel = (1234 << 16) | 5678,
    /// Asks whether the server accepts TLS.
    ssl = (1234 << 16) | 5679,
    /// Asks whether the server accepts GSSAPI encryption (not used).
    gssEncryption = (1234 << 16) | 5680,
}

/// Message types sent by the backend (the first byte of each message).
enum BackendMessage : char
{
    authentication = 'R', /// AuthenticationOk, AuthenticationSASL, ...
    backendKeyData = 'K', /// process ID and secret key, for cancel requests
    bindComplete = '2', /// Bind done
    closeComplete = '3', /// Close done
    commandComplete = 'C', /// a statement finished; carries its command tag
    copyData = 'd', /// COPY data
    copyDone = 'c', /// end of COPY data
    copyInResponse = 'G', /// the server waits for COPY data
    copyOutResponse = 'H', /// COPY data follows
    copyBothResponse = 'W', /// COPY in both directions (replication)
    dataRow = 'D', /// one row of a result
    emptyQueryResponse = 'I', /// the query string was empty
    errorResponse = 'E', /// an error
    functionCallResponse = 'V', /// result of the function call protocol (not used)
    negotiateProtocolVersion = 'v', /// the server supports an older minor version or not all options
    noData = 'n', /// the statement returns no rows
    noticeResponse = 'N', /// a warning or other notice
    notificationResponse = 'A', /// a NOTIFY on a channel the session listens to
    parameterDescription = 't', /// parameter types of a prepared statement
    parameterStatus = 'S', /// a run-time parameter's current value
    parseComplete = '1', /// Parse done
    portalSuspended = 's', /// Execute stopped at its row limit
    readyForQuery = 'Z', /// the server is ready for the next command; carries the transaction status
    rowDescription = 'T', /// the columns of a result
}

/// Message types sent by the frontend.
enum FrontendMessage : char
{
    bind = 'B', /// binds parameters to a prepared statement, making a portal
    close = 'C', /// closes a prepared statement or portal
    copyData = 'd', /// COPY data
    copyDone = 'c', /// end of COPY data
    copyFail = 'f', /// aborts COPY FROM STDIN
    describe = 'D', /// asks for a statement's or portal's description
    execute = 'E', /// runs a portal
    flush = 'H', /// asks the server to send what it has
    parse = 'P', /// prepares a statement
    password = 'p', /// PasswordMessage, SASLInitialResponse, SASLResponse
    query = 'Q', /// simple query
    sync = 'S', /// ends an extended-query batch
    terminate = 'X', /// closes the session
}

/// Authentication request codes (the first field of an `R` message).
enum AuthRequest : int
{
    ok = 0, /// authentication succeeded
    kerberosV5 = 2, /// not supported by PostgreSQL any more
    cleartextPassword = 3, /// send the password as is
    md5Password = 5, /// send the MD5 hash of the password with a 4-byte salt
    scmCredential = 6, /// Unix-socket credentials (not supported)
    gss = 7, /// GSSAPI
    gssContinue = 8, /// GSSAPI or SSPI data
    sspi = 9, /// SSPI
    sasl = 10, /// SASL: the mechanisms follow
    saslContinue = 11, /// SASL challenge
    saslFinal = 12, /// SASL outcome data
}

/// Transaction status reported by ReadyForQuery.
enum TransactionStatus : char
{
    idle = 'I', /// not in a transaction block
    inTransaction = 'T', /// in a transaction block
    failed = 'E', /// in a failed transaction block: commands are rejected until it ends
}
