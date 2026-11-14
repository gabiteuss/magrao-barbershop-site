-- WhatsApp real dos barbeiros (29/10/2026). Guilherme fica vazio (número informado não é de celular) e usa o da barbearia.
update public.barbers set whatsapp = '55XXXXXXXXXXX' where id = 4 and name = 'Pablo';
update public.barbers set whatsapp = '55XXXXXXXXXXX' where id = 1 and name = 'Willian';
update public.barbers set whatsapp = '5519984094568' where id = 3 and name = 'Magrão';

-- Números do topo da agenda: clientes com cadastro no site e clientes marcados hoje e nos próximos dias.
-- Conta só horários ativos, então um desmarque já diminui na hora. Barbeiro vê só os dele (sem o total de cadastros).
create or replace function public.staff_client_counts() returns json
language plpgsql stable security definer set search_path = public as $$
declare
  v_barber bigint := case when is_admin() then null else my_barber_id() end;
  v_today date := local_now()::date;
begin
  perform _require_staff();
  return json_build_object(
    'cadastrados', case when v_barber is null then
        (select count(*) from profiles where role = 'client' and has_login) end,
    'balcao', case when v_barber is null then
        (select count(*) from profiles where role = 'client' and not has_login and phone <> '5500000000000') end,
    'hoje_total', (select count(*) from bookings where start_at::date = v_today and status in ('confirmado', 'concluido')
                     and (v_barber is null or barber_id = v_barber)),
    'hoje_falta', (select count(*) from bookings where start_at::date = v_today and status = 'confirmado'
                     and (v_barber is null or barber_id = v_barber)),
    'futuros', (select count(*) from bookings where start_at::date > v_today and status = 'confirmado'
                  and (v_barber is null or barber_id = v_barber)),
    'futuros_dias', (select count(distinct start_at::date) from bookings where start_at::date > v_today and status = 'confirmado'
                  and (v_barber is null or barber_id = v_barber)),
    'agora', to_char(local_now(), 'HH24:MI'));
end $$;

revoke execute on function public.staff_client_counts() from public, anon;
grant execute on function public.staff_client_counts() to authenticated;
