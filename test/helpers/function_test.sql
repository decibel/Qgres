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
  c_execute_roles CONSTANT name[] := string_to_array(execute_roles, ',')::name[];

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
  IF c_execute_roles = array['public'::name] THEN
    RETURN NEXT is(
      (proc).proacl
      , NULL
      , format( 'Function %s shouldn''t have any permissions defined', fsig )
    );
  ELSIF c_execute_roles IS NOT NULL THEN
    RETURN QUERY SELECT function_privs_are(
      fname
      , c_args
      , rolname
      , CASE WHEN
            rolname = ANY(c_execute_roles || array[current_user])
          THEN array['EXECUTE']
        ELSE NULL
      END
    ) FROM pg_roles
    ;
  END IF;
END
$body$;

CREATE FUNCTION pg_temp.function_test_count(
    execute_roles text DEFAULT NULL
) RETURNS int LANGUAGE plpgsql AS $body$
DECLARE
  c_execute_roles CONSTANT name[] := string_to_array(execute_roles, ',')::name[];
BEGIN
  IF c_execute_roles = array['public'::name] THEN
    RETURN 3+1;
  ELSIF c_execute_roles IS NOT NULL THEN
    RETURN 3 + (SELECT count(*)::int FROM pg_roles);
  ELSE
    RETURN 3;
  END IF;
END
$body$;

-- vi: expandtab ts=2 sw=2
