-- Balcão: marcar o corte do filho na conta do pai (ex.: o filho vem sozinho e o pai paga depois).
-- O barbeiro escolhe um filho já cadastrado ou digita o nome (fica cadastrado na conta do pai).
create or replace function public.admin_children(p_user uuid) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  perform _require_staff();
  return (select coalesce(json_agg(json_build_object('id', id, 'name', name) order by id), '[]')
          from children where user_id = p_user and active);
end $$;

do $$
declare v_src text; v_new text;
begin
  select pg_get_functiondef(oid) into v_src from pg_proc where proname = 'admin_create_booking' and pronamespace = 'public'::regnamespace;
  v_new := v_src;
  v_new := replace(v_new, 'p_use_package boolean DEFAULT false)', 'p_use_package boolean DEFAULT false, p_child_name text DEFAULT NULL::text)');
  v_new := replace(v_new, '  v_cp bigint;', '  v_cp bigint;
  v_child bigint;
  v_child_name text := nullif(initcap(trim(regexp_replace(coalesce(p_child_name, ''''), ''\s+'', '' '', ''g''))), '''');');
  v_new := replace(v_new, '  perform pg_advisory_xact_lock(hashtext(''agenda''));', '  if v_child_name is not null then
    if length(v_child_name) < 2 then raise exception ''Digite o nome do filho.'' using errcode = ''PT400''; end if;
    select id into v_child from children where user_id = p.id and active and lower(name) = lower(v_child_name) limit 1;
    if v_child is null then
      insert into children (user_id, name) values (p.id, v_child_name) returning id into v_child;
    end if;
  end if;

  perform pg_advisory_xact_lock(hashtext(''agenda''));');
  v_new := replace(v_new, 'pay_choice, pay_method, client_package_id, final_price_cents)', 'pay_choice, pay_method, client_package_id, final_price_cents, child_id)');
  v_new := replace(v_new, '(select round(price_cents::numeric / qty)::int from client_packages where id = v_cp))', '(select round(price_cents::numeric / qty)::int from client_packages where id = v_cp), v_child)');
  v_new := replace(v_new, 'jsonb_build_array(first_name(p.name), s.name,', 'jsonb_build_array(first_name(p.name), s.name || coalesce('' para '' || v_child_name, ''''),');
  if (length(v_new) - length(v_src)) < 400 or position('v_child)' in v_new) = 0 or position('p_child_name text' in v_new) = 0 then
    raise exception 'admin_create_booking mudou; ajuste a migração';
  end if;
  execute 'drop function public.admin_create_booking(uuid, bigint, date, text, bigint, boolean, boolean)';
  execute v_new;
end $$;

revoke execute on function public.admin_children(uuid), public.admin_create_booking(uuid, bigint, date, text, bigint, boolean, boolean, text) from public, anon;
grant execute on function public.admin_children(uuid), public.admin_create_booking(uuid, bigint, date, text, bigint, boolean, boolean, text) to authenticated;
