/++
The geometric types: `point`, `line`, `lseg`, `box`, `path`, `polygon`,
`circle`. Their text uses the server's float8 text (shortest exact digits,
`NaN`, `Infinity`).

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module postgresql.types.geometric;

import postgresql.exception : ClientException, ProtocolException;
import postgresql.types.floats : formatFloat8;

@safe:

/// A `point`: `(x,y)`.
struct Point
{
    double x = 0; ///
    double y = 0; ///

    /// The text PostgreSQL writes.
    string toString() const
    {
        return "(" ~ formatFloat8(x) ~ "," ~ formatFloat8(y) ~ ")";
    }
}

/// A `line` given by its equation Ax + By + C = 0: `{A,B,C}`.
struct Line
{
    double a = 0; ///
    double b = 0; ///
    double c = 0; ///

    /// The text PostgreSQL writes.
    string toString() const
    {
        return "{" ~ formatFloat8(a) ~ "," ~ formatFloat8(b) ~ "," ~ formatFloat8(c) ~ "}";
    }
}

/// A line segment (`lseg`): `[(x1,y1),(x2,y2)]`.
struct LineSegment
{
    Point start; ///
    Point end; ///

    /// The text PostgreSQL writes.
    string toString() const
    {
        return "[" ~ start.toString() ~ "," ~ end.toString() ~ "]";
    }
}

/// A `box`: the upper right and the lower left corners, `(x2,y2),(x1,y1)` (the server orders them).
struct Box
{
    Point high; ///
    Point low; ///

    /// The text PostgreSQL writes.
    string toString() const
    {
        return high.toString() ~ "," ~ low.toString();
    }
}

/// A `path`: open `[(x1,y1),...]` or closed `((x1,y1),...)`.
struct Path
{
    Point[] points; ///
    bool closed; ///

    /// The text PostgreSQL writes.
    string toString() const
    {
        return (closed ? "(" : "[") ~ pointList(points) ~ (closed ? ")" : "]");
    }
}

/// A `polygon`: `((x1,y1),...)`.
struct Polygon
{
    Point[] points; ///

    /// The text PostgreSQL writes.
    string toString() const
    {
        return "(" ~ pointList(points) ~ ")";
    }
}

/// A `circle`: `<(x,y),r>`.
struct Circle
{
    Point center; ///
    double radius = 0; ///

    /// The text PostgreSQL writes.
    string toString() const
    {
        return "<" ~ center.toString() ~ "," ~ formatFloat8(radius) ~ ">";
    }
}

private string pointList(const Point[] points)
{
    string text;
    foreach (i, p; points)
        text ~= (i ? "," : "") ~ p.toString();
    return text;
}

/// Whether `T` is one of the geometric types of this module.
enum bool isGeometric(T) = is(T == Point) || is(T == Line) || is(T == LineSegment) || is(T == Box)
    || is(T == Path) || is(T == Polygon) || is(T == Circle);

/++
Reads `T` from its binary format (big-endian float8s; paths with a closed
flag and a count, polygons with a count).

Throws: `ProtocolException` for malformed data.
+/
T geometricFromBinary(T)(scope const(ubyte)[] data) pure if (isGeometric!T)
{
    size_t at;
    double number()
    {
        if (at + 8 > data.length)
            throw new ProtocolException("Malformed " ~ T.stringof ~ " value");
        ulong bits;
        foreach (b; data[at .. at + 8])
            bits = bits << 8 | b;
        at += 8;
        return (() @trusted => *cast(double*)&bits)(); // reinterprets the 8 bytes
    }

    Point point()
    {
        const x = number();
        return Point(x, number());
    }

    Point[] points()
    {
        if (at + 4 > data.length)
            throw new ProtocolException("Malformed " ~ T.stringof ~ " value");
        const n = cast(uint)(data[at] << 24 | data[at + 1] << 16 | data[at + 2] << 8 | data[at + 3]);
        at += 4;
        if (n > (data.length - at) / 16)
            throw new ProtocolException("Malformed " ~ T.stringof ~ " value");
        auto list = new Point[n];
        foreach (ref p; list)
            p = point();
        return list;
    }

    T value;
    static if (is(T == Point))
        value = point();
    else static if (is(T == Line))
    {
        value.a = number();
        value.b = number();
        value.c = number();
    }
    else static if (is(T == LineSegment))
    {
        value.start = point();
        value.end = point();
    }
    else static if (is(T == Box))
    {
        value.high = point();
        value.low = point();
    }
    else static if (is(T == Path))
    {
        if (data.length < 1)
            throw new ProtocolException("Malformed path value");
        value.closed = data[0] != 0;
        at = 1;
        value.points = points();
    }
    else static if (is(T == Polygon))
        value.points = points();
    else static if (is(T == Circle))
    {
        value.center = point();
        value.radius = number();
    }
    if (at != data.length)
        throw new ProtocolException("Malformed " ~ T.stringof ~ " value");
    return value;
}

/// The binary format of `value`.
immutable(ubyte)[] geometricToBinary(T)(const T value) pure if (isGeometric!T)
{
    ubyte[] data;
    void number(double d)
    {
        const bits = (() @trusted => *cast(const(ulong)*)&d)(); // reinterprets the 8 bytes
        foreach_reverse (i; 0 .. 8)
            data ~= cast(ubyte)(bits >> (8 * i));
    }

    void point(const Point p)
    {
        number(p.x);
        number(p.y);
    }

    void points(const Point[] list)
    {
        const n = cast(uint) list.length;
        data ~= [cast(ubyte)(n >> 24), cast(ubyte)(n >> 16), cast(ubyte)(n >> 8), cast(ubyte) n];
        foreach (p; list)
            point(p);
    }

    static if (is(T == Point))
        point(value);
    else static if (is(T == Line))
    {
        number(value.a);
        number(value.b);
        number(value.c);
    }
    else static if (is(T == LineSegment))
    {
        point(value.start);
        point(value.end);
    }
    else static if (is(T == Box))
    {
        point(value.high);
        point(value.low);
    }
    else static if (is(T == Path))
    {
        data ~= value.closed ? 1 : 0;
        points(value.points);
    }
    else static if (is(T == Polygon))
        points(value.points);
    else static if (is(T == Circle))
    {
        point(value.center);
        number(value.radius);
    }
    return (() @trusted => cast(immutable) data)(); // not referenced elsewhere
}

/++
Parses the text of a geometric value (as the server writes it, or
accepts it: the numbers in order; a path is open when it starts with `[`).

Throws: `ClientException` for malformed text.
+/
T parseGeometric(T)(string text) if (isGeometric!T)
{
    import std.string : strip;
    import postgresql.types.floats : parseFloat8;

    double[] numbers;
    const s = text.strip;
    size_t i;
    while (i < s.length)
    {
        const c = s[i];
        if (c == '(' || c == ')' || c == '[' || c == ']' || c == '{' || c == '}' || c == '<' || c == '>' || c == ','
                || c == ' ')
        {
            i++;
            continue;
        }
        const start = i;
        while (i < s.length && s[i] != ',' && s[i] != ')' && s[i] != ']' && s[i] != '}' && s[i] != '>' && s[i] != ' ')
            i++;
        numbers ~= parseFloat8(s[start .. i]);
    }

    void need(size_t n)
    {
        if (numbers.length != n)
            throw new ClientException("Invalid " ~ T.stringof ~ " text '" ~ text ~ "'");
    }

    Point[] pointsOf()
    {
        if (numbers.length % 2)
            need(numbers.length + 1);
        auto list = new Point[numbers.length / 2];
        foreach (k, ref p; list)
            p = Point(numbers[2 * k], numbers[2 * k + 1]);
        return list;
    }

    static if (is(T == Point))
    {
        need(2);
        return Point(numbers[0], numbers[1]);
    }
    else static if (is(T == Line))
    {
        need(3);
        return Line(numbers[0], numbers[1], numbers[2]);
    }
    else static if (is(T == LineSegment))
    {
        need(4);
        return LineSegment(Point(numbers[0], numbers[1]), Point(numbers[2], numbers[3]));
    }
    else static if (is(T == Box))
    {
        need(4);
        return Box(Point(numbers[0], numbers[1]), Point(numbers[2], numbers[3]));
    }
    else static if (is(T == Path))
        return Path(pointsOf(), s.length == 0 || s[0] != '[');
    else static if (is(T == Polygon))
        return Polygon(pointsOf());
    else static if (is(T == Circle))
    {
        need(3);
        return Circle(Point(numbers[0], numbers[1]), numbers[2]);
    }
}

///
unittest
{
    assert(Point(1.5, 2).toString() == "(1.5,2)" && Line(1, -1, 0).toString() == "{1,-1,0}");
    assert(Box(Point(2, 3), Point(0, 0)).toString() == "(2,3),(0,0)");
    assert(Path([Point(0, 0), Point(1, 1)], false).toString() == "[(0,0),(1,1)]");
    assert(Circle(Point(1, 2), 3).toString() == "<(1,2),3>");
    assert(parseGeometric!Path("((0,0),(1,1),(2,0))") == Path([
        Point(0, 0), Point(1, 1), Point(2, 0)
    ], true));
    assert(parseGeometric!LineSegment("[(0,0),(1,1)]") == LineSegment(Point(0, 0), Point(1, 1)));
    assert(parseGeometric!Circle("<(1,2),0.5>") == Circle(Point(1, 2), 0.5));
    const p = Polygon([Point(0, 0), Point(1, 1)]);
    assert(geometricFromBinary!Polygon(geometricToBinary(p)) == p);
    const path = Path([Point(1, 2)], true);
    assert(geometricFromBinary!Path(geometricToBinary(path)) == path);
}
