/*-------------------------------------------------------------------------
 *
 * Copyright (c) 2011, PostgreSQL Global Development Group
 *
 *
 *-------------------------------------------------------------------------
 */

module org.postgresql.util.ByteConverter;

/**
 * Helper methods to parse java base types from byte arrays.
 *
 * @author Mikko Tiihonen
 */
public class ByteConverter {

  private this() {
    // prevent instantiation of static helper class
  }

  /**
   * Parses a long value from the byte array.
   *
   * @param bytes The byte array to parse.
   * @param idx The starting index of the parse in the byte array.
   * @return parsed long value.
   */
  public static long int8(byte[] bytes, int idx) {
    return
        (cast(long) (bytes[idx + 0] & 255) << 56)
            + (cast(long) (bytes[idx + 1] & 255) << 48)
            + (cast(long) (bytes[idx + 2] & 255) << 40)
            + (cast(long) (bytes[idx + 3] & 255) << 32)
            + (cast(long) (bytes[idx + 4] & 255) << 24)
            + (cast(long) (bytes[idx + 5] & 255) << 16)
            + (cast(long) (bytes[idx + 6] & 255) << 8)
            + (bytes[idx + 7] & 255);
  }

  /**
   * Parses an int value from the byte array.
   *
   * @param bytes The byte array to parse.
   * @param idx The starting index of the parse in the byte array.
   * @return parsed int value.
   */
  public static int int4(byte[] bytes, int idx) {
    return
        ((bytes[idx] & 255) << 24)
            + ((bytes[idx + 1] & 255) << 16)
            + ((bytes[idx + 2] & 255) << 8)
            + ((bytes[idx + 3] & 255));
  }

  /**
   * Parses a short value from the byte array.
   *
   * @param bytes The byte array to parse.
   * @param idx The starting index of the parse in the byte array.
   * @return parsed short value.
   */
  public static short int2(byte[] bytes, int idx) {
    return cast(short) (((bytes[idx] & 255) << 8) + ((bytes[idx + 1] & 255)));
  }

  /**
   * Parses a float value from the byte array.
   *
   * @param bytes The byte array to parse.
   * @param idx The starting index of the parse in the byte array.
   * @return parsed float value.
   */
  public static float float4(byte[] bytes, int idx) {
    return /*Float.*/intBitsToFloat(int4(bytes, idx));
  }

  /**
   * Parses a double value from the byte array.
   *
   * @param bytes The byte array to parse.
   * @param idx The starting index of the parse in the byte array.
   * @return parsed double value.
   */
  public static double float8(byte[] bytes, int idx) {
    return /*Double.*/longBitsToDouble(int8(bytes, idx));
  }

  /**
   * Encodes a long value to the byte array.
   *
   * @param target The byte array to encode to.
   * @param idx The starting index in the byte array.
   * @param value The value to encode.
   */
  public static void int8(byte[] target, int idx, long value) {
    target[idx + 0] = cast(byte) (value >>> 56);
    target[idx + 1] = cast(byte) (value >>> 48);
    target[idx + 2] = cast(byte) (value >>> 40);
    target[idx + 3] = cast(byte) (value >>> 32);
    target[idx + 4] = cast(byte) (value >>> 24);
    target[idx + 5] = cast(byte) (value >>> 16);
    target[idx + 6] = cast(byte) (value >>> 8);
    target[idx + 7] = cast(byte) value;
  }

  /**
   * Encodes a int value to the byte array.
   *
   * @param target The byte array to encode to.
   * @param idx The starting index in the byte array.
   * @param value The value to encode.
   */
  public static void int4(byte[] target, int idx, int value) {
    target[idx + 0] = cast(byte) (value >>> 24);
    target[idx + 1] = cast(byte) (value >>> 16);
    target[idx + 2] = cast(byte) (value >>> 8);
    target[idx + 3] = cast(byte) value;
  }

  /**
   * Encodes a int value to the byte array.
   *
   * @param target The byte array to encode to.
   * @param idx The starting index in the byte array.
   * @param value The value to encode.
   */
  public static void int2(byte[] target, int idx, int value) {
    target[idx + 0] = cast(byte) (value >>> 8);
    target[idx + 1] = cast(byte) value;
  }

  /**
   * Encodes a int value to the byte array.
   *
   * @param target The byte array to encode to.
   * @param idx The starting index in the byte array.
   * @param value The value to encode.
   */
  public static void float4(byte[] target, int idx, float value) {
    int4(target, idx, /*Float.*/floatToRawIntBits(value));
  }

  /**
   * Encodes a int value to the byte array.
   *
   * @param target The byte array to encode to.
   * @param idx The starting index in the byte array.
   * @param value The value to encode.
   */
  public static void float8(byte[] target, int idx, double value) {
    int8(target, idx, /*Double.*/doubleToRawLongBits(value));
  }
}

union LongDouble {
    long longValue;
    double doubleValue;
}
union IntFloat {
    int intValue;
    float floatValue;
}

float intBitsToFloat(int n) {
    IntFloat a;
    a.intValue = n;
    return a.floatValue;
}

double longBitsToDouble(long n) {
    LongDouble a;
    a.longValue = n;
    return a.doubleValue;
}

int floatToRawIntBits(float f) {
    IntFloat a;
    a.floatValue = f;
    return a.intValue;
}

long doubleToRawLongBits(double f) {
    LongDouble a;
    a.doubleValue = f;
    return a.longValue;
}
