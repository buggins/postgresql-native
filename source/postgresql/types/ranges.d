/++
Typed ranges: `Range!T` for `int4range`, `int8range`, `numrange`,
`daterange`, `tsrange`, `tstzrange` and user-defined range types.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module postgresql.types.ranges;

/++
A range of `T` values: a lower and an upper bound, each inclusive or
exclusive, or infinite (unbounded); or empty. By default the lower bound is
included and the upper one excluded, as the server writes discrete ranges.

Example:
---
auto r = conn.queryValue!(Range!int)("SELECT int4range(1, 10)");   // 1 to 9
conn.exec("INSERT INTO bookings (during) VALUES (?)", Range!DateTime(start, end));
---
+/
struct Range(T)
{
    /// The lower bound (unused when `lowerInfinite` or `empty`).
    T lower;
    /// The upper bound (unused when `upperInfinite` or `empty`).
    T upper;
    /// Whether the lower bound is included (`[`).
    bool lowerInclusive = true;
    /// Whether the upper bound is included (`]`).
    bool upperInclusive;
    /// Whether there is no lower bound.
    bool lowerInfinite;
    /// Whether there is no upper bound.
    bool upperInfinite;
    /// Whether the range is empty (contains nothing).
    bool empty;

    /// A range from `lower` to `upper`, by default with `lower` included and `upper` excluded.
    this(T lower, T upper, bool lowerInclusive = true, bool upperInclusive = false)
    {
        this.lower = lower;
        this.upper = upper;
        this.lowerInclusive = lowerInclusive;
        this.upperInclusive = upperInclusive;
    }

    /// The empty range.
    static Range emptyRange()
    {
        Range r;
        r.empty = true;
        r.lowerInclusive = false;
        return r;
    }

    /// A range from `lower` (inclusive unless said otherwise) with no upper bound.
    static Range from(T lower, bool inclusive = true)
    {
        Range r;
        r.lower = lower;
        r.lowerInclusive = inclusive;
        r.upperInfinite = true;
        return r;
    }

    /// A range up to `upper` (exclusive unless said otherwise) with no lower bound.
    static Range until(T upper, bool inclusive = false)
    {
        Range r;
        r.upper = upper;
        r.upperInclusive = inclusive;
        r.lowerInclusive = false;
        r.lowerInfinite = true;
        return r;
    }
}

///
@safe unittest
{
    const r = Range!int(1, 10);
    assert(r.lowerInclusive && !r.upperInclusive && !r.empty);
    assert(Range!int.emptyRange().empty && Range!int.from(5).upperInfinite && Range!int.until(5).lowerInfinite);
}

/// Whether `T` is a `Range!X`.
enum bool isRange(T) = is(T : Range!X, X);
