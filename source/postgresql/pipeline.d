/++
Pipelines: several statements sent together and answered in order, with one
round trip for statements already in the statement cache (two for new ones:
parse and describe first).

In `PipelineMode.transaction` (the default) the statements form one implicit
transaction (or run inside the current transaction block): after an error the
server skips the rest, and outside a block it rolls back the earlier ones.
In `PipelineMode.independent` each statement is its own unit (a Sync after
each): an error affects only its statement.

Results are read completely (rows included) before `run` returns, so keep
pipelines to statements with modest results. Very large pipelines can stall:
the client sends everything before reading, so a server that fills its
socket buffer with results waits for the client to read them.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module postgresql.pipeline;

import postgresql.connection : affectedRows, Connection;
import postgresql.exception : ServerException, ServerMessage;
import postgresql.params : hasVariant, rewritePlaceholders;
import postgresql.result : ColumnInfo, Row;
import postgresql.statement : makeEncoder, ParamEncoder;

@safe:

/// How the statements of a pipeline relate (see the module documentation).
enum PipelineMode
{
    /// One implicit transaction: an error skips the following statements.
    transaction,
    /// Each statement on its own: an error affects only its statement.
    independent,
}

/// The outcome of one statement of a pipeline.
struct PipelineResult
{
    /// The columns; empty for a statement without rows.
    const(ColumnInfo)[] columns;
    /// The rows.
    Row[] rows;
    /// The command tag (e.g. `INSERT 0 1`); null if the statement failed or was skipped.
    string commandTag;
    /// Whether the statement failed (its error is in `error`).
    bool failed;
    /// Whether the statement was not run because an earlier one failed (`PipelineMode.transaction`).
    bool skipped;
    /// The error of a failed statement.
    ServerMessage error;

    /// The number of rows the statement affected (from its command tag).
    @property ulong affectedRows() const pure
    {
        return .affectedRows(commandTag);
    }

    /// Throws the statement's error, if it failed.
    void throwIfFailed() const
    {
        if (failed)
            throw new ServerException(error);
    }
}

/++
Statements to run together on a connection (`Connection.pipeline`). Add them
with `add`, then `run` sends them and returns their results.
+/
final class Pipeline
{
    private Connection conn;
    private PipelineMode mode;
    private string[] sqls;
    private ParamEncoder[] encoders;

    package this(Connection conn, PipelineMode mode) pure nothrow
    {
        this.conn = conn;
        this.mode = mode;
    }

    /++
    Adds a statement with its parameter values (placeholders as in
    `Connection.query`). Returns its index in the results.
    +/
    size_t add(Args...)(string sql, Args args)
    {
        static if (Args.length == 0)
        {
            sqls ~= sql;
            encoders ~= null;
        }
        else
        {
            size_t count;
            sqls ~= conn.options.rewritePlaceholders ? rewritePlaceholders(sql, count) : sql;
            static if (hasVariant!Args)
                encoders ~= (() @trusted => makeEncoder(args))(); // Variant copies
            else
                encoders ~= makeEncoder(args);
        }
        const index = sqls.length;
        return index - 1; // added above: at least one
    }

    /// Number of statements added and not run yet.
    @property size_t length() const pure nothrow
    {
        return sqls.length;
    }

    /++
    Sends the statements and reads all their results. The pipeline is empty afterwards.

    Throws: `ClientException` for parameter values that don't fit; `ServerException`
    if a statement can't be parsed (then none is run). Errors of running
    statements are in their results (`PipelineResult.failed`).
    +/
    PipelineResult[] run()
    {
        scope (exit)
        {
            sqls = null;
            encoders = null;
        }
        if (sqls.length == 0)
            return null;
        return conn.runPipeline(sqls, encoders, mode == PipelineMode.transaction);
    }
}
