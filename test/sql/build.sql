\set ECHO none

\i test/pgxntool/psql.sql

BEGIN;
CREATE EXTENSION IF NOT EXISTS citext;

SET client_min_messages = WARNING;
\i sql/qgres.sql

\echo # TRANSACTION INTENTIONALLY LEFT OPEN!

-- vi: expandtab ts=2 sw=2
