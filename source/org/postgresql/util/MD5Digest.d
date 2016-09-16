/*-------------------------------------------------------------------------
*
* Copyright (c) 2003-2014, PostgreSQL Global Development Group
*
*
*-------------------------------------------------------------------------
*/

module org.postgresql.util.MD5Digest;

/**
 * MD5-based utility function to obfuscate passwords before network transmission.
 *
 * @author Jeremy Wohl
 */

//import java.security.MessageDigest;
//import java.security.NoSuchAlgorithmException;

public class MD5Digest {
  private this() {
  }

  /**
   * Encodes user/password/salt information in the following way: MD5(MD5(password + user) + salt)
   *
   * @param user The connecting user.
   * @param password The connecting user's password.
   * @param salt A four-salt sent by the server.
   * @return A 35-byte array, comprising the string "md5" and an MD5 digest.
   */
  public static byte[] encode(byte user[], byte password[], byte salt[]) {
    import std.digest.md;
    MD5 md;
    //MessageDigest md;
    //byte[] temp_digest;
    //byte[] pass_digest;
    byte[] hex_digest = new byte[35];

    //try {
      //md = MessageDigest.getInstance("MD5");

      md.put(cast(ubyte[])password);
      md.put(cast(ubyte[])user);
      auto temp_digest = md.finish();

      bytesToHex(cast(byte[])temp_digest, hex_digest, 0);
      md.put(cast(ubyte[])hex_digest[0 .. 32]);
      md.put(cast(ubyte[])salt);
      auto pass_digest = md.finish();

      bytesToHex(cast(byte[])pass_digest, hex_digest, 3);
      hex_digest[0] = cast(byte) 'm';
      hex_digest[1] = cast(byte) 'd';
      hex_digest[2] = cast(byte) '5';
    //} catch (NoSuchAlgorithmException e) {
    //  throw new IllegalStateException("Unable to encode password with MD5", e);
    //}

    return hex_digest;
  }

  /*
   * Turn 16-byte stream into a human-readable 32-byte hex string
   */
  private static void bytesToHex(byte[] bytes, byte[] hex, int offset) {
    immutable char lookup[] =
    ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'];

    int i;
    int c;
    int j;
    int pos = offset;

    for (i = 0; i < 16; i++) {
      c = bytes[i] & 0xFF;
      j = c >> 4;
      hex[pos++] = cast(byte) lookup[j];
      j = (c & 0xF);
      hex[pos++] = cast(byte) lookup[j];
    }
  }
}
