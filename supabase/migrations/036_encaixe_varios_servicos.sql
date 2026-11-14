-- Encaixe (já atendido) com mais de um serviço, igual ao agendamento do site:
-- o primeiro é o principal e os outros vão em extra_service_ids; o tempo é a soma das durações.
-- O valor cobrado continua sendo o que o barbeiro digita (a tela já sugere a soma dos preços).
do $$
declare v_src text; v_new text;
begin
  select pg_get_functiondef(oid) into v_src from pg_proc where proname = 'staff_walkin' and pronamespace = 'public'::regnamespace;
  v_new := v_src;
  v_new := replace(v_new, 'p_items jsonb DEFAULT NULL::jsonb)', 'p_items jsonb DEFAULT NULL::jsonb, p_extras bigint[] DEFAULT NULL::bigint[])');
  v_new := replace(v_new, '  pr products;', '  pr products;
  c record;');
  v_new := replace(v_new, '  if s.id is null then raise exception ''Serviço não encontrado.'' using errcode = ''PT404''; end if;',
    '  if s.id is null then raise exception ''Serviço não encontrado.'' using errcode = ''PT404''; end if;
  select * into c from _combo(s.id, p_extras);
  if not c.ok then raise exception ''Algum serviço escolhido não está mais disponível.'' using errcode = ''PT404''; end if;');
  v_new := replace(v_new, 'pay_choice, pay_method, final_price_cents, walk_in, walkin_name, attendance_confirmed_at, reminder_sent_at)',
                          'pay_choice, pay_method, final_price_cents, walk_in, walkin_name, attendance_confirmed_at, reminder_sent_at, extra_service_ids)');
  v_new := replace(v_new, 'values (v_user, p_barber, s.id, v_start, v_start + make_interval(mins => s.duration_min), ''concluido'', s.price_cents, 0,',
                          'values (v_user, p_barber, s.id, v_start, v_start + make_interval(mins => c.duration_min), ''concluido'', c.price_cents, 0,');
  v_new := replace(v_new, 'p_pay_method, p_price_cents, true, v_name, now(), now())', 'p_pay_method, p_price_cents, true, v_name, now(), now(), c.extras)');
  if position('c.extras)' in v_new) = 0 or position('p_extras bigint[]' in v_new) = 0 or position('s.duration_min' in v_new) > 0
     or position('_combo(s.id, p_extras)' in v_new) = 0 then
    raise exception 'staff_walkin mudou; ajuste a migração';
  end if;
  execute 'drop function public.staff_walkin(bigint, bigint, date, text, integer, text, uuid, text, text, jsonb)';
  execute v_new;
end $$;

revoke execute on function public.staff_walkin(bigint, bigint, date, text, integer, text, uuid, text, text, jsonb, bigint[]) from public, anon;
grant execute on function public.staff_walkin(bigint, bigint, date, text, integer, text, uuid, text, text, jsonb, bigint[]) to authenticated;
