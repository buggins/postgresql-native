/++
The text forms of arrays, records (composite values), ranges, multiranges
and `hstore`: parsing them into their parts, and quoting parts as the server
does in its output.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module postgresql.types.textformat;

import postgresql.exception : ClientException;

@safe:

/// Whether `c` is a space character as the server's array, record and range parsers see it.
bool isSpace(char c) pure nothrow @nogc
{
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f';
}

/++
An array element as the server writes it in array text: in double quotes
(with `"` and `\` escaped by `\`) when it is empty, `NULL` in any case, or
contains `{`, `}`, `"`, `\`, the delimiter or a space.
+/
string quoteArrayElement(string s, char delimiter) pure
{
    import std.uni : sicmp;

    bool quote = s.length == 0 || sicmp(s, "NULL") == 0;
    foreach (c; s)
        quote = quote || c == '{' || c == '}' || c == '"' || c == '\\' || c == delimiter || isSpace(c);
    return quote ? quoted(s, '\\') : s;
}

/++
A record field as the server writes it in record text: in double quotes
(with `"` and `\` doubled) when it is empty or contains a parenthesis,
`,`, `"`, `\` or a space.
+/
string quoteRecordField(string s) pure
{
    bool quote = s.length == 0;
    foreach (c; s)
        quote = quote || c == '(' || c == ')' || c == ',' || c == '"' || c == '\\' || isSpace(c);
    return quote ? quoted(s, 0) : s;
}

/++
A range bound as the server writes it in range text: in double quotes (with
`"` and `\` doubled) when it is empty or contains a parenthesis, a
bracket, `,`, `"`, `\` or a space.
+/
string quoteRangeBound(string s) pure
{
    bool quote = s.length == 0;
    foreach (c; s)
        quote = quote || c == '(' || c == ')' || c == '[' || c == ']' || c == ',' || c == '"' || c == '\\'
            || isSpace(c);
    return quote ? quoted(s, 0) : s;
}

/// A key or value as `hstore` writes it: always in double quotes, `"` and `\` escaped by `\`.
string quoteHstore(string s) pure
{
    return quoted(s, '\\');
}

// s in double quotes; `"` and `\` preceded by `escape`, or doubled when escape is 0
private string quoted(string s, char escape) pure
{
    auto r = new char[](0);
    r.reserve(s.length + 2);
    r ~= '"';
    foreach (c; s)
    {
        if (c == '"' || c == '\\')
            r ~= escape ? escape : c;
        r ~= c;
    }
    r ~= '"';
    return (() @trusted => cast(string) r)(); // not referenced elsewhere
}

///
unittest
{
    assert(quoteArrayElement("a b", ',') == `"a b"` && quoteArrayElement("null", ',') == `"null"`);
    assert(quoteArrayElement(`x"y`, ',') == `"x\"y"` && quoteArrayElement("1.5", ',') == "1.5");
    assert(quoteArrayElement("(1,1),(0,0)", ';') == "(1,1),(0,0)");
    assert(quoteRecordField(`q"x`) == `"q""x"` && quoteRecordField("") == `""` && quoteRecordField("ab") == "ab");
    assert(quoteRangeBound("2020-01-01 00:00:00") == `"2020-01-01 00:00:00"` && quoteRangeBound("5") == "5");
    assert(quoteHstore(`a"b`) == `"a\"b"`);
}

/// The parts of an array's text.
struct ArrayText
{
    /// The length of each dimension (none for an empty array).
    int[] lengths;
    /// The lower bound of each dimension.
    int[] lowerBounds;
    /// The elements in row-major order; null for NULL.
    string[] elements;
}

/++
Parses array text: `{1,2,NULL}`, `{{1,2},{3,4}}`, `[0:1]={a,"b c"}`, `{}`.

Throws: `ClientException` for malformed text.
+/
ArrayText parseArrayText(string text, char delimiter = ',') pure
{
    import std.conv : ConvException, to;

    ArrayText result;
    size_t i;
    void fail()
    {
        throw new ClientException("Malformed array text '" ~ text ~ "'");
    }

    void skipSpaces()
    {
        while (i < text.length && isSpace(text[i]))
            i++;
    }

    int[] decoratedLower, decoratedUpper;
    skipSpaces();
    // dimension decoration: [l:u][l:u]=
    while (i < text.length && text[i] == '[')
    {
        i++;
        const start = i;
        while (i < text.length && text[i] != ']')
            i++;
        if (i >= text.length)
            fail();
        auto dim = text[start .. i];
        i++;
        import std.string : indexOf;

        const colon = dim.indexOf(':');
        try
        {
            if (colon < 0)
            {
                decoratedLower ~= 1;
                decoratedUpper ~= dim.to!int;
            }
            else
            {
                decoratedLower ~= dim[0 .. colon].to!int;
                decoratedUpper ~= dim[colon + 1 .. $].to!int;
            }
        }
        catch (ConvException)
            fail();
    }
    if (decoratedLower.length)
    {
        skipSpaces();
        if (i >= text.length || text[i] != '=')
            fail();
        i++;
        skipSpaces();
    }

    // nested braces: all elements at the same depth, sub-arrays of equal lengths per level
    int[] lengths;
    ptrdiff_t leafLevel = -1;
    void element(size_t level)
    {
        if (leafLevel < 0)
            leafLevel = level;
        else if (leafLevel != level)
            fail();
        string value;
        if (text[i] == '"')
        {
            i++;
            auto buf = new char[](0);
            bool closed;
            while (i < text.length)
            {
                if (text[i] == '\\' && i + 1 < text.length)
                {
                    buf ~= text[i + 1];
                    i += 2;
                }
                else if (text[i] == '"')
                {
                    i++;
                    closed = true;
                    break;
                }
                else
                    buf ~= text[i++];
            }
            if (!closed)
                fail();
            value = buf.length ? (() @trusted => cast(string) buf)() : ""; // not referenced elsewhere
        }
        else
        {
            import std.uni : sicmp;

            auto buf = new char[](0);
            while (i < text.length && text[i] != delimiter && text[i] != '}' && text[i] != '{' && text[i] != '"')
            {
                if (text[i] == '\\' && i + 1 < text.length)
                    i++;
                buf ~= text[i++];
            }
            while (buf.length && isSpace(buf[$ - 1]))
                buf = buf[0 .. $ - 1];
            if (buf.length == 0)
                fail();
            value = sicmp(buf, "NULL") == 0 ? null : (() @trusted => cast(string) buf)();
        }
        result.elements ~= value;
    }

    void group(size_t level)
    {
        i++; // '{'
        skipSpaces();
        if (i < text.length && text[i] == '}')
        {
            if (level != 0)
                fail();
            i++;
            return; // {}
        }
        int count;
        for (;;)
        {
            skipSpaces();
            if (i >= text.length)
                fail();
            if (text[i] == '{')
            {
                if (leafLevel >= 0 && leafLevel <= level)
                    fail();
                group(level + 1);
            }
            else
                element(level);
            count++;
            skipSpaces();
            if (i >= text.length)
                fail();
            if (text[i] == delimiter)
                i++;
            else if (text[i] == '}')
            {
                i++;
                break;
            }
            else
                fail();
        }
        if (lengths.length <= level)
            lengths.length = level + 1;
        if (lengths[level] == 0)
            lengths[level] = count;
        else if (lengths[level] != count)
            throw new ClientException("Multidimensional arrays must have sub-arrays of the same size");
    }

    if (i >= text.length || text[i] != '{')
        fail();
    group(0);
    skipSpaces();
    if (i != text.length)
        fail();
    if (result.elements.length == 0)
    {
        if (decoratedLower.length)
            fail();
        return result; // empty
    }
    result.lengths = lengths;
    if (decoratedLower.length)
    {
        if (decoratedLower.length != result.lengths.length)
            fail();
        foreach (d; 0 .. decoratedLower.length)
            if (decoratedUpper[d] - decoratedLower[d] + 1 != result.lengths[d])
                fail();
        result.lowerBounds = decoratedLower;
    }
    else
    {
        result.lowerBounds = new int[result.lengths.length];
        result.lowerBounds[] = 1;
    }
    size_t total = 1;
    foreach (l; result.lengths)
        total *= l;
    if (total != result.elements.length)
        fail();
    return result;
}

///
unittest
{
    import std.exception : assertThrown;

    auto a = parseArrayText(`{1,2,NULL}`);
    assert(a.lengths == [3] && a.lowerBounds == [1] && a.elements == ["1", "2", null]);
    a = parseArrayText(`{{1,2},{3,4},{5,6}}`);
    assert(a.lengths == [3, 2] && a.elements == ["1", "2", "3", "4", "5", "6"]);
    a = parseArrayText(`[0:1]={"a b","x\"y"}`);
    assert(a.lowerBounds == [0] && a.elements == ["a b", `x"y`]);
    a = parseArrayText(`{}`);
    assert(a.lengths.length == 0 && a.elements.length == 0);
    a = parseArrayText(`{"",NULL,"NULL"}`);
    assert(a.elements[0]!is null && a.elements[0].length == 0 && a.elements[1] is null && a.elements[2] == "NULL");
    a = parseArrayText(`{(1,1),(0,0);(3,3),(2,2)}`, ';');
    assert(a.elements == ["(1,1),(0,0)", "(3,3),(2,2)"]);
    a = parseArrayText(`{{{1},{2}},{{3},{4}}}`);
    assert(a.lengths == [2, 2, 1]);
    assertThrown!ClientException(parseArrayText(`{{1,2},{3}}`));
    assertThrown!ClientException(parseArrayText(`{1,{2}}`));
    assertThrown!ClientException(parseArrayText(`{"a}`));
    assertThrown!ClientException(parseArrayText(`[1:3]={1,2}`));
}

/++
Parses record text, `(1,"a b",,"")`, into its fields: null for a NULL
(nothing between the commas), the text otherwise.

Throws: `ClientException` for malformed text.
+/
string[] parseRecordText(string text) pure
{
    size_t i;
    void fail()
    {
        throw new ClientException("Malformed record text '" ~ text ~ "'");
    }

    while (i < text.length && isSpace(text[i]))
        i++;
    if (i >= text.length || text[i] != '(')
        fail();
    i++;
    string[] fields;
    for (;;)
    {
        if (i >= text.length)
            fail();
        if (text[i] == ',' || text[i] == ')')
            fields ~= null; // NULL
        else
        {
            auto buf = new char[](0);
            bool inQuotes;
            while (i < text.length && (inQuotes || (text[i] != ',' && text[i] != ')')))
            {
                const c = text[i++];
                if (c == '\\')
                {
                    if (i >= text.length)
                        fail();
                    buf ~= text[i++];
                }
                else if (c == '"')
                {
                    if (!inQuotes)
                        inQuotes = true;
                    else if (i < text.length && text[i] == '"')
                    {
                        buf ~= '"'; // a doubled quote
                        i++;
                    }
                    else
                        inQuotes = false;
                }
                else
                    buf ~= c;
            }
            fields ~= buf.length ? (() @trusted => cast(string) buf)() : ""; // quoted empty: an empty string
        }
        if (i >= text.length)
            fail();
        if (text[i++] == ')')
            break;
    }
    while (i < text.length && isSpace(text[i]))
        i++;
    if (i != text.length)
        fail();
    return fields;
}

///
unittest
{
    import std.exception : assertThrown;

    assert(parseRecordText(`(1,"a b",,"","{1,2}")`) == ["1", "a b", null, "", "{1,2}"]);
    const f = parseRecordText(`(,"")`);
    assert(f[0] is null && f[1]!is null && f[1].length == 0);
    assert(parseRecordText(`("{""a b""}","q""x")`) == [`{"a b"}`, `q"x`]);
    assert(parseRecordText(`()`) == [null]);
    assertThrown!ClientException(parseRecordText(`(1,2`));
}

/// The parts of a range's text.
struct RangeText
{
    /// Whether the range is empty (`empty`).
    bool empty;
    /// Whether the bounds are inclusive (`[`, `]`).
    bool lowerInclusive, upperInclusive;
    /// The bounds' text; null for an infinite (omitted) bound.
    string lower, upper;
}

/++
Parses range text: `empty`, or two bounds between a bracket (inclusive) or
a parenthesis (exclusive), e.g. `[1,5]` or `["2020-01-01 00:00:00",infinity]`; an
omitted bound is infinite.

Throws: `ClientException` for malformed text.
+/
RangeText parseRangeText(string text) pure
{
    import std.string : strip;
    import std.uni : sicmp;

    RangeText r;
    void fail()
    {
        throw new ClientException("Malformed range text '" ~ text ~ "'");
    }

    const s = text.strip;
    if (sicmp(s, "empty") == 0)
    {
        r.empty = true;
        return r;
    }
    if (s.length < 3 || (s[0] != '[' && s[0] != '(') || (s[$ - 1] != ']' && s[$ - 1] != ')'))
        fail();
    r.lowerInclusive = s[0] == '[';
    r.upperInclusive = s[$ - 1] == ']';
    size_t i = 1;
    string bound(char end)
    {
        if (i < s.length && (s[i] == end))
            return null; // omitted: infinite
        auto buf = new char[](0);
        bool inQuotes, any;
        while (i < s.length && (inQuotes || (s[i] != end)))
        {
            const c = s[i++];
            any = true;
            if (c == '\\')
            {
                if (i >= s.length)
                    fail();
                buf ~= s[i++];
            }
            else if (c == '"')
            {
                if (!inQuotes)
                    inQuotes = true;
                else if (i < s.length && s[i] == '"')
                {
                    buf ~= '"';
                    i++;
                }
                else
                    inQuotes = false;
            }
            else
                buf ~= c;
        }
        if (!any)
            return null;
        return buf.length ? (() @trusted => cast(string) buf)() : "";
    }

    r.lower = bound(',');
    if (i >= s.length || s[i] != ',')
        fail();
    i++;
    const last = s[$ - 1];
    r.upper = bound(last);
    if (i + 1 != s.length)
        fail();
    return r;
}

///
unittest
{
    auto r = parseRangeText(`[1,5)`);
    assert(!r.empty && r.lowerInclusive && !r.upperInclusive && r.lower == "1" && r.upper == "5");
    r = parseRangeText(`(,5]`);
    assert(r.lower is null && r.upper == "5" && r.upperInclusive);
    r = parseRangeText(`["2020-01-01 00:00:00","a""b")`);
    assert(r.lower == "2020-01-01 00:00:00" && r.upper == `a"b`);
    assert(parseRangeText("empty").empty);
    r = parseRangeText(`(,)`);
    assert(r.lower is null && r.upper is null);
}

/++
Splits multirange text, e.g. `{[1,3],[5,7]}` or `{}`, into the text of its ranges.

Throws: `ClientException` for malformed text.
+/
string[] parseMultirangeText(string text) pure
{
    import std.string : strip;

    const s = text.strip;
    if (s.length < 2 || s[0] != '{' || s[$ - 1] != '}')
        throw new ClientException("Malformed multirange text '" ~ text ~ "'");
    string[] ranges;
    // s[$ - 1] is the closing brace
    size_t i = 1;
    while (i + 1 < s.length)
    {
        while (i + 1 < s.length && (isSpace(s[i]) || s[i] == ','))
            i++;
        if (i + 1 >= s.length)
            break;
        const start = i;
        bool inQuotes;
        // to the closing bracket of this range (outside quotes), or the word "empty"
        while (i + 1 < s.length)
        {
            const c = s[i];
            if (c == '\\')
            {
                i += 2;
                continue;
            }
            if (c == '"')
                inQuotes = !inQuotes;
            i++;
            if (!inQuotes && (c == ']' || c == ')') && i > start + 1)
                break;
            if (!inQuotes && c == ',' && s[start] != '[' && s[start] != '(')
            {
                i--;
                break;
            }
        }
        ranges ~= s[start .. i].strip;
    }
    return ranges;
}

///
unittest
{
    assert(parseMultirangeText(`{[1,3),[5,7)}`) == ["[1,3)", "[5,7)"]);
    assert(parseMultirangeText(`{}`).length == 0);
    assert(parseMultirangeText(`{["a,b","c)"]}`) == [`["a,b","c)"]`]);
}

/// A key and value of an `hstore`; `value` is null for NULL.
struct HstorePair
{
    /// The key.
    string key;
    /// The value; null for NULL.
    string value;
}

/++
Parses `hstore` text: `"a"=>"1", "b"=>NULL`.

Throws: `ClientException` for malformed text.
+/
HstorePair[] parseHstoreText(string text) pure
{
    import std.uni : sicmp;

    HstorePair[] pairs;
    size_t i;
    void fail()
    {
        throw new ClientException("Malformed hstore text '" ~ text ~ "'");
    }

    void skipSpaces()
    {
        while (i < text.length && isSpace(text[i]))
            i++;
    }

    static struct Item
    {
        string text;
        bool quoted;
    }

    Item item()
    {
        skipSpaces();
        auto buf = new char[](0);
        if (i < text.length && text[i] == '"')
        {
            i++;
            for (;;)
            {
                if (i >= text.length)
                    fail();
                const c = text[i++];
                if (c == '\\' && i < text.length)
                    buf ~= text[i++];
                else if (c == '"')
                    break;
                else
                    buf ~= c;
            }
            return Item(buf.length ? (() @trusted => cast(string) buf)() : "", true);
        }
        while (i < text.length && !isSpace(text[i]) && text[i] != ',' && text[i] != '=')
        {
            if (text[i] == '\\' && i + 1 < text.length)
                i++;
            buf ~= text[i++];
        }
        if (buf.length == 0)
            fail();
        return Item((() @trusted => cast(string) buf)(), false);
    }

    skipSpaces();
    while (i < text.length)
    {
        const key = item().text;
        skipSpaces();
        if (i + 1 >= text.length || text[i .. i + 2] != "=>")
            fail();
        i += 2;
        const value = item();
        pairs ~= HstorePair(key, !value.quoted && sicmp(value.text, "NULL") == 0 ? null : value.text);
        skipSpaces();
        if (i < text.length)
        {
            if (text[i] != ',')
                fail();
            i++;
            skipSpaces();
        }
    }
    return pairs;
}

///
unittest
{
    const p = parseHstoreText(`"a"=>"1", "b c"=>NULL, "q\"x"=>""`);
    assert(p.length == 3 && p[0] == HstorePair("a", "1") && p[1].key == "b c" && p[1].value is null);
    assert(p[2].key == `q"x` && p[2].value !is null && p[2].value.length == 0);
    assert(parseHstoreText("").length == 0);
}
