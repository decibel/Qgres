\unset ECHO
\i test/pgxntool/setup.sql

\i test/helpers/function_test.sql

SELECT plan((
  0
  -- General tests
  + ( -- _queue_type__sanitize()
    pg_temp.function_test_count('public')
    + 4 * 2 -- _queue_type__sanitize()
  )

  -- table tests
  + 5 -- _queue
  + 3 -- _sp_entry_id

  -- API functions
  + ( -- queue__create()
    pg_temp.function_test_count('public')
    + pg_temp.function_test_count('qgres__queue_maintain')
    + 2 -- \i test/helpers/queue__create.sql
    + 1 -- error test
  )
)::int);

/*
* _queue_type__sanitize()
*/
SELECT pg_temp.function_test(
  '_queue_type__sanitize'
  , 'text'
  , 'stable'
  , strict := true
  , definer := false
  , execute_roles := 'public'
);
WITH v(input, expected) AS (
  SELECT * FROM (VALUES
      ('SP'::text        , 'Serial Publisher'::queue_type)
    , ('Serial Publisher',  'Serial Publisher'::queue_type)
    , ('SR'::text        , 'Serial Remover'::queue_type)
    , ('Serial Remover',  'Serial Remover'::queue_type)
  ) v
)
-- Straight test
SELECT is(
  _queue_type__sanitize(input)
  , expected
  , format( 'Check _queue_type__sanitize(%L)', input )
) FROM v
UNION ALL
-- Test with lower(input)
SELECT is(
  _queue_type__sanitize(lower(input))
  , expected
  , format( 'Check _queue_type__sanitize(%L)', lower(input) )
) FROM v
;

/*
 * _queue table tests
 */
SELECT col_is_pk(
  '_queue'
  , 'queue_id'
);
SELECT col_is_unique(
  '_queue'
  , 'queue_name'
);
SELECT col_not_null(
  '_queue'
  , 'queue_name'
);
SELECT col_type_is(
  '_queue'
  , 'queue_name'
  , 'citext'
);
SELECT trigger_is(
  '_queue'
  , '_queue_dml'
  , '_queue_dml'
);

/*
 * _sp_entry_id
 */
SELECT col_is_pk(
  '_sp_entry_id'
  , 'queue_id'
);
SELECT col_not_null(
  '_sp_entry_id'
  , 'entry_id'
);
SELECT fk_ok(
  '_sp_entry_id'
  , 'queue_id'
  , '_queue'
  , 'queue_id'
);

/*
* queue__create()
*/
SELECT pg_temp.function_test(
  'queue__create'
  , 'citext,queue_type'
  , 'volatile'
  , strict := false
  , definer := true
  , execute_roles := 'qgres__queue_maintain'
);
SELECT pg_temp.function_test(
  'queue__create'
  , 'citext,text'
  , 'volatile'
  , strict := false
  , definer := false
  , execute_roles := 'public'
);

\i test/helpers/queue__create.sql

SELECT throws_ok(
  -- Intentionally change case of name and queue_type
  $$SELECT queue__create('test sp queue', 'sr')$$
  , '23505' -- Unique violation
  , 'queue "test sp queue" already exists'
  , 'Duplicate creation produces nice error message'
);

\i test/pgxntool/finish.sql

-- vi: expandtab ts=2 sw=2
