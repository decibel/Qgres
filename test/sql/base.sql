\unset ECHO
\i test/pgxntool/setup.sql

\i test/helpers/function_test.sql

SELECT plan((
  0
  -- General tests
  + ( -- queue_type
    pg_temp.function_test_count('public')
    + 2
  )

  + ( -- _queue_type__sanitize()
    pg_temp.function_test_count('public')
    + 4 * 2 -- _queue_type__sanitize()
  )

  -- table tests
  + 7 -- _queue
  + 6 -- _sp_next_sequence_number
  + 4 -- _sp_consumer
  + 5 -- _sp_entry
  + pg_temp.function_test_count('') -- _sp_trim()

  -- view tests (Note this runs after queue__create())
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
  ) -- +19 = 76

  + ( -- consumer__register
    pg_temp.function_test_count('qgres__queue_delete')
    + 2 -- 2 good consumers
    + 3 -- 3 exceptions
  ) -- +9 = 85

  + ( -- consumer__drop
    pg_temp.function_test_count('qgres__queue_delete')
    + 1 -- drop
    + 2 -- exceptions
  ) -- +7 = 92

  + ( -- Publish
    pg_temp.function_test_count('qgres__queue_insert')
    + 2 * 4 * pg_temp.function_test_count('qgres__queue_insert')
      -- +36 = 128
    + 3 -- exceptions
    + 2 -- consumer registration (spread across test)
    + 4 -- test NULLs
    + 4 -- test not NULL
  ) -- +13 = 141

  + ( -- consume
    2 * pg_temp.function_test_count('qgres__queue_delete')
    + 4 -- exceptions
    + 3 -- sanity checks
    + 1 -- test NULLs
    + 1 -- entry count
    + 2 -- test not NULL
    + 1 -- entry count
    + 3 -- test empty queue
    + 1 -- Publish more
    + 3 -- verify consume and queue still has entries
    + 2 -- Drop consumer; verify
  ) -- +29 = 170

  + ( -- add
    pg_temp.function_test_count('qgres__queue_insert')
    + 2 * 4 * pg_temp.function_test_count('qgres__queue_insert')
      -- +36 = 206
    + 3 -- exceptions
    + 4 -- test NULLs
    + 4 -- test not NULL
  ) -- +11 = 217

  + ( -- Remove
     2 * pg_temp.function_test_count('qgres__queue_delete')
    + 2 -- exceptions
    + 2 -- sanity check, temp table
    + 3 -- remove 2 entries, verify
    + 3 -- remove remaining, verify
  ) -- +18 = 235

  + ( -- queue__drop()
    pg_temp.function_test_count('qgres__queue_manage')
    + pg_temp.function_test_count('public')
    + 2 -- non-existent queue
  ) -- +10 = 245
)::int);

/*
 * queue_entry
 */
SELECT pg_temp.function_test(
  'queue_entry'
  , 'bytea,jsonb,text'
  , 'immutable'
  , strict := false
  , definer := false
  , execute_roles := 'public'
);
SELECT is(
  queue_entry(bytea := '0xdeadbeef', jsonb := '{"key": "jsonb"}', text := 'text')
  , row('0xdeadbeef'::bytea, '{"key": "jsonb"}'::jsonb, 'text'::text)::queue_entry
  , 'sanity check queue_entry() with named parameters'
);
SELECT is(
  queue_entry()
  , row(NULL,NULL,NULL)::queue_entry
  , 'sanity check queue_entry() with no parameters'
);

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
 * TABLES
 */
-- _queue table tests
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
SELECT trigger_is(
  '_queue'
  , 'update'
  , '_tg_not_allowed'
);
SELECT is(
  (SELECT relacl FROM pg_class WHERE oid = '_queue'::regclass)
  , NULL
  , 'table "_queue" should not have any permissions defined'
);

-- _sp_next_sequence_number
SELECT col_is_pk(
  '_sp_next_sequence_number'
  , 'queue_id'
);
SELECT col_not_null(
  '_sp_next_sequence_number'
  , 'next_sequence_number'
);
SELECT fk_ok(
  '_sp_next_sequence_number'
  , 'queue_id'
  , '_queue'
  , 'queue_id'
);
SELECT trigger_is(
  '_sp_next_sequence_number'
  , 'verify_sp_queue__insert'
  , '_tg_sp_next_sequence_number__verify_sp_queue'
);
SELECT trigger_is(
  '_sp_next_sequence_number'
  , 'update_queue_id'
  , '_tg_not_allowed'
);
SELECT is(
  (SELECT relacl FROM pg_class WHERE oid = '_sp_next_sequence_number'::regclass)
  , NULL
  , 'table "_sp_next_sequence_number" should not have any permissions defined'
);

-- _sp_consumer
SELECT col_is_pk(
  '_sp_consumer'
  , array['queue_id', 'consumer_name']
);
SELECT fk_ok(
  '_sp_consumer'
  , 'queue_id'
  , '_sp_next_sequence_number'
  , 'queue_id'
);
SELECT trigger_is(
  '_sp_consumer'
  , 'update'
  , '_tg_not_allowed'
);
SELECT is(
  (SELECT relacl FROM pg_class WHERE oid = '_sp_consumer'::regclass)
  , NULL
  , 'table "_sp_consumer" should not have any permissions defined'
);

-- _sp_entry
SELECT col_is_pk(
  '_sp_entry'
  , array['queue_id', 'sequence_number']
);
SELECT fk_ok(
  '_sp_entry'
  , 'queue_id'
  , '_sp_next_sequence_number'
  , 'queue_id'
);
SELECT trigger_is(
  '_sp_entry'
  , 'insert'
  , '_tg_sp_entry__sequence_number'
);
SELECT trigger_is(
  '_sp_entry'
  , 'update'
  , '_tg_not_allowed'
);
SELECT is(
  (SELECT relacl FROM pg_class WHERE oid = '_sp_entry'::regclass)
  , NULL
  , 'table "_sp_entry" should not have any permissions defined'
);
SELECT pg_temp.function_test(
  '_sp_trim'
  , 'int'
  , 'volatile'
  , strict := false
  , definer := false
  , execute_roles := current_user
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
 * consumer__register()
 */
SELECT pg_temp.function_test(
  'consumer__register'
  , 'citext,citext'
  , 'volatile'
  , strict := false
  , definer := true
  , execute_roles := 'qgres__queue_delete,' || current_user
);
SELECT lives_ok(
  $$SELECT consumer__register('test SP queue', 'test consumer')$$
  , 'Register 1st test consumer'
);
SELECT lives_ok(
  $$SELECT consumer__register('test SP queue', 'test consumer 2')$$
  , 'Register 2nd test consumer'
);
SELECT throws_ok(
  $$SELECT consumer__register('test SP queue', 'test consumer')$$
  , '23505'
  , 'consumer "test consumer" on queue "test SP queue" already exists'
  , 'registering duplicate consumer should error'
);
SELECT throws_ok(
  $$SELECT consumer__register('queue that should not exist', 'test consumer')$$
  , 'P0002'
  , 'queue "queue that should not exist" does not exist'
  , 'registering consumer on non-existent queue should error'
);
SELECT throws_ok(
  $$SELECT consumer__register('test SR queue', 'test consumer')$$
  , '22023'
  , 'consumers may only be registered on "Serial Publisher" queues'
  , 'registering consumer on SR queue should error'
);

/*
 * consumer__drop()
 */
SELECT pg_temp.function_test(
  'consumer__drop'
  , 'citext,citext'
  , 'volatile'
  , strict := false
  , definer := true
  , execute_roles := 'qgres__queue_delete,' || current_user
);
SELECT lives_ok(
  $$SELECT consumer__drop('test SP queue', 'test consumer 2')$$
  , 'Drop test consumer 2'
);
SELECT throws_ok(
  $$SELECT consumer__drop('queue that should not exist', 'test consumer 2')$$
  , 'P0002'
  , 'queue "queue that should not exist" does not exist'
  , 'dropping consumer on non-existent queue should error'
);
SELECT throws_ok(
  $$SELECT consumer__drop('test SR queue', 'test consumer')$$
  , '22023'
  , 'consumers may only be dropped on "Serial Publisher" queues'
  , 'dropping consumer on SR queue should error'
);

/*
 * Publish()
 */
-- The main publish function
SELECT pg_temp.function_test(
  '_Publish'
  , 'int,queue_entry'
  , 'volatile'
  , strict := false
  , definer := true
  , execute_roles := 'qgres__queue_insert,' || current_user
);

/*
 * We need to test a 2x4 matrix of (queue_name|queue_id) and the various data
 * options.
 */
SELECT pg_temp.function_test(
      'Publish'
      , queue_arg || ',' || data_args
      , 'volatile'
      , strict := false
      , definer := false
      , execute_roles := 'public'
    )
  FROM (VALUES ('int'),('citext')) q(queue_arg)
    , (VALUES
      ('bytea,jsonb,text')
      , ('bytea')
      , ('jsonb')
      , ('text')
    ) d(data_args)
;
SELECT throws_ok(
  $$SELECT "_Publish"(-999999, queue_entry() )$$
  , 'P0002'
  , 'queue_id -999999 does not exist'
  , '_Publish with non-existent queue_id throws error'
);
SELECT throws_ok(
  $$SELECT "Publish"(-999999, NULL::text )$$
  , 'P0002'
  , 'queue_id -999999 does not exist'
  , 'Publish with non-existent queue_id throws error'
);
SELECT throws_ok(
  $$SELECT "Publish"('queue that should not exist', NULL::text )$$
  , 'P0002'
  , 'queue "queue that should not exist" does not exist'
  , 'Publishing to "queue that should not exist" throws error'
);
-- TEST NULLS
SELECT lives_ok(
  $$SELECT "Publish"('test SP queue', NULL, NULL, NULL)$$
  , $$SELECT "Publish"('test SP queue', NULL, NULL, NULL)$$
);
-- Test the 3 single arg versions
SELECT lives_ok(
      format(
        $$SELECT "Publish"('test SP queue', NULL::%I)$$
        , arg_type
      )
      , format(
        $$SELECT "Publish"('test SP queue', NULL::%I)$$
        , arg_type
      )
    )
  FROM unnest('{bytea,jsonb,text}'::regtype[]) u(arg_type)
;
SELECT lives_ok(
  $$SELECT consumer__register('test SP queue', 'post-NULLs')$$
  , $$Register consumer 'post-NULLs'$$
);
SELECT lives_ok(
  $$SELECT "Publish"('test SP queue', '0xdeadbeef', '{"key":"jsonb"}'::jsonb, 'text')$$
  , $$SELECT "Publish"('test SP queue', '0xdeadbeef', '{"key":"jsonb"}'::jsonb, 'text')$$
);
SELECT lives_ok(
      format(
        $$SELECT "Publish"('test SP queue', %L::%I)$$
        , value, datatype
      )
      , format(
        $$SELECT "Publish"('test SP queue', %L::%I)$$
        , value, datatype
      )
    )
  FROM (VALUES
    ('0xdeadbeef'::text, 'bytea'::regtype)
    , ('{"key":"jsonb"}', 'jsonb')
    , ('text', 'text')
  ) v(value, datatype)
;
SELECT lives_ok(
  $$SELECT consumer__register('test SP queue', 'empty')$$
  , $$Register consumer 'empty'$$
);

/*
 * consume()
 */
SELECT pg_temp.function_test(
  'consume'
  , 'int,citext,int'
  , 'volatile'
  , strict := false
  , definer := true
  , execute_roles := 'qgres__queue_delete,' || current_user
);
SELECT pg_temp.function_test(
  'consume'
  , 'citext,citext,int'
  , 'volatile'
  , strict := false
  , definer := false
  , execute_roles := 'qgres__queue_delete,' || current_user
);
SELECT throws_ok(
  $$SELECT consume(-999999, 'no such consumer' )$$
  , 'P0002'
  , 'queue_id -999999 does not exist'
  , 'consume() with non-existent queue_id throws error'
);
SELECT throws_ok(
  $$SELECT consume('no such queue', 'no such consumer' )$$
  , 'P0002'
  , 'queue "no such queue" does not exist'
  , 'consume() with non-existent queue_name throws error'
);
SELECT throws_ok(
  $$SELECT consume('test SR queue', 'empty' )$$
  , '22023'
  , 'consume() may only be called on Serial Publisher queues'
  , 'consume() with non-existent consumer throws error'
);
SELECT throws_ok(
  $$SELECT consume('test SP queue', 'no such consumer' )$$
  , 'P0002'
  , 'consumer does not exist'
  , 'consume() with non-existent consumer throws error'
);
-- Sanity-checks
SELECT is(
  (SELECT count(*)::int FROM _sp_entry WHERE queue_id = queue__get_id('test SP queue'))
  , 8
  , 'Sanity-check test queue'
);
SELECT is(
  (SELECT int4range(min(sequence_number),max(sequence_number),'[]')
      FROM _sp_entry
      WHERE queue_id = queue__get_id('test SP queue')
    )
  , '[1,8]'::int4range
  , 'Sanity-check test queue entries'
);
SELECT bag_eq(
  $$SELECT consumer_name, last_sequence_number
      FROM _sp_consumer
      WHERE queue_id = queue__get_id('test SP queue')
    $$
  , $$SELECT * FROM (VALUES
        ('test consumer'::citext, 0::int)
        , ('post-NULLs', 4)
        , ('empty', 8)
      ) v(consumer_name, last_sequence_number)
      $$
  , 'Verify _sp_consumer contents'
);
-- Test returned values
SELECT results_eq(
  $$SELECT * FROM consume('test SP queue', 'test consumer', 4)$$
  , $$SELECT gs::int, NULL::bytea, NULL::jsonb, NULL::text
        FROM generate_series(1,4) gs
    $$
  , 'Verify NULL entries from test consumer'
);
SELECT is(
  (SELECT count(*)::int FROM _sp_entry WHERE queue_id = queue__get_id('test SP queue'))
  , 4
  , 'Verify queue entries are removed'
);
SELECT results_eq(
  format( $$SELECT * FROM consume('test SP queue', %L)$$, consumer ) 
  , $$SELECT *
        FROM
          (VALUES
            (5, '0xdeadbeef'::bytea, '{"key":"jsonb"}'::jsonb, 'text'::text)
            , (6, '0xdeadbeef'::bytea, NULL, NULL)
            , (7, NULL, '{"key":"jsonb"}', NULL)
            , (8, NULL, NULL, 'text')
          ) v(sequence_number, bytea, jsonb, text)
        ORDER BY sequence_number
    $$
  , format( 'Verify results from consumer %L', consumer )
) FROM unnest('{test consumer,post-NULLs}'::citext[]) consumer
;
SELECT is(
  (SELECT count(*)::int FROM _sp_entry WHERE queue_id = queue__get_id('test SP queue'))
  , 0
  , 'Verify queue entries are removed'
);
SELECT is(
      (SELECT count(*)::int FROM consume('test SP queue', consumer_name))
      , 0
      , format('Verify no rows returned for consumer %L', consumer_name)
    )
  FROM _sp_consumer
  WHERE queue_id = queue__get_id('test SP queue')
;
SELECT results_eq(
  $$SELECT "Publish"('test SP queue', gs::text) FROM generate_series(1,10) gs$$
  , $$SELECT generate_series(1,10)+8$$
  , 'Publish new records'
);
SELECT results_eq(
  format( $$SELECT sequence_number, text FROM consume('test SP queue', %L)$$, consumer ) 
  , $$SELECT gs+8, gs::text FROM generate_series(1,10) gs$$
  , format( 'Verify results from consumer %L', consumer )
) FROM unnest('{test consumer,post-NULLs}'::citext[]) consumer
;
SELECT is(
  (SELECT count(*)::int FROM _sp_entry WHERE queue_id = queue__get_id('test SP queue'))
  , 10
  , 'Verify queue entries still exist'
);
SELECT lives_ok(
  $$SELECT consumer__drop('test SP queue', 'empty')$$
  , $$Drop consumer 'empty'$$
);
SELECT is(
  (SELECT count(*)::int FROM _sp_entry WHERE queue_id = queue__get_id('test SP queue'))
  , 0
  , 'Verify queue entries are removed after dropping consumer'
);

/*
 * add()
 */
-- The main publish function
SELECT pg_temp.function_test(
  '_add'
  , 'int,queue_entry'
  , 'volatile'
  , strict := false
  , definer := true
  , execute_roles := 'qgres__queue_insert,' || current_user
);

/*
 * We need to test a 2x4 matrix of (queue_name|queue_id) and the various data
 * options.
 */
SELECT pg_temp.function_test(
      'add'
      , queue_arg || ',' || data_args
      , 'volatile'
      , strict := false
      , definer := false
      , execute_roles := 'public'
    )
  FROM (VALUES ('int'),('citext')) q(queue_arg)
    , (VALUES
      ('bytea,jsonb,text')
      , ('bytea')
      , ('jsonb')
      , ('text')
    ) d(data_args)
;
SELECT throws_ok(
  $$SELECT "_add"(-999999, queue_entry() )$$
  , 'P0002'
  , 'queue_id -999999 does not exist'
  , '_add with non-existent queue_id throws error'
);
SELECT throws_ok(
  $$SELECT "add"(-999999, NULL::text )$$
  , 'P0002'
  , 'queue_id -999999 does not exist'
  , 'add with non-existent queue_id throws error'
);
SELECT throws_ok(
  $$SELECT "add"('queue that should not exist', NULL::text )$$
  , 'P0002'
  , 'queue "queue that should not exist" does not exist'
  , 'adding to "queue that should not exist" throws error'
);
-- TEST NULLS
SELECT lives_ok(
  $$SELECT "add"('test SR queue', NULL, NULL, NULL)$$
  , $$SELECT "add"('test SR queue', NULL, NULL, NULL)$$
);
-- Test the 3 single arg versions
SELECT lives_ok(
      format(
        $$SELECT "add"('test SR queue', NULL::%I)$$
        , arg_type
      )
      , format(
        $$SELECT "add"('test SR queue', NULL::%I)$$
        , arg_type
      )
    )
  FROM unnest('{bytea,jsonb,text}'::regtype[]) u(arg_type)
;
SELECT lives_ok(
  $$SELECT "add"('test SR queue', '0xdeadbeef', '{"key":"jsonb"}'::jsonb, 'text')$$
  , $$SELECT "add"('test SR queue', '0xdeadbeef', '{"key":"jsonb"}'::jsonb, 'text')$$
);
SELECT lives_ok(
      format(
        $$SELECT "add"('test SR queue', %L::%I)$$
        , value, datatype
      )
      , format(
        $$SELECT "add"('test SR queue', %L::%I)$$
        , value, datatype
      )
    )
  FROM (VALUES
    ('0xdeadbeef'::text, 'bytea'::regtype)
    , ('{"key":"jsonb"}', 'jsonb')
    , ('text', 'text')
  ) v(value, datatype)
;

/*
 * Remove
 */
SELECT pg_temp.function_test(
  'Remove'
  , 'int,int'
  , 'volatile'
  , strict := false
  , definer := true
  , execute_roles := 'qgres__queue_delete,' || current_user
);
SELECT pg_temp.function_test(
  'Remove'
  , 'citext,int'
  , 'volatile'
  , strict := false
  , definer := false
  , execute_roles := 'qgres__queue_delete,' || current_user
);
SELECT throws_ok(
  $$SELECT "Remove"(-999999)$$
  , 'P0002'
  , 'queue_id -999999 does not exist'
  , '"Remove"() with non-existent queue_id throws error'
);
SELECT throws_ok(
  $$SELECT "Remove"('no such queue')$$
  , 'P0002'
  , 'queue "no such queue" does not exist'
  , '"Remove"() with non-existent queue_name throws error'
);
-- Sanity-check
SELECT is(
  (SELECT count(*)::int FROM _sr_entry WHERE queue_id = queue__get_id('test SR queue'))
  , 8
  , 'Sanity-check test queue'
);
SELECT lives_ok(
  $$CREATE TEMP TABLE sr_entries AS
      SELECT (entry).bytea, (entry).jsonb, (entry).text
        FROM _sr_entry
        WHERE queue_id = queue__get_id('test SR queue')
  $$
  , 'Create temp table with existing entries'
);
SELECT lives_ok(
  $$CREATE TEMP TABLE removed AS SELECT * FROM "Remove"('test SR queue', 2)$$
  , 'Remove 2 entries'
);
SELECT is(
  (SELECT count(*)::int FROM removed)
  , 2
  , 'Verify removed count'
);
SELECT is(
  (SELECT count(*)::int FROM _sr_entry WHERE queue_id = queue__get_id('test SR queue'))
  , 6
  , 'Verify queue count'
);
SELECT lives_ok(
  $$INSERT INTO removed SELECT * FROM "Remove"('test SR queue')$$
  , 'Remove remaining entries'
);
SELECT is(
  (SELECT count(*)::int FROM _sr_entry WHERE queue_id = queue__get_id('test SR queue'))
  , 0
  , 'Verify queue is empty'
);
SELECT bag_eq(
  $$SELECT * FROM removed$$
  , $$SELECT * FROM sr_entries$$
  , 'Verify removed entries'
);


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
