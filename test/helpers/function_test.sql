CREATE FUNCTION pg_temp.function_test(
    fname name
    , args text
    , volatility text
    , strict boolean
    , definer boolean DEFAULT false
    , execute_roles text DEFAULT NULL
) RETURNS SETOF text LANGUAGE plpgsql AS $body$
DECLARE
  c_args CONSTANT name[] := string_to_array(args, ',')::regtype[]::name[];
  c_execute_roles CONSTANT name[] := string_to_array(nullif(execute_roles,'public'), ',')::name[];

  fsig CONSTANT text := format('%I(%s)', fname, array_to_string(c_args, ', '));
  proc pg_proc;
BEGIN
  -- TODO: catch exception when function doesn't exist
  SELECT INTO STRICT proc
      *
    FROM pg_proc
    WHERE oid = fsig::regprocedure
  ;

  RETURN NEXT volatility_is(fname, c_args, volatility);

  IF strict THEN
    RETURN NEXT is_strict(fname, c_args);
  ELSE
    RETURN NEXT isnt_strict(fname, c_args);
  END IF;

  IF definer THEN
    RETURN NEXT is_definer(fname, c_args);
  ELSE
    -- TODO: Fix after pgtap 0.97.0
    RETURN NEXT is(
      (proc).prosecdef
      , false
      , format( 'Function %s shouldn''t be security definer', fsig )
    );
  END IF;
  IF c_execute_roles IS NULL THEN
    RETURN NEXT is(
      (proc).proacl
      , NULL
      , format( 'Function %s shouldn''t have any permissions defined', fsig )
    );
  ELSE
    RETURN NEXT bag_eq(
      format($$SELECT grantee::name FROM unnest(acl(%L::aclitem[])) u WHERE rights = array['EXECUTE'::acl_right]$$, (proc).proacl)
      , c_execute_roles
      , 'Check EXECUTE rights on function ' || fsig
    );
  END IF;
END
$body$;

CREATE FUNCTION pg_temp.function_test_count(
    execute_roles text DEFAULT NULL
) RETURNS int LANGUAGE plpgsql AS $body$
DECLARE
  c_execute_roles CONSTANT name[] := string_to_array(execute_roles, ',')::name[];
BEGIN
  RETURN 4;
END
$body$;

-- vi: expandtab ts=2 sw=2
