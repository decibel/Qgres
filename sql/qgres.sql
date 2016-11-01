CREATE SCHEMA qgres_temp; -- Can't use pg_temp or entire extension will uninstall after commit
CREATE OR REPLACE FUNCTION qgres_temp.role__create(
  role_name name
) RETURNS void LANGUAGE plpgsql AS $body$
BEGIN
  IF NOT EXISTS( SELECT 1 FROM pg_roles WHERE rolname = role_name ) THEN
    EXECUTE format( $$CREATE ROLE %I$$, role_name );
  ELSE
    RAISE NOTICE 'role "%" already exists, skipping', role_name;
  END IF;
END
$body$;
SELECT qgres_temp.role__create( 'qgres__queue_manage' );
SELECT qgres_temp.role__create( 'qgres__queue_insert' );
SELECT qgres_temp.role__create( 'qgres__queue_delete' );
DROP FUNCTION qgres_temp.role__create(name);

CREATE TYPE queue_type AS ENUM(
  'Serial Publisher'
  , 'Serial Remover'
);

/*
 * Eventually we might support adding additional types to this, so best to make
 * it a stand-alone type (and make it public). This will simplify some other
 * code too.
 */
CREATE TYPE queue_entry AS(
  bytea bytea
  , jsonb jsonb
  , text text
);
CREATE OR REPLACE FUNCTION queue_entry(
  bytea bytea DEFAULT NULL
  , jsonb jsonb DEFAULT NULL
  , text text DEFAULT NULL
) RETURNS queue_entry IMMUTABLE LANGUAGE sql AS $body$
SELECT row($1,$2,$3)::queue_entry;
$body$;

CREATE OR REPLACE FUNCTION _queue_type__sanitize(
  queue_type text
) RETURNS queue_type LANGUAGE sql STRICT STABLE AS $body$
SELECT CASE
  WHEN upper(queue_type) = 'SP' THEN 'Serial Publisher'
  WHEN upper(queue_type) = 'SR' THEN 'Serial Remover'
  ELSE initcap(queue_type)
END::queue_type
$body$;
COMMENT ON FUNCTION _queue_type__sanitize(
  text
) IS $$Used to standardize input to the queue_type ENUM.$$;

CREATE OR REPLACE FUNCTION _tg_not_allowed(
) RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN
  RAISE '% to % is not allowed', TG_OP, TG_RELID::regclass;
END
$body$;

/*
 * TABLES
 */
CREATE TABLE _queue(
  queue_id      serial    NOT NULL PRIMARY KEY
  , queue_name    citext    NOT NULL UNIQUE
  , queue_type    queue_type  NOT NULL
);
CREATE OR REPLACE FUNCTION _queue_dml(
) RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN
  IF TG_WHEN <> 'AFTER' THEN
    RAISE 'trigger definition error';
  END IF;
  CASE TG_OP
    WHEN 'INSERT' THEN
      CASE NEW.queue_type 
        WHEN 'Serial Publisher' THEN
          INSERT INTO _sp_next_sequence_number(queue_id, next_sequence_number)
            VALUES(NEW.queue_id, 1)
          ;
        WHEN 'Serial Remover' THEN
          NULL;
      ELSE RAISE 'unknown queue type %', n.queue_type;
      END CASE;
    WHEN 'UPDATE' THEN
      RAISE 'updates to % are not allowed', TG_RELID::regclass;
    WHEN 'DELETE' THEN
      NULL;
    ELSE RAISE 'unknown operation %', TG_OP;
  END CASE;
  RETURN NULL;
END
$body$;
CREATE TRIGGER _queue_dml AFTER INSERT OR UPDATE OR DELETE ON _queue
  FOR EACH ROW EXECUTE PROCEDURE _queue_dml()
;
CREATE TRIGGER update AFTER UPDATE ON _queue
  FOR EACH ROW EXECUTE PROCEDURE _tg_not_allowed()
;

CREATE TABLE _sp_next_sequence_number(
  queue_id      int     NOT NULL PRIMARY KEY REFERENCES _queue ON DELETE CASCADE
  , next_sequence_number    int     NOT NULL
);
CREATE OR REPLACE FUNCTION _tg_sp_next_sequence_number__verify_sp_queue(
) RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN
  IF (queue__get(NEW.queue_id)).queue_type <> 'Serial Publisher' THEN
    RAISE 'only valid for Serial Publisher queues';
  END IF;
  RETURN NULL;
END
$body$;
CREATE TRIGGER verify_sp_queue__insert AFTER INSERT ON _sp_next_sequence_number
  FOR EACH ROW EXECUTE PROCEDURE _tg_sp_next_sequence_number__verify_sp_queue()
;
CREATE TRIGGER update_queue_id AFTER UPDATE OF queue_id ON _sp_next_sequence_number
  FOR EACH ROW EXECUTE PROCEDURE _tg_not_allowed()
;

CREATE TABLE _sp_consumer(
  queue_id        int     NOT NULL REFERENCES _sp_next_sequence_number -- Ensures this is an sp queue
  , consumer_name citext  NOT NULL
  , CONSTRAINT _sp_consumer__pk_queue_id__consumer_name PRIMARY KEY( queue_id, consumer_name )
  -- TODO: move to a separate table for better performance
  , last_sequence_number int     NOT NULL
);
CREATE TRIGGER update AFTER UPDATE OF queue_id, consumer_name ON _sp_consumer
  FOR EACH ROW EXECUTE PROCEDURE _tg_not_allowed()
;
CREATE TABLE _sp_entry(
  queue_id          int             NOT NULL
      REFERENCES _sp_next_sequence_number -- Ensures this is an sp queue
  , sequence_number int             NOT NULL
  , CONSTRAINT _sp_consumer__pk_queue_id__sequence_number PRIMARY KEY( queue_id, sequence_number )
  , entry           queue_entry     NOT NULL
);
CREATE OR REPLACE FUNCTION _tg_sp_entry__sequence_number(
) RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN
  IF NEW.sequence_number IS DISTINCT FROM
    -- See below as well!
    (SELECT next_sequence_number - 1
        FROM _sp_next_sequence_number nsn
        WHERE nsn.queue_id = NEW.queue_id
      )
  THEN
    RAISE 'sequence number error'
      USING DETAIL = format(
          'NEW.queue_id = %L, NEW.sequence_number = %L, expected = %L'
          , NEW.queue_id
          , NEW.sequence_number
          -- Duplicated for performance reasons (avoid storing plpgsql variables)
          , (SELECT next_sequence_number - 1
            FROM _sp_next_sequence_number nsn
            WHERE nsn.queue_id = NEW.queue_id
          )
        )
      , HINT = 'This should never happen; please open an issue on GitHub.'
    ;
  END IF;
  RETURN NULL;
END
$body$;
CREATE TRIGGER insert AFTER INSERT ON _sp_entry
  FOR EACH ROW EXECUTE PROCEDURE _tg_sp_entry__sequence_number()
;
CREATE TRIGGER update AFTER UPDATE ON _sp_entry
  FOR EACH ROW EXECUTE PROCEDURE _tg_not_allowed()
;

CREATE OR REPLACE FUNCTION _sp_trim(
  queue_id  _queue.queue_id%TYPE
) RETURNS void LANGUAGE plpgsql AS $body$
DECLARE
  p_queue_id ALIAS FOR queue_id;
BEGIN
  -- Not worth sanity-checking rowcount, since things like dropping a consumer could affect it
  DELETE FROM _sp_entry e
    WHERE e.queue_id = p_queue_id
      AND e.sequence_number <=
        (SELECT min(last_sequence_number)
            FROM _sp_consumer c
            WHERE c.queue_id = e.queue_id
          )
  ;
END
$body$;
REVOKE ALL ON FUNCTION _sp_trim(
  queue_id  _queue.queue_id%TYPE
) FROM public;

CREATE TABLE _sr_entry(
  queue_id          int             NOT NULL REFERENCES _queue
  , entry           queue_entry     NOT NULL
);
CREATE OR REPLACE FUNCTION _tg_sr_entry__verify_sp_queue(
) RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN
  IF (queue__get(NEW.queue_id)).queue_type <> 'Serial Remover' THEN
    RAISE 'only valid for Serial Remover queues';
  END IF;
  RETURN NULL;
END
$body$;
CREATE TRIGGER verify_sr_entry__insert AFTER INSERT ON _sr_entry
  FOR EACH ROW EXECUTE PROCEDURE _tg_sr_entry__verify_sp_queue()
;
CREATE TRIGGER update AFTER UPDATE ON _sr_entry
  FOR EACH ROW EXECUTE PROCEDURE _tg_not_allowed()
;


CREATE OR REPLACE VIEW queue AS
  SELECT queue_id, queue_name, queue_type
    FROM _queue
;
GRANT SELECT ON queue TO PUBLIC;

/*
 * API FUNCTIONS
 */
CREATE OR REPLACE FUNCTION queue__get(
  queue_name  _queue.queue_name%TYPE
) RETURNS queue LANGUAGE plpgsql STABLE AS $body$
DECLARE
  p_queue_name ALIAS FOR queue_name;
  r record;
BEGIN
  SELECT INTO STRICT r
      *
    FROM queue q
    WHERE q.queue_name = p_queue_name
  ;
  RETURN r;
EXCEPTION WHEN no_data_found THEN
  RAISE 'queue "%" does not exist', queue_name
    USING ERRCODE = 'no_data_found'
  ;
END
$body$;
CREATE OR REPLACE FUNCTION queue__get(
  queue_id  _queue.queue_id%TYPE
) RETURNS queue LANGUAGE plpgsql STABLE AS $body$
DECLARE
  p_queue_id ALIAS FOR queue_id;
  r record;
BEGIN
  SELECT INTO STRICT r
      *
    FROM queue q
    WHERE q.queue_id = p_queue_id
  ;
  RETURN r;
EXCEPTION WHEN no_data_found THEN
  RAISE 'queue_id % does not exist', queue_id
    USING ERRCODE = 'no_data_found'
  ;
END
$body$;
CREATE OR REPLACE FUNCTION queue__get_id(
  queue_name  _queue.queue_name%TYPE
) RETURNS int LANGUAGE sql STABLE AS $body$
SELECT (queue__get(queue_name)).queue_id
$body$;

CREATE OR REPLACE FUNCTION queue__create(
  queue_name  _queue.queue_name%TYPE
  , queue_type _queue.queue_type%TYPE
  , OUT queue_id int
) LANGUAGE plpgsql SECURITY DEFINER AS $body$
BEGIN
  INSERT INTO _queue(queue_name, queue_type)
    VALUES(queue_name, queue_type)
    RETURNING _queue.queue_id INTO STRICT queue_id
  ;
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'queue "%" already exists', queue_name
    USING HINT = 'Remember that queue names are case insensitive.'
      , ERRCODE = 'unique_violation'
  ;
END
$body$;
REVOKE ALL ON FUNCTION queue__create(
  queue_name  _queue.queue_name%TYPE
  , queue_type _queue.queue_type%TYPE
) FROM public;
GRANT EXECUTE ON FUNCTION queue__create(
  queue_name  _queue.queue_name%TYPE
  , queue_type _queue.queue_type%TYPE
) TO qgres__queue_manage;
COMMENT ON FUNCTION queue__create(
  queue_name  _queue.queue_name%TYPE
  , queue_type _queue.queue_type%TYPE
) IS $$Creates a new queue. Returns queue_id for the new queue. Raises an error if a queue with the same name already exists.$$;

CREATE OR REPLACE FUNCTION queue__create(
  queue_name _queue.queue_name%TYPE
  , queue_type text
  , OUT queue_id int
) LANGUAGE SQL AS $body$
SELECT queue__create(queue_name, _queue_type__sanitize(queue_type))
$body$;


CREATE OR REPLACE FUNCTION queue__drop(
  queue_id  _queue.queue_id%TYPE
  , force boolean DEFAULT false
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $body$
DECLARE
  p_queue_id ALIAS FOR queue_id;
BEGIN
  DELETE FROM _queue
    WHERE _queue.queue_id = p_queue_id
  ;
  IF NOT found THEN
    RAISE 'queue_id % does not exist', queue_id
      USING ERRCODE = 'no_data_found'
    ;
  END IF;
EXCEPTION
-- TODO: handle case when events exist
  WHEN unique_violation THEN
    -- dependent_objects_still_exist
    RAISE EXCEPTION 'queue "%" already exists', queue_id
      USING HINT = 'Remember that queue names are case insensitive.'
        , ERRCODE = 'unique_violation'
    ;
END
$body$;
REVOKE ALL ON FUNCTION queue__drop(
  queue_id  _queue.queue_id%TYPE
  , boolean
) FROM public;
GRANT EXECUTE ON FUNCTION queue__drop(
  queue_id  _queue.queue_id%TYPE
  , boolean
) TO qgres__queue_manage;
COMMENT ON FUNCTION queue__drop(
  queue_id  _queue.queue_id%TYPE
  , boolean
) IS $$Drops a queue. Raises an error if the queue does not exist, or if there are events in the queue (unless force is true).$$;


CREATE OR REPLACE FUNCTION queue__drop(
  queue_name  _queue.queue_name%TYPE
  , force boolean DEFAULT false
) RETURNS void LANGUAGE sql AS $body$
SELECT queue__drop(queue__get_id(queue_name), force)
$body$;
COMMENT ON FUNCTION queue__drop(
  queue_name  _queue.queue_name%TYPE
  , boolean
) IS $$Drops a queue. Raises an error if the queue does not exist, or if there are events in the queue (unless force is true).$$;

/*
 * CONSUMER functions
 */

-- Register
CREATE OR REPLACE FUNCTION consumer__register(
  queue_name _queue.queue_name%TYPE
  , consumer_name _sp_consumer.consumer_name%TYPE
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $body$
DECLARE
  r_queue _queue;
BEGIN
  r_queue := queue__get(queue_name); -- sanity-check's queue_name for us
  IF r_queue.queue_type <> 'Serial Publisher' THEN
    RAISE 'consumers may only be registered on "Serial Publisher" queues'
      USING ERRCODE = 'invalid_parameter_value'
    ;
  END IF;
  INSERT INTO _sp_consumer(queue_id, consumer_name, last_sequence_number)
    VALUES(
      r_queue.queue_id
      , consumer_name
      , (SELECT next_sequence_number - 1
          FROM _sp_next_sequence_number
          WHERE queue_id = r_queue.queue_id
          FOR UPDATE
        )
    )
  ;
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'consumer "%" on queue "%" already exists', consumer_name, queue_name
    USING HINT = 'Remember that queue names and consumer names are case insensitive.'
      , ERRCODE = 'unique_violation'
  ;
END
$body$;
REVOKE ALL ON FUNCTION consumer__register(
  queue_name _queue.queue_name%TYPE
  , consumer_name _sp_consumer.consumer_name%TYPE
) FROM public;
GRANT EXECUTE ON FUNCTION consumer__register(
  queue_name _queue.queue_name%TYPE
  , consumer_name _sp_consumer.consumer_name%TYPE
) TO qgres__queue_delete;
COMMENT ON FUNCTION consumer__register(
  queue_name _queue.queue_name%TYPE
  , consumer_name _sp_consumer.consumer_name%TYPE
) IS $$Register a consumer on a queue.$$;

-- DROP
CREATE OR REPLACE FUNCTION consumer__drop(
  queue_name _queue.queue_name%TYPE
  , consumer_name _sp_consumer.consumer_name%TYPE
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $body$
DECLARE
  p_consumer_name ALIAS FOR consumer_name;

  r_queue _queue;
BEGIN
  r_queue := queue__get(queue_name); -- sanity-check's queue_name for us
  IF r_queue.queue_type <> 'Serial Publisher' THEN
    RAISE 'consumers may only be dropped on "Serial Publisher" queues'
      USING ERRCODE = 'invalid_parameter_value'
    ;
  END IF;
  DELETE FROM _sp_consumer
    WHERE queue_id = r_queue.queue_id
      AND _sp_consumer.consumer_name = p_consumer_name
  ;
  IF NOT FOUND THEN
    RAISE 'consumer "%" on queue "%" is not registered', consumer_name, queue_name
      USING ERRCODE = 'no_data_found'
    ;
  END IF;

  -- Trim, in case this consumer was holding entries in the queue
  PERFORM _sp_trim(r_queue.queue_id);
END
$body$;
REVOKE ALL ON FUNCTION consumer__drop(
  queue_name _queue.queue_name%TYPE
  , consumer_name _sp_consumer.consumer_name%TYPE
) FROM public;
GRANT EXECUTE ON FUNCTION consumer__drop(
  queue_name _queue.queue_name%TYPE
  , consumer_name _sp_consumer.consumer_name%TYPE
) TO qgres__queue_delete;
COMMENT ON FUNCTION consumer__drop(
  queue_name _queue.queue_name%TYPE
  , consumer_name _sp_consumer.consumer_name%TYPE
) IS $$Register a consumer on a queue.$$;

/*
 * "Publish"()
 */
-- This is our "base" function; all others are wrappers
CREATE OR REPLACE FUNCTION "_Publish"(
  queue_id _queue.queue_id%TYPE
  , entry queue_entry
  , OUT sequence_number _sp_next_sequence_number.next_sequence_number%TYPE
) SECURITY DEFINER LANGUAGE plpgsql AS $body$
DECLARE
  p_queue_id ALIAS FOR queue_id;

  rowcount bigint;
BEGIN
  UPDATE _sp_next_sequence_number AS sp
    SET next_sequence_number = next_sequence_number + 1
    WHERE sp.queue_id = p_queue_id
    RETURNING next_sequence_number - 1 -- RETURNING gives the NEW value
    INTO sequence_number
  ;
  -- We make these checks the hard way to avoid the cost of starting a subtransaction
  GET DIAGNOSTICS rowcount = ROW_COUNT;
  CASE
    WHEN rowcount = 1 THEN
      NULL; -- OK
    WHEN rowcount = 0 THEN
      -- See if the queue even exists, and if it's an SP queue
      DECLARE
        r_queue queue;
      BEGIN
        -- This will give a good error if queue doesn't exist
        r_queue := queue__get(p_queue_id);

        IF r_queue.queue_type <> 'Serial Publisher' THEN
          RAISE '"Publish"() may only be called on Serial Publisher queues'
            USING ERRCODE = 'invalid_parameter_value'
              , DETAIL = format( 'queue_id %L is type %L', p_queue_id, r_queue.queue_type )
              , HINT = 'Perhaps you want to use the add() function instead?'
          ;
        ELSE
          RAISE 'no record in _sp_next_sequence_number for queue_id %', p_queue_id
            USING HINT = 'This should never happen; please open an issue on GitHub.'
          ;
        END IF;
      END;
    WHEN rowcount > 1 THEN
      RAISE 'multiple records in _sp_next_sequence_number for queue_id %', p_queue_id
        USING HINT = 'This should never happen; please open an issue on GitHub.'
      ;
    ELSE
      RAISE EXCEPTION 'unexpected rowcount value "%"', rowcount
        USING HINT = 'This should never happen; please open an issue on GitHub.'
      ;
  END CASE;

  INSERT INTO _sp_entry VALUES(p_queue_id, sequence_number, entry);
END
$body$;
REVOKE ALL ON FUNCTION "_Publish"(
  queue_id _queue.queue_id%TYPE
  , entry queue_entry
  , OUT sequence_number _sp_next_sequence_number.next_sequence_number%TYPE
) FROM public;
GRANT EXECUTE ON FUNCTION "_Publish"(
  queue_id _queue.queue_id%TYPE
  , entry queue_entry
  , OUT sequence_number _sp_next_sequence_number.next_sequence_number%TYPE
) TO qgres__queue_insert;

CREATE OR REPLACE FUNCTION "Publish"(
  queue_id _queue.queue_id%TYPE
  , bytea bytea
  , jsonb jsonb
  , text text
  , OUT sequence_number _sp_next_sequence_number.next_sequence_number%TYPE
) LANGUAGE sql AS $body$
SELECT "_Publish"(queue_id, queue_entry(bytea := bytea, jsonb := jsonb, text := text))
$body$;
CREATE OR REPLACE FUNCTION "Publish"(
  queue_name _queue.queue_name%TYPE
  , bytea bytea
  , jsonb jsonb
  , text text
  , OUT sequence_number _sp_next_sequence_number.next_sequence_number%TYPE
) LANGUAGE sql AS $body$
SELECT "_Publish"(queue__get_id(queue_name), queue_entry(bytea := bytea, jsonb := jsonb, text := text))
$body$;
CREATE OR REPLACE FUNCTION qgres_temp.build_publish(
  first_arg text
  , call text
  , data_type regtype
) RETURNS void LANGUAGE plpgsql AS $build$
DECLARE
  c_template CONSTANT text := $template$
CREATE OR REPLACE FUNCTION "Publish"(
  %1$s
  , %3$s %3$s
  , OUT sequence_number _sp_next_sequence_number.next_sequence_number%%TYPE
) LANGUAGE sql AS $body$
SELECT "_Publish"(%2$s, queue_entry(%3$s := %3$s))
$body$;
$template$;
BEGIN
  EXECUTE format(c_template, first_arg, call, data_type);
END
$build$;
SELECT qgres_temp.build_publish( first_arg, call, data_type )
  FROM
  (VALUES
      ('queue_id _queue.queue_id%TYPE'::text, 'queue_id'::text)
      , ('queue_name _queue.queue_name%TYPE', 'queue__get_id(queue_name)')
    ) v(first_arg, call)
  , unnest('{bytea,jsonb,text}'::regtype[]) data_type
;
DROP FUNCTION qgres_temp.build_publish(text,text,regtype); 

/*
 * "add"()
 */
-- This is our "base" function; all others are wrappers
CREATE OR REPLACE FUNCTION "_add"(
  queue_id _queue.queue_id%TYPE
  , entry queue_entry
) RETURNS void SECURITY DEFINER LANGUAGE plpgsql AS $body$
DECLARE
  p_queue_id ALIAS FOR queue_id;

  v_constraint_name name;
BEGIN
  INSERT INTO _sr_entry VALUES(p_queue_id, entry);
EXCEPTION WHEN foreign_key_violation THEN
  GET STACKED DIAGNOSTICS v_constraint_name = CONSTRAINT_NAME;
  IF v_constraint_name = '_sr_entry_queue_id_fkey' THEN
    RAISE 'queue_id % does not exist', p_queue_id
      USING ERRCODE = 'no_data_found'
    ;
  ELSE
    RAISE; -- Re-raise error
  END IF;
END
$body$;
REVOKE ALL ON FUNCTION "_add"(
  queue_id _queue.queue_id%TYPE
  , entry queue_entry
) FROM public;
GRANT EXECUTE ON FUNCTION "_add"(
  queue_id _queue.queue_id%TYPE
  , entry queue_entry
) TO qgres__queue_insert;

CREATE OR REPLACE FUNCTION "add"(
  queue_id _queue.queue_id%TYPE
  , bytea bytea
  , jsonb jsonb
  , text text
) RETURNS void LANGUAGE sql AS $body$
SELECT "_add"(queue_id, queue_entry(bytea := bytea, jsonb := jsonb, text := text))
$body$;
CREATE OR REPLACE FUNCTION "add"(
  queue_name _queue.queue_name%TYPE
  , bytea bytea
  , jsonb jsonb
  , text text
) RETURNS void LANGUAGE sql AS $body$
SELECT "_add"(queue__get_id(queue_name), queue_entry(bytea := bytea, jsonb := jsonb, text := text))
$body$;
CREATE OR REPLACE FUNCTION qgres_temp.build_add(
  first_arg text
  , call text
  , data_type regtype
) RETURNS void LANGUAGE plpgsql AS $build$
DECLARE
  c_template CONSTANT text := $template$
CREATE OR REPLACE FUNCTION "add"(
  %1$s
  , %3$s %3$s
) RETURNS void LANGUAGE sql AS $body$
SELECT "_add"(%2$s, queue_entry(%3$s := %3$s))
$body$;
$template$;
BEGIN
  EXECUTE format(c_template, first_arg, call, data_type);
END
$build$;
SELECT qgres_temp.build_add( first_arg, call, data_type )
  FROM
  (VALUES
      ('queue_id _queue.queue_id%TYPE'::text, 'queue_id'::text)
      , ('queue_name _queue.queue_name%TYPE', 'queue__get_id(queue_name)')
    ) v(first_arg, call)
  , unnest('{bytea,jsonb,text}'::regtype[]) data_type
;
DROP FUNCTION qgres_temp.build_add(text,text,regtype); 

/*
 * consume()
 */
CREATE OR REPLACE FUNCTION consume(
  queue_id _queue.queue_id%TYPE
  , consumer_name _sp_consumer.consumer_name%TYPE
  , row_limit int DEFAULT 2^31-1
) RETURNS TABLE(
  sequence_number _sp_entry.sequence_number%TYPE
  , bytea bytea
  , jsonb jsonb
  , text text
) LANGUAGE plpgsql SECURITY DEFINER AS $body$
DECLARE
  p_queue_id ALIAS FOR queue_id;
  p_consumer_name ALIAS FOR consumer_name;
  p_limit ALIAS FOR row_limit;

  v_sequence_number int;
  v_last_sequence_number int;
  rowcount bigint;
BEGIN
  DECLARE
    r_queue queue;
  BEGIN
    SELECT INTO STRICT v_sequence_number
        last_sequence_number
      FROM _sp_consumer c
      WHERE
        c.queue_id = p_queue_id
        AND c.consumer_name = p_consumer_name
      FOR UPDATE
    ;
  EXCEPTION WHEN no_data_found THEN
    -- This will throw an error if the queue doesn't exist, which is what we want
    r_queue := queue__get(queue_id);

    IF r_queue.queue_type <> 'Serial Publisher' THEN
      RAISE 'consume() may only be called on Serial Publisher queues'
        USING ERRCODE = 'invalid_parameter_value'
          , DETAIL = format( 'queue_id %L is type %L', p_queue_id, r_queue.queue_type )
          , HINT = 'Perhaps you want to use the "Remove"() function instead?'
      ;
    END IF;
    
    -- If we end up here then the consumer must not exist
    RAISE 'consumer does not exist'
      USING ERRCODE = 'no_data_found'
        , DETAIL = format( 'queue_id %L, consumer_name  %L', p_queue_id, p_consumer_name )
    ;
  END;

  FOR sequence_number, bytea, jsonb, text IN
    SELECT e.sequence_number, (entry).bytea, (entry).jsonb, (entry).text
      FROM _sp_entry e
        WHERE e.queue_id = p_queue_id
          AND e.sequence_number > v_sequence_number
      ORDER BY e.sequence_number
      LIMIT p_limit
  LOOP
    v_last_sequence_number = sequence_number;
    RETURN NEXT;
  END LOOP;

  IF FOUND THEN
    -- Update consumer
    UPDATE _sp_consumer c
      SET last_sequence_number = v_last_sequence_number
      WHERE c.queue_id = p_queue_id
        AND c.consumer_name = p_consumer_name
    ;
    GET DIAGNOSTICS rowcount = ROW_COUNT;
    CASE
      WHEN rowcount = 1 THEN
        NULL; -- OK
      WHEN rowcount = 0 THEN
        RAISE '_sp_consumer record vanished'
          USING HINT = 'This should never happen; please open an issue on GitHub.'
            , DETAIL = format( 'queue_id %L, consumer_name  %L', p_queue_id, p_consumer_name )
        ;
      WHEN rowcount > 1 THEN
        RAISE 'multiple records updated'
          USING HINT = 'This should never happen; please open an issue on GitHub.'
            , DETAIL = format( 'queue_id %L, consumer_name  %L', p_queue_id, p_consumer_name )
        ;
      ELSE
        RAISE EXCEPTION 'unexpected rowcount value "%"', rowcount
          USING HINT = 'This should never happen; please open an issue on GitHub.'
            , DETAIL = format( 'queue_id %L, consumer_name  %L', p_queue_id, p_consumer_name )
        ;
    END CASE;

    PERFORM _sp_trim(p_queue_id);
  END IF;
END
$body$;
REVOKE ALL ON FUNCTION consume(
  queue_id _queue.queue_id%TYPE
  , consumer_name _sp_consumer.consumer_name%TYPE
  , row_limit int
) FROM public;
GRANT EXECUTE ON FUNCTION consume(
  queue_id _queue.queue_id%TYPE
  , consumer_name _sp_consumer.consumer_name%TYPE
  , row_limit int
) TO qgres__queue_delete;

CREATE OR REPLACE FUNCTION consume(
  queue_name _queue.queue_name%TYPE
  , consumer_name _sp_consumer.consumer_name%TYPE
  , row_limit int DEFAULT 2^31-1
) RETURNS TABLE(
  sequence_number _sp_entry.sequence_number%TYPE
  , bytea bytea
  , jsonb jsonb
  , text text
) LANGUAGE sql AS $body$
SELECT consume(
  queue__get_id(queue_name)
  , consumer_name
  , row_limit
);
$body$;
REVOKE ALL ON FUNCTION consume(
  queue_name _queue.queue_name%TYPE
  , consumer_name _sp_consumer.consumer_name%TYPE
  , row_limit int
) FROM public;
GRANT EXECUTE ON FUNCTION consume(
  queue_name _queue.queue_name%TYPE
  , consumer_name _sp_consumer.consumer_name%TYPE
  , row_limit int
) TO qgres__queue_delete;

/*
 * Remove
 */
CREATE OR REPLACE FUNCTION "Remove"(
  queue_id _queue.queue_id%TYPE
  , row_limit int DEFAULT 2^31-1
) RETURNS TABLE(
  bytea bytea
  , jsonb jsonb
  , text text
) LANGUAGE plpgsql SECURITY DEFINER AS $body$
DECLARE
  p_queue_id ALIAS FOR queue_id;

  r_queue queue;
BEGIN
  -- Throws error for non-existent queue
  r_queue := queue__get(p_queue_id);

  IF r_queue.queue_type <> 'Serial Remover' THEN
    RAISE 'consume() may only be called on Serial Remover queues'
      USING ERRCODE = 'invalid_parameter_value'
        , DETAIL = format( 'queue_id %L is type %L', p_queue_id, r_queue.queue_type )
        , HINT = 'Perhaps you want to use the consume() function instead?'
    ;
  END IF;

  RETURN QUERY
    DELETE FROM _sr_entry e1
      USING (
        SELECT ctid
          FROM _sr_entry
          LIMIT row_limit
          FOR UPDATE
      ) e2
      WHERE e1.ctid = e2.ctid
      RETURNING (entry).bytea, (entry).jsonb, (entry).text
  ;
END
$body$;
REVOKE ALL ON FUNCTION "Remove"(
  queue_id _queue.queue_id%TYPE
  , row_limit int
) FROM public;
GRANT EXECUTE ON FUNCTION "Remove"(
  queue_id _queue.queue_id%TYPE
  , row_limit int
) TO qgres__queue_delete;
CREATE OR REPLACE FUNCTION "Remove"(
  queue_name _queue.queue_name%TYPE
  , row_limit int DEFAULT 2^31-1
) RETURNS TABLE(
  bytea bytea
  , jsonb jsonb
  , text text
) LANGUAGE sql AS $body$
SELECT "Remove"(queue__get_id(queue_name), row_limit)
$body$;
REVOKE ALL ON FUNCTION "Remove"(
  queue_name _queue.queue_name%TYPE
  , row_limit int
) FROM public;
GRANT EXECUTE ON FUNCTION "Remove"(
  queue_name _queue.queue_name%TYPE
  , row_limit int
) TO qgres__queue_delete;

DROP SCHEMA qgres_temp; 
-- vi: expandtab ts=2 sw=2
