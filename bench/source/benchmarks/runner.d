/++
Benchmark runner: a table of cases, each prepared once and then timed over
several runs. Reports the median and minimum time, throughput and the bytes
allocated per row.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module benchmarks.runner;

import core.time : Duration;

/// A case ready to run: the work of one run and its size.
struct Prepared
{
    /// Rows processed by one run.
    size_t rows;
    /// Wire bytes processed by one run (for MB/s), or 0.
    size_t bytes;
    /// One run.
    void delegate() run;
}

/// A benchmark case.
struct BenchCase
{
    /// Name, e.g. `"query/rows"`; `--filter` matches substrings of it.
    string name;
    /// Builds the input for `rows` rows (not timed).
    Prepared delegate(size_t rows) prepare;
    /// Rows to use when `--rows` is not given.
    size_t defaultRows = 1_000_000;
}

/// The measurements of one case.
struct Result
{
    string name; ///
    size_t rows; ///
    size_t bytes; ///
    Duration median; ///
    Duration min; ///
    ulong allocatedPerRun; /// bytes allocated by the median run
    size_t collections; /// GC collections during the runs (besides the runner's own between runs)
    size_t runs; /// measured runs
}

/++
Runs `cases` whose name contains `filter`; `rows` = 0 uses each case's
default. Each case runs at least `runs` times and until `minTime` of
measured time has passed (at most 1000 runs).
+/
Result[] runAll(BenchCase[] cases, string filter, size_t rows, size_t runs, Duration minTime,
        void delegate(Result) report)
{
    import std.algorithm.searching : canFind;

    Result[] results;
    foreach (c; cases)
        if (filter.length == 0 || c.name.canFind(filter))
        {
            const r = runOne(c, rows ? rows : c.defaultRows, runs, minTime);
            report(r);
            results ~= r;
        }
    return results;
}

/// Prepares `c`, runs it once to warm up, then measures it (see `runAll`).
Result runOne(BenchCase c, size_t rows, size_t runs, Duration minTime)
{
    import core.memory : GC;
    import std.algorithm.sorting : sort;
    import std.datetime.stopwatch : StopWatch;

    auto prepared = c.prepare(rows);
    prepared.run(); // warm-up
    struct Run
    {
        Duration time;
        ulong allocated;
    }

    Run[] measured;
    Duration total;
    const collectionsBefore = GC.profileStats().numCollections;
    while (measured.length < 1000 && (measured.length < runs || total < minTime))
    {
        GC.collect(); // start each run with a clean heap (not timed)
        const allocatedBefore = GC.allocatedInCurrentThread();
        StopWatch sw;
        sw.start();
        prepared.run();
        sw.stop();
        measured ~= Run(sw.peek(), GC.allocatedInCurrentThread() - allocatedBefore);
        total += sw.peek();
    }
    const all = GC.profileStats().numCollections - collectionsBefore;
    const collections = all > measured.length ? all - measured.length : 0; // not the runner's own
    sort!((a, b) => a.time < b.time)(measured);
    const median = measured[$ / 2];
    return Result(c.name, prepared.rows, prepared.bytes, median.time, measured[0].time, median.allocated,
            collections, measured.length);
}

/// The header of the Markdown table.
string markdownHeader()
{
    return "| case | rows | wire MB | median ms | min ms | Mrows/s | MB/s | alloc B/row | runs |\n"
        ~ "|---|---:|---:|---:|---:|---:|---:|---:|---:|";
}

/// One result as a row of the Markdown table.
string markdownRow(const Result r)
{
    import std.format : format;

    const seconds = r.median.total!"hnsecs" / 1e7;
    const mb = r.bytes / 1e6;
    const mrows = r.rows / seconds / 1e6;
    return format("| %s | %s | %.1f | %.2f | %.2f | %s | %s | %.1f | %s |", r.name, r.rows, mb,
            seconds * 1e3, r.min.total!"hnsecs" / 1e4, format(mrows < 1 ? "%.3f" : "%.1f", mrows),
            r.bytes ? format("%.0f", mb / seconds) : "", cast(double) r.allocatedPerRun / r.rows, r.runs);
}

/// The CSV header and one result as a CSV line.
enum csvHeader = "case,rows,bytes,median_ns,min_ns,allocated_bytes,collections,runs";

/// ditto
string csvRow(const Result r)
{
    import std.format : format;

    import std.array : replace;

    // Names contain commas: quote them, doubling quotes
    return format("\"%s\",%s,%s,%s,%s,%s,%s,%s", r.name.replace(`"`, `""`), r.rows, r.bytes, r.median.total!"nsecs",
            r.min.total!"nsecs", r.allocatedPerRun, r.collections, r.runs);
}
