module org.postgresql.util.JdbcBlackHole;

import ddbc.core;
//import java.sql.Connection;
//import java.sql.ResultSet;
//import java.sql.SQLException;
//import java.sql.Statement;

public class JdbcBlackHole {
  public static void close(Connection con) {
    try {
      if (con !is null) {
        con.close();
      }
    } catch (SQLException e) {
      /* ignore for now */
    }
  }

  public static void close(Statement s) {
    try {
      if (s !is null) {
        s.close();
      }
    } catch (SQLException e) {
      /* ignore for now */
    }
  }

  public static void close(ResultSet rs) {
    try {
      if (rs !is null) {
        rs.close();
      }
    } catch (SQLException e) {
      /* ignore for now */
    }
  }
}
