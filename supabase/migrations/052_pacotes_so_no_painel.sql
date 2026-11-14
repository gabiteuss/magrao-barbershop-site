-- Pacotes não aparecem mais no site público nem na área do cliente (14/11/2026).
-- Os pacotes são combinados com cada cliente (muitos levam o nome dele), então só a equipe vê e ativa pelo painel.
-- O cliente continua vendo os pacotes que ele já tem (my_packages -> mine).
do $$
declare v_src text; v_new text;
begin
  select pg_get_functiondef(oid) into v_src from pg_proc where proname = '_catalog' and pronamespace = 'public'::regnamespace;
  v_new := replace(v_src, 'where p_all or (k.active and s.active)', 'where p_all');
  if v_new = v_src then raise exception '_catalog mudou'; end if;
  execute v_new;
end $$;
