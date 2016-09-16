/*-------------------------------------------------------------------------
*
* Copyright (c) 2012, PostgreSQL Global Development Group
*
*
*-------------------------------------------------------------------------
*/

module org.postgresql.util.HostSpec;

/**
 * Simple container for host and port.
 */
public class HostSpec {
  protected immutable string host;
  protected immutable int port;

  public this(string host, int port) {
    this.host = host;
    this.port = port;
  }

  public string getHost() {
    return host;
  }

  public int getPort() {
    return port;
  }

  override
  public string toString() {
    import std.conv : to;
    return host ~ ":" ~ to!string(port);
  }

  override
  public bool opEquals(Object obj) {
    auto foo = cast(HostSpec)obj;
    return foo && port == foo.port
        && host == foo.host;
  }

  override
  public size_t toHash() {
    return port ^ host.hashOf;
  }
}
