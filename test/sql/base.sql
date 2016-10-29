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
  + 6 -- _queue
  + 4 -- _sp_entry_id

  -- view tests
  + 2

  -- API functions
  + ( -- queue__create()
    pg_temp.function_test_count('qgres__queue_manage')
    + pg_temp.function_test_count('public')
    + 2 -- \i test/helpers/queue__create.sql
    + 1 -- error test
  )

  + ( -- queue__get*()
    1 -- sanity check
    + 3 * pg_temp.function_test_count('public')
    + 3 * 2 -- 3 tests * 2 queues
  )

  + ( -- queue__drop()
    pg_temp.function_test_count('qgres__queue_manage')
    + pg_temp.function_test_count('public')
    + 1 -- non-existent queue
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
SELECT is(
  (SELECT relacl FROM pg_class WHERE oid = '_queue'::regclass)
  , NULL
  , 'table "_queue" should not have any permissions defined'
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
SELECT is(
  (SELECT relacl FROM pg_class WHERE oid = '_sp_entry_id'::regclass)
  , NULL
  , 'table "_sp_entry_id" should not have any permissions defined'
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
  , execute_roles := 'qgres__queue_manage,' || current_user
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

/*
 * VIEW queue
 */
SELECT bag_eq(
  $$SELECT * FROM _queue$$
  , $$SELECT * FROM queue$$
  , 'Verify contents of view "queue"'
);
SELECT table_privs_are(
  'queue'
  , 'public'
  , array['SELECT']
);

/*
 * queue__get*
 */
SELECT is(
  (SELECT count(*) FROM _queue)
  , 2::bigint
  , 'Expected number of base queue entries'
);
SELECT pg_temp.function_test(
  'queue__get'
  , ftype
  , 'stable'
  , strict := false
  , definer := false
  , execute_roles := 'public'
)
  FROM unnest(array['citext', 'int']) u(ftype)
;
SELECT pg_temp.function_test(
  'queue__get_id'
  , 'citext'
  , 'stable'
  , strict := false
  , definer := false
  , execute_roles := 'public'
);
-- Don't assume that if the name version works the id version does!
SELECT is(
      queue__get(queue_id)
      , row(q.*)::queue
      , 'queue__get(queue_id)'
    )
  FROM queue q
;
SELECT is(
      queue__get(queue_name)
      , row(q.*)::queue
      , 'queue__get(queue_name)'
    )
  FROM queue q
;
SELECT is(
      queue__get_id(queue_name)
      , queue_id
      , 'queue__get_id(queue_name)'
    )
  FROM queue
;

/*
 * queue__drop()
 */
SELECT pg_temp.function_test(
  'queue__drop'
  , 'int,boolean'
  , 'volatile'
  , strict := false
  , definer := true
  , execute_roles := 'qgres__queue_manage,' || current_user
);
SELECT pg_temp.function_test(
  'queue__drop'
  , 'citext,boolean'
  , 'volatile'
  , strict := false
  , definer := false
  , execute_roles := 'public'
);
SELECT throws_ok(
  $$SELECT queue__drop(-999999)$$
  , 'P0002'
  , 'queue_id -999999 does not exist'
  , 'Dropping non-existent queue throws an error'
);
SELECT throws_ok(
  $$SELECT queue__drop('queue that should not exist')$$
  , 'P0002'
  , 'queue "queue that should not exist" does not exist'
  , 'Dropping non-existent queue throws an error'
);
-- TODO empty queue (force true and false)
-- TODO non-empty queue (force true and false)

\i test/pgxntool/finish.sql

-- vi: expandtab ts=2 sw=2
