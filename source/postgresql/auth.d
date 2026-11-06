/++
Password authentication: SCRAM-SHA-256 (RFC 5802 and RFC 7677, with the
`tls-server-end-point` channel binding of RFC 5929 for SCRAM-SHA-256-PLUS),
MD5, and the SASLprep preparation of passwords (RFC 4013).

PostgreSQL ignores the user name inside SCRAM messages (the startup message
names the user), so the client sends an empty one, as libpq does.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module postgresql.auth;

import std.base64 : Base64;
import std.digest.hmac : HMAC;
import std.digest.sha : SHA256, sha256Of;

import postgresql.exception : ClientException, ProtocolException;

@safe:

/// The SASL mechanism names.
enum scramSha256 = "SCRAM-SHA-256";
/// ditto
enum scramSha256Plus = "SCRAM-SHA-256-PLUS";

/// The most PBKDF2 iterations accepted from a server (PostgreSQL's default is 4096).
enum uint maxScramIterations = 1 << 24;

/++
The response to an MD5 password request:
`"md5" ~ hex(md5(hex(md5(password ~ user)) ~ salt))`.
+/
string md5PasswordResponse(const(char)[] user, const(char)[] password, const(ubyte)[] salt)
{
    import std.digest : LetterCase, toHexString;
    import std.digest.md : md5Of;

    const inner = toHexString!(LetterCase.lower)(md5Of(password, user));
    return "md5" ~ toHexString!(LetterCase.lower)(md5Of(inner[], salt)).idup;
}

///
unittest
{
    // Python: "md5" + md5(md5(b"secret" + b"postgres").hexdigest().encode() + bytes([1, 2, 3, 4])).hexdigest()
    assert(md5PasswordResponse("postgres", "secret", [1, 2, 3, 4]) == "md5bb41a296aab6baccb36ff243a562abff");
}

/++
The client side of a SCRAM-SHA-256 exchange.

1. `clientFirstMessage` goes in the SASLInitialResponse;
2. `clientFinalMessage(serverFirst)` answers the SASLContinue;
3. `verifyServerFinal(serverFinal)` checks the SASLFinal: the server proves it
   knows the password too.
+/
struct ScramClient
{
    private const(ubyte)[] password;
    private string nonce;
    private string gs2Header;
    private const(ubyte)[] channelBinding;
    private string clientFirstBare;
    private ubyte[32] expectedServerSignature;
    private bool finalSent;

    /++
    Starts an exchange.

    Params:
        password = the password; prepared with SASLprep (`saslPrep`).
        mechanism = `scramSha256` or `scramSha256Plus`.
        channelBinding = for `scramSha256Plus`: the `tls-server-end-point` data
            (the hash of the server certificate, see `tlsServerEndPoint`).
        clientSupportsBinding = for `scramSha256` over TLS when the server
            didn't offer the -PLUS mechanism: tells the server that the client
            could have used channel binding (`y` flag), which lets it detect a
            downgrade.
        nonce = the client nonce; random when null (tests pass a fixed one).
    +/
    this(const(char)[] password, string mechanism, const(ubyte)[] channelBinding = null,
            bool clientSupportsBinding = false, string nonce = null)
    {
        import dbwire.crypto.random : randomBytes;

        this.password = saslPrep(password);
        if (mechanism == scramSha256Plus)
        {
            if (channelBinding.length == 0)
                throw new ClientException("SCRAM-SHA-256-PLUS needs the channel binding data");
            gs2Header = "p=tls-server-end-point,,";
            this.channelBinding = channelBinding.dup;
        }
        else if (mechanism == scramSha256)
            gs2Header = clientSupportsBinding ? "y,," : "n,,";
        else
            throw new ClientException("Unsupported SASL mechanism " ~ mechanism);
        this.nonce = nonce.length ? nonce : Base64.encode(randomBytes(18)).idup;
        clientFirstBare = "n=,r=" ~ this.nonce;
    }

    /// The client-first-message (sent in the SASLInitialResponse).
    string clientFirstMessage() const pure nothrow
    {
        return gs2Header ~ clientFirstBare;
    }

    /++
    Answers the server-first-message with the client-final-message.

    Throws: `ProtocolException` if the server's message is malformed, its
    nonce doesn't extend the client's, or it asks for too many iterations.
    +/
    string clientFinalMessage(const(char)[] serverFirst)
    {
        import dbwire.crypto.pbkdf2 : pbkdf2;
        import std.algorithm.searching : startsWith;
        import std.conv : ConvException, to;

        string serverNonce, salt;
        uint iterations;
        foreach (attribute; splitAttributes(serverFirst))
        {
            if (attribute.startsWith("r="))
                serverNonce = attribute[2 .. $].idup;
            else if (attribute.startsWith("s="))
                salt = attribute[2 .. $].idup;
            else if (attribute.startsWith("i="))
            {
                try
                    iterations = attribute[2 .. $].to!uint;
                catch (ConvException)
                    throw new ProtocolException("SCRAM: invalid iteration count");
            }
            else if (attribute.startsWith("m="))
                throw new ProtocolException("SCRAM: the server requires an unsupported extension");
        }
        if (serverNonce.length <= nonce.length || !serverNonce.startsWith(nonce))
            throw new ProtocolException("SCRAM: the server's nonce doesn't extend the client's");
        if (salt.length == 0 || iterations == 0)
            throw new ProtocolException("SCRAM: the server sent no salt or iteration count");
        if (iterations > maxScramIterations)
            throw new ProtocolException("SCRAM: the server asks for too many iterations");
        ubyte[] saltBytes;
        try
            saltBytes = Base64.decode(salt);
        catch (Exception)
            throw new ProtocolException("SCRAM: the salt is not valid base64");

        auto saltedPassword = pbkdf2!SHA256(password, saltBytes, iterations, 32);
        scope (exit)
            saltedPassword[] = 0;
        auto clientKey = hmacSha256(saltedPassword, cast(const(ubyte)[]) "Client Key");
        const storedKey = sha256Of(clientKey[]);

        const cbind = Base64.encode(cast(const(ubyte)[]) gs2Header ~ channelBinding);
        const withoutProof = "c=" ~ cbind ~ ",r=" ~ serverNonce;
        const authMessage = clientFirstBare ~ "," ~ serverFirst ~ "," ~ withoutProof;

        const clientSignature = hmacSha256(storedKey[], cast(const(ubyte)[]) authMessage);
        ubyte[32] proof = clientKey;
        proof[] ^= clientSignature[];
        clientKey[] = 0;
        const serverKey = hmacSha256(saltedPassword, cast(const(ubyte)[]) "Server Key");
        expectedServerSignature = hmacSha256(serverKey[], cast(const(ubyte)[]) authMessage);
        finalSent = true;
        return (withoutProof ~ ",p=" ~ Base64.encode(proof[])).idup;
    }

    /++
    Checks the server-final-message: the server's signature must match.

    Throws: `ClientException` if the server reports an error (`e=...`);
    `ProtocolException` if the signature is missing or wrong (the server
    doesn't know the password: possibly an impostor).
    +/
    void verifyServerFinal(const(char)[] serverFinal) const
    {
        import std.algorithm.searching : startsWith;

        if (!finalSent)
            throw new ProtocolException("SCRAM: final message before the challenge");
        foreach (attribute; splitAttributes(serverFinal))
        {
            if (attribute.startsWith("e="))
                throw new ClientException("SCRAM authentication failed: " ~ attribute[2 .. $].idup);
            if (attribute.startsWith("v="))
            {
                ubyte[] signature;
                try
                    signature = Base64.decode(attribute[2 .. $]);
                catch (Exception)
                    throw new ProtocolException("SCRAM: the server signature is not valid base64");
                if (!constantTimeEqual(signature, expectedServerSignature[]))
                    throw new ProtocolException("SCRAM: the server's signature is wrong");
                return;
            }
        }
        throw new ProtocolException("SCRAM: the server sent no signature");
    }
}

// RFC 7677, section 3 (user "user", password "pencil"). PostgreSQL clients send
// an empty user name, so the vector is checked with the RFC's client-first-bare.
unittest
{
    import std.exception : assertThrown;

    auto scram = ScramClient("pencil", scramSha256, null, false, "rOprNGfwEbeRWgbNEkqO");
    scram.clientFirstBare = "n=user,r=rOprNGfwEbeRWgbNEkqO";
    enum serverFirst = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096";
    assert(scram.clientFinalMessage(serverFirst) == "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,"
            ~ "p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=");
    scram.verifyServerFinal("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=");
    assertThrown!ProtocolException(scram.verifyServerFinal("v=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="));
    assertThrown!ClientException(scram.verifyServerFinal("e=invalid-proof"));

    auto other = ScramClient("pencil", scramSha256, null, false, "abc");
    assert(other.clientFirstMessage() == "n,,n=,r=abc");
    assertThrown!ProtocolException(other.clientFinalMessage("r=xyz123,s=AAAA,i=4096")); // nonce not extended
    assertThrown!ProtocolException(other.clientFinalMessage("r=abc,s=AAAA,i=4096")); // not longer
    assertThrown!ProtocolException(other.clientFinalMessage("r=abcd,s=AAAA,i=0"));
    assertThrown!ProtocolException(other.clientFinalMessage("r=abcd,s=AAAA,i=99999999"));
    assertThrown!ProtocolException(other.clientFinalMessage("m=ext,r=abcd,s=AAAA,i=4096"));

    assert(ScramClient("x", scramSha256, null, true, "n").clientFirstMessage() == "y,,n=,r=n");
    auto plus = ScramClient("x", scramSha256Plus, [1, 2, 3], false, "n");
    assert(plus.clientFirstMessage() == "p=tls-server-end-point,,n=,r=n");
    // c= carries the GS2 header followed by the binding data
    assert(plus.clientFinalMessage("r=n1,s=AAAA,i=1")[0 .. 38] == "c=cD10bHMtc2VydmVyLWVuZC1wb2ludCwsAQID");
    assertThrown!ClientException(ScramClient("x", scramSha256Plus));
}

/++
The `tls-server-end-point` channel binding data (RFC 5929) for a server
certificate in DER form: its hash with the certificate's signature hash
algorithm, SHA-256 when that is MD5 or SHA-1.

Throws: `ClientException` if the certificate's signature algorithm has no
single hash (e.g. Ed25519 or RSASSA-PSS), so channel binding isn't defined;
`ProtocolException` if the certificate is malformed.
+/
ubyte[] tlsServerEndPoint(const(ubyte)[] certificateDer)
{
    import std.digest.sha : sha384Of, sha512Of;

    final switch (signatureHash(certificateDer))
    {
    case SignatureHash.sha256:
        return sha256Of(certificateDer)[].dup;
    case SignatureHash.sha384:
        return sha384Of(certificateDer)[].dup;
    case SignatureHash.sha512:
        return sha512Of(certificateDer)[].dup;
    case SignatureHash.none:
        throw new ClientException("Channel binding is not defined for the server certificate's signature algorithm");
    }
}

/++
Prepares a password with SASLprep (RFC 4013), as PostgreSQL does for SCRAM:
non-ASCII spaces become spaces, "commonly mapped to nothing" characters are
dropped, the text is normalized to NFKC, and prohibited characters or
inconsistent bidirectional text make the original bytes be used unchanged
(PostgreSQL does the same when it stores the password). ASCII passwords
without control characters are returned as they are.
+/
const(ubyte)[] saslPrep(const(char)[] password)
{
    import std.uni : NFKC, normalize;
    import std.utf : byDchar, UTFException;

    bool ascii = true;
    foreach (char c; password)
        if (c >= 0x80 || c < 0x20 || c == 0x7F)
            ascii = false;
    if (ascii)
        return cast(const(ubyte)[]) password;

    dchar[] mapped;
    try
    {
        foreach (dchar c; password.byDchar)
        {
            if (c == dchar.init)
                return cast(const(ubyte)[]) password; // invalid UTF-8
            if (mapsToNothing(c))
                continue;
            mapped ~= isNonAsciiSpace(c) ? ' ' : c;
        }
    }
    catch (UTFException)
        return cast(const(ubyte)[]) password;
    const normalized = normalize!NFKC(mapped.idup);
    bool randAl, letter;
    foreach (c; normalized)
    {
        if (isProhibited(c))
            return cast(const(ubyte)[]) password;
        if (isRandAl(c))
            randAl = true;
        else if (isLetter(c))
            letter = true;
    }
    if (randAl && (letter || !isRandAl(normalized[0]) || !isRandAl(normalized[$ - 1])))
        return cast(const(ubyte)[]) password;
    if (normalized.length == 0)
        return cast(const(ubyte)[]) password;
    import std.conv : to;

    return cast(const(ubyte)[]) normalized.to!string;
}

///
unittest
{
    assert(saslPrep("pencil") == cast(const(ubyte)[]) "pencil");
    assert(saslPrep("I­X") == cast(const(ubyte)[]) "IX"); // soft hyphen mapped to nothing
    assert(saslPrep("a b") == cast(const(ubyte)[]) "a b"); // non-ASCII space
    assert(saslPrep("Ⅸ") == cast(const(ubyte)[]) "IX"); // NFKC: roman numeral nine
    assert(saslPrep("ª") == cast(const(ubyte)[]) "a");
    assert(saslPrep("a\x07b") == cast(const(ubyte)[]) "a\x07b"); // prohibited: used unchanged
    assert(saslPrep("пароль") == cast(const(ubyte)[]) "пароль");
    assert(saslPrep("אaא") == cast(const(ubyte)[]) "אaא"); // mixed bidi: unchanged
}

private:

ubyte[32] hmacSha256(scope const(ubyte)[] key, scope const(ubyte)[] data)
{
    auto mac = HMAC!SHA256(key);
    mac.put(data);
    return mac.finish();
}

bool constantTimeEqual(const(ubyte)[] a, const(ubyte)[] b) pure nothrow
{
    if (a.length != b.length)
        return false;
    ubyte diff;
    foreach (i; 0 .. a.length)
        diff |= a[i] ^ b[i];
    return diff == 0;
}

const(char)[][] splitAttributes(const(char)[] message) pure
{
    import std.array : split;

    return message.split(",");
}

enum SignatureHash
{
    none,
    sha256,
    sha384,
    sha512,
}

// Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm AlgorithmIdentifier, signature }
SignatureHash signatureHash(const(ubyte)[] der)
{
    auto certificate = Der(der).read(0x30);
    auto fields = Der(certificate);
    fields.read(0x30); // tbsCertificate
    auto algorithm = Der(fields.read(0x30));
    const oid = algorithm.read(0x06);
    // 1.2.840.113549.1.1.{4 md5, 5 sha1, 11 sha256, 12 sha384, 13 sha512} (RSA)
    static immutable ubyte[] rsaPrefix = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01];
    // 1.2.840.10045.4.1 (ECDSA SHA-1), 1.2.840.10045.4.3.{2, 3, 4} (ECDSA SHA-256/384/512)
    static immutable ubyte[] ecdsaSha1 = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x01];
    static immutable ubyte[] ecdsaPrefix = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03];
    // 1.3.14.3.2.29 (RSA SHA-1, old OIW) and 1.2.840.10040.4.3 (DSA SHA-1); 2.16.840.1.101.3.4.3.2 (DSA SHA-256)
    static immutable ubyte[] oiwRsaSha1 = [0x2B, 0x0E, 0x03, 0x02, 0x1D];
    static immutable ubyte[] dsaSha1 = [0x2A, 0x86, 0x48, 0xCE, 0x38, 0x04, 0x03];
    static immutable ubyte[] dsaSha256 = [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x03, 0x02];
    if (oid.length == rsaPrefix.length + 1 && oid[0 .. $ - 1] == rsaPrefix)
    {
        switch (oid[$ - 1])
        {
        case 4, 5, 11:
            return SignatureHash.sha256;
        case 12:
            return SignatureHash.sha384;
        case 13:
            return SignatureHash.sha512;
        default:
            return SignatureHash.none; // e.g. 10: RSASSA-PSS (hash in the parameters)
        }
    }
    if (oid == ecdsaSha1 || oid == oiwRsaSha1 || oid == dsaSha1 || oid == dsaSha256)
        return SignatureHash.sha256;
    if (oid.length == ecdsaPrefix.length + 1 && oid[0 .. $ - 1] == ecdsaPrefix)
    {
        switch (oid[$ - 1])
        {
        case 2:
            return SignatureHash.sha256;
        case 3:
            return SignatureHash.sha384;
        case 4:
            return SignatureHash.sha512;
        default:
            return SignatureHash.none;
        }
    }
    return SignatureHash.none; // Ed25519, Ed448, ...
}

// Reads DER elements one after another, with every length checked.
struct Der
{
    const(ubyte)[] data;

    const(ubyte)[] read(ubyte tag)
    {
        if (data.length < 2 || data[0] != tag)
            throw new ProtocolException("Malformed server certificate");
        size_t length = data[1];
        size_t pos = 2;
        if (length & 0x80)
        {
            const n = length & 0x7F;
            if (n < 1 || n > 4 || data.length < 2 + n)
                throw new ProtocolException("Malformed server certificate");
            length = 0;
            foreach (i; 0 .. n)
                length = (length << 8) | data[2 + i];
            pos = 2 + n;
        }
        if (data.length - pos < length)
            throw new ProtocolException("Malformed server certificate");
        auto content = data[pos .. pos + length];
        data = data[pos + length .. $];
        return content;
    }
}

// RFC 3454 table B.1
bool mapsToNothing(dchar c) pure nothrow
{
    return c == 0x00AD || c == 0x034F || c == 0x1806 || (c >= 0x180B && c <= 0x180D)
        || (c >= 0x200B && c <= 0x200D) || c == 0x2060 || (c >= 0xFE00 && c <= 0xFE0F) || c == 0xFEFF;
}

// RFC 3454 table C.1.2
bool isNonAsciiSpace(dchar c) pure nothrow
{
    return c == 0x00A0 || c == 0x1680 || (c >= 0x2000 && c <= 0x200B) || c == 0x202F || c == 0x205F || c == 0x3000;
}

// RFC 3454 tables C.1.2 to C.9 (prohibited output of SASLprep)
bool isProhibited(dchar c) pure nothrow
{
    if (isNonAsciiSpace(c))
        return true;
    if (c < 0x20 || c == 0x7F || (c >= 0x80 && c <= 0x9F)) // C.2.1, C.2.2
        return true;
    if (c == 0x06DD || c == 0x070F || c == 0x180E || c == 0x200C || c == 0x200D || c == 0x2028 || c == 0x2029
            || (c >= 0x2060 && c <= 0x2063) || (c >= 0x206A && c <= 0x206F) || c == 0xFEFF
            || (c >= 0xFFF9 && c <= 0xFFFC) || (c >= 0x1D173 && c <= 0x1D17A))
        return true; // C.2.2
    if ((c >= 0xE000 && c <= 0xF8FF) || (c >= 0xF0000 && c <= 0xFFFFD) || (c >= 0x100000 && c <= 0x10FFFD))
        return true; // C.3 private use
    if ((c >= 0xFDD0 && c <= 0xFDEF) || (c & 0xFFFE) == 0xFFFE)
        return true; // C.4 non-characters
    if (c >= 0xD800 && c <= 0xDFFF)
        return true; // C.5 surrogates
    if (c >= 0xFFF9 && c <= 0xFFFD)
        return true; // C.6
    if (c >= 0x2FF0 && c <= 0x2FFB)
        return true; // C.7
    if (c == 0x0340 || c == 0x0341 || c == 0x200E || c == 0x200F || (c >= 0x202A && c <= 0x202E))
        return true; // C.8
    if (c == 0xE0001 || (c >= 0xE0020 && c <= 0xE007F))
        return true; // C.9
    return false;
}

// Right-to-left letters (RFC 3454 table D.1, by block: Hebrew, Arabic, Syriac, Thaana, NKo and the RTL presentation forms).
bool isRandAl(dchar c) pure nothrow
{
    import std.uni : isAlpha;

    return ((c >= 0x05BE && c <= 0x07FF) || (c >= 0xFB1D && c <= 0xFDFF) || (c >= 0xFE70 && c <= 0xFEFC))
        && (isAlpha(c) || c == 0x05BE || c == 0x05C0 || c == 0x05C3);
}

// Left-to-right letters (RFC 3454 table D.2), approximated by the letters that are not right-to-left.
bool isLetter(dchar c) pure nothrow
{
    import std.uni : isAlpha;

    return isAlpha(c) && !isRandAl(c);
}
