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

CREATE TABLE _sp_entry_id(
  queue_id      int     NOT NULL PRIMARY KEY REFERENCES _queue ON DELETE CASCADE
  , entry_id    int     NOT NULL
);


/*
 * API FUNCTIONS
 */
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
  
DROP SCHEMA qgres_temp; 
-- vi: expandtab ts=2 sw=2
