-- Painel: todos os horários de um dia, barbeiro por barbeiro, com quem está em cada horário ocupado.
-- Mesma grade do site (passo de slot_step_min), sem a janela de agendamento (mostra também os dias "em breve").
create or replace function public.staff_day_slots(p_day date, p_barber bigint default null) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  v_barber bigint := case when is_admin() then p_barber else my_barber_id() end;
  v_step int := greatest(coalesce(setting('slot_step_min'), 40), 5);
begin
  perform _require_staff();
  return (select coalesce(json_agg(json_build_object(
      'barber_id', br.id, 'barber_name', br.name,
      'closed', br.open_until is not null and br.open_until < p_day,
      'hours', (select coalesce(json_agg(to_char(h.start_time, 'HH24:MI') || '-' || to_char(h.end_time, 'HH24:MI') order by h.start_time), '[]')
                from _day_hours(br.id, p_day) h),
      'special', exists (select 1 from day_hours d where d.barber_id = br.id and d.day = p_day),
      'slots', (select coalesce(json_agg(json_build_object(
                  'time', to_char(g.slot, 'HH24:MI'),
                  'status', case when bk.id is not null then 'ocupado'
                                 when k.id is not null then 'bloqueado'
                                 when g.slot <= local_now() then 'passou'
                                 else 'livre' end,
                  'cliente', case when bk.id is not null then
                               coalesce((select name from children where id = bk.child_id) || ' (filho de ' || p.name || ')', p.name) end,
                  'servico', s.name,
                  'motivo', k.reason) order by g.slot), '[]')
                from _slot_grid(br.id, p_day, v_step, null, false) g
                left join lateral (select b.* from bookings b
                                   where b.barber_id = br.id and b.start_at < g.slot + make_interval(mins => v_step) and b.end_at > g.slot
                                     and (b.status in ('confirmado', 'concluido') or (b.status = 'pendente' and b.hold_expires_at > local_now()))
                                   order by b.start_at limit 1) bk on true
                left join profiles p on p.id = bk.user_id
                left join services s on s.id = bk.service_id
                left join lateral (select k.* from blocks k
                                   where k.barber_id = br.id and k.start_at < g.slot + make_interval(mins => v_step) and k.end_at > g.slot
                                   limit 1) k on true)
    ) order by br.id), '[]')
    from barbers br where br.active and (v_barber is null or br.id = v_barber));
end $$;

revoke execute on function public.staff_day_slots(date, bigint) from public, anon;
grant execute on function public.staff_day_slots(date, bigint) to authenticated;
