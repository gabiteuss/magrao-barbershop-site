-- Barbeiro toca num horário da grade do dia e escolhe: bloquear (ninguém agenda) ou liberar para agendar.
-- Liberar um pedaço de um bloqueio maior (ex.: almoço 12:00-13:20) corta o bloqueio e mantém o resto.
create or replace function public.staff_toggle_slot(p_barber bigint, p_day date, p_time text, p_block boolean) returns json
language plpgsql security definer set search_path = public as $$
declare
  v_step interval := make_interval(mins => greatest(coalesce(setting('slot_step_min'), 40), 5));
  v_start timestamp;
  v_end timestamp;
  k blocks;
begin
  perform _staff_can(p_barber);
  if p_time !~ '^\d{2}:\d{2}$' then raise exception 'Horário inválido.' using errcode = 'PT400'; end if;
  v_start := p_day + p_time::time;
  v_end := v_start + v_step;
  if v_end <= local_now() then raise exception 'Esse horário já passou.' using errcode = 'PT400'; end if;

  if p_block then
    if exists (select 1 from bookings b where b.barber_id = p_barber and b.start_at < v_end and b.end_at > v_start
                 and (b.status = 'confirmado' or (b.status = 'pendente' and b.hold_expires_at > local_now()))) then
      raise exception 'Tem cliente marcado nesse horário. Desmarque ou mova antes de bloquear.' using errcode = 'PT409';
    end if;
    if not exists (select 1 from blocks where barber_id = p_barber and start_at < v_end and end_at > v_start) then
      insert into blocks (barber_id, start_at, end_at, reason) values (p_barber, v_start, v_end, 'bloqueado pelo barbeiro');
    end if;
  else
    for k in select * from blocks where barber_id = p_barber and start_at < v_end and end_at > v_start loop
      delete from blocks where id = k.id;
      if k.start_at < v_start then
        insert into blocks (barber_id, start_at, end_at, reason) values (p_barber, k.start_at, v_start, k.reason);
      end if;
      if k.end_at > v_end then
        insert into blocks (barber_id, start_at, end_at, reason) values (p_barber, v_end, k.end_at, k.reason);
      end if;
    end loop;
  end if;
  return json_build_object('ok', true);
end $$;

revoke execute on function public.staff_toggle_slot(bigint, date, text, boolean) from public, anon;
grant execute on function public.staff_toggle_slot(bigint, date, text, boolean) to authenticated;
