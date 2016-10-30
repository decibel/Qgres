CREATE SCHEMA qgres_temp; -- Can't use pg_temp or entire extension will uninstall after commit
CREATE FUNCTION qgres_temp.role__create(
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

CREATE FUNCTION _queue_type__sanitize(
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

CREATE FUNCTION _tg_not_allowed(
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
CREATE FUNCTION _queue_dml(
) RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN
  IF TG_WHEN <> 'AFTER' THEN
    RAISE 'trigger definition error';
  END IF;
  CASE TG_OP
    WHEN 'INSERT' THEN
      CASE NEW.queue_type 
        WHEN 'Serial Publisher' THEN
          INSERT INTO _sp_entry_id(queue_id, entry_id)
            VALUES(NEW.queue_id, 0)
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

CREATE TABLE _sp_entry_id(
  queue_id      int     NOT NULL PRIMARY KEY REFERENCES _queue ON DELETE CASCADE
  , entry_id    int     NOT NULL
);
CREATE FUNCTION _tg_sp_entry_id__verify_sp_queue(
) RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN
  IF (queue__get(NEW.queue_id)).queue_type <> 'Serial Publisher' THEN
    RAISE 'only valid for Serial Publisher queues';
  END IF;
  RETURN NULL;
END
$body$;
CREATE TRIGGER verify_sp_queue__insert AFTER INSERT ON _sp_entry_id
  FOR EACH ROW EXECUTE PROCEDURE _tg_sp_entry_id__verify_sp_queue()
;
CREATE TRIGGER update_queue_id AFTER UPDATE OF queue_id ON _sp_entry_id
  FOR EACH ROW EXECUTE PROCEDURE _tg_not_allowed()
;

CREATE TABLE _sp_consumer(
  queue_id        int     NOT NULL REFERENCES _sp_entry_id -- Ensures this is an sp queue
  , consumer_name citext  NOT NULL
  , CONSTRAINT _sp_consumer__pk_queue_id__consumer_name PRIMARY KEY( queue_id, consumer_name )
  -- TODO: move to a separate table for better performance
  , next_entry_id int     NOT NULL
);
CREATE TRIGGER update AFTER UPDATE OF queue_id, consumer_name ON _sp_consumer
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
CREATE FUNCTION queue__get(
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
CREATE FUNCTION queue__get(
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
CREATE FUNCTION queue__get_id(
  queue_name  _queue.queue_name%TYPE
) RETURNS int LANGUAGE sql STABLE AS $body$
SELECT (queue__get(queue_name)).queue_id
$body$;

CREATE FUNCTION queue__create(
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

CREATE FUNCTION queue__create(
  queue_name _queue.queue_name%TYPE
  , queue_type text
  , OUT queue_id int
) LANGUAGE SQL AS $body$
SELECT queue__create(queue_name, _queue_type__sanitize(queue_type))
$body$;


CREATE FUNCTION queue__drop(
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


CREATE FUNCTION queue__drop(
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
  INSERT INTO _sp_consumer(queue_id, consumer_name, next_entry_id)
    VALUES(
      r_queue.queue_id
      , consumer_name
      , (SELECT entry_id
          FROM _sp_entry_id
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



DROP SCHEMA qgres_temp; 
-- vi: expandtab ts=2 sw=2
