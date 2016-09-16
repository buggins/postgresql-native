/*-------------------------------------------------------------------------
*
* Copyright (c) 2015, PostgreSQL Global Development Group
*
*
*-------------------------------------------------------------------------
*/

module org.postgresql.util.CanEstimateSize;

public interface CanEstimateSize {
  long getSize();
}
