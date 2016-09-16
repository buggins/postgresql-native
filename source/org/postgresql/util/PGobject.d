/*-------------------------------------------------------------------------
*
* Copyright (c) 2003, PostgreSQL Global Development Group
*
*
*-------------------------------------------------------------------------
*/

module org.postgresql.util.PGobject;

//import java.io.Serializable;
//import java.sql.SQLException;
import ddbc.core;

/**
 * PGobject is a class used to describe unknown types An unknown type is any type that is unknown by
 * JDBC Standards
 */
public class PGobject /*implements Serializable, Cloneable*/ {
  protected string type;
  protected string value;

  /**
   * This is called by org.postgresql.Connection.getObject() to create the object.
   */
  public this() {
  }

  /**
   * This method sets the type of this object.
   *
   * <p>
   * It should not be extended by subclasses, hence its final
   *
   * @param type a string describing the type of the object
   */
  public final void setType(string type) {
    this.type = type;
  }

  /**
   * This method sets the value of this object. It must be overidden.
   *
   * @param value a string representation of the value of the object
   * @throws SQLException thrown if value is invalid for this type
   */
  public void setValue(string value) /* throws SQLException */ {
    this.value = value;
  }

  /**
   * As this cannot change during the life of the object, it's final.
   *
   * @return the type name of this object
   */
  public final string getType() @safe nothrow {
    return type;
  }

  /**
   * This must be overidden, to return the value of the object, in the form required by
   * org.postgresql.
   *
   * @return the value of this object
   */
  public string getValue() @safe nothrow {
    return value;
  }

  /**
   * This must be overidden to allow comparisons of objects
   *
   * @param obj Object to compare with
   * @return true if the two boxes are identical
   */
  override public bool opEquals(Object obj) {
    PGobject foo = cast(PGobject)obj;
    if (foo) {
      string otherValue = foo.getValue();

      if (otherValue is null) {
        return getValue() is null;
      }
      return otherValue == getValue();
    }
    return false;
  }

  /**
   * This must be overidden to allow the object to be cloned
   */
  public Object clone() /*throws CloneNotSupportedException*/ {
    PGobject res = new PGobject;
    res.type = type;
    res.value = value;
    return res; //super.clone();
  }

  /**
   * This is defined here, so user code need not overide it.
   *
   * @return the value of this object, in the syntax expected by org.postgresql
   */
  override public string toString() {
    return getValue();
  }

  /**
   * Compute hash. As equals() use only value. Return the same hash for the same value.
   *
   * @return Value hashcode, 0 if value is null {@link java.util.Objects#hashCode(Object)}
   */
  override
  public size_t toHash() @safe nothrow {
    return getValue() !is null ? getValue().hashOf : 0;
  }
}
