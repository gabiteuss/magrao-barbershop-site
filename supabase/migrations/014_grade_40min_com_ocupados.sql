-- =====================================================================
-- Horários de 40 minutos contados a partir do início do expediente de cada barbeiro,
-- e uma grade completa do dia (livre / ocupado) para a tela de agendar.
-- =====================================================================

update public.settings set value = '40' where key = 'slot_step_min';
update public.services set duration_min = 40 where name in ('Social e Sobrancelha', 'Degradê e Sobrancelha');

-- Grade completa de um barbeiro num dia: todos os horários do expediente com a situação de cada um.
--   livre    = dá para marcar
--   ocupado  = já tem cliente ou bloqueio (folga, almoço)
--   encerrado = já passou (ou está em cima da hora)
--   fechado  = fora da agenda liberada pelo barbeiro
create or replace function public._slot_grid(
  p_barber bigint, p_day date, p_duration integer,
  p_ignore bigint default null, p_respect_window boolean default true
) returns table (slot timestamp, status text)
language plpgsql stable security definer set search_path = public as $$
declare
  v_now      timestamp := local_now();
  v_step     interval  := make_interval(mins => greatest(coalesce(setting('slot_step_min'), 40), 5));
  v_dur      interval  := make_interval(mins => p_duration);
  v_earliest timestamp := v_now + make_interval(mins => setting('min_lead_min'));
  v_latest   timestamp := _latest_for(p_barber);
  w record;
  t timestamp;
begin
  for w in
    select start_time, end_time from working_hours
    where barber_id = p_barber and weekday = extract(dow from p_day)::int
    order by start_time
  loop
    t := p_day + w.start_time;
    while t + v_dur <= p_day + w.end_time loop
      slot := t;
      if t <= v_now or (p_respect_window and t < v_earliest) then
        status := 'encerrado';
      elsif p_respect_window and t >= v_latest then
        status := 'fechado';
      elsif exists (
             select 1 from bookings b
             where b.barber_id = p_barber and b.id is distinct from p_ignore
               and b.start_at < t + v_dur and b.end_at > t
               and (b.status = 'confirmado' or (b.status = 'pendente' and b.hold_expires_at > v_now)))
         or exists (
             select 1 from blocks k where k.barber_id = p_barber and k.start_at < t + v_dur and k.end_at > t) then
        status := 'ocupado';
      else
        status := 'livre';
      end if;
      return next;
      t := t + v_step;
    end loop;
  end loop;
end $$;

-- Os horários livres saem da mesma grade (uma regra só para tudo)
create or replace function public._free_slots(
  p_barber bigint, p_day date, p_duration integer,
  p_ignore bigint default null, p_respect_window boolean default true
) returns setof timestamp
language sql stable security definer set search_path = public as $$
  select slot from _slot_grid(p_barber, p_day, p_duration, p_ignore, p_respect_window) where status = 'livre'
$$;

-- Tela de agendar: todos os horários do dia, barbeiro por barbeiro (sem dizer quem é o cliente)
create or replace function public.day_grid(p_service bigint, p_day date, p_barber bigint default null) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  v_dur integer;
begin
  select duration_min into v_dur from services where id = p_service and active;
  if v_dur is null then
    raise exception 'Serviço não encontrado.' using errcode = 'PT404';
  end if;
  return (
    select coalesce(json_agg(json_build_object(
             'barber_id', b.id, 'barber_name', b.name, 'photo', b.photo,
             'slots', (select coalesce(json_agg(json_build_object('time', to_char(g.slot, 'HH24:MI'), 'status', g.status) order by g.slot), '[]')
                       from _slot_grid(b.id, p_day, v_dur) g))
           order by b.id), '[]')
    from barbers b
    where b.active and (p_barber is null or b.id = p_barber));
end $$;

-- Configurações: intervalo de 10 a 120 minutos (de 5 em 5)
create or replace function public.admin_set_config(p jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare
  k text;
  v integer;
begin
  perform _require_admin();
  for k in select jsonb_object_keys(p) loop
    if k = 'birthday_gift' then
      if length(trim(coalesce(p->>k, ''))) < 3 or length(p->>k) > 200 then
        raise exception 'Descreva o brinde (até 200 letras).' using errcode = 'PT400';
      end if;
      update settings set value = trim(p->>k) where key = k;
      continue;
    end if;
    continue when k not in ('deposit_percent', 'reminder_minutes', 'hold_minutes', 'cancel_hours', 'slot_step_min',
                            'min_lead_min', 'days_ahead', 'waitlist_notify_count',
                            'confirm_required', 'confirm_ask_minutes', 'confirm_deadline_minutes', 'birthday_enabled');
    v := (p->>k)::integer;
    if k = 'slot_step_min' and (v < 10 or v > 120 or v % 5 <> 0) then
      raise exception 'O tempo de cada horário precisa ser de 10 a 120 minutos.' using errcode = 'PT400';
    end if;
    if v < 0 or (k = 'deposit_percent' and v > 100) or (k = 'hold_minutes' and v < 5)
       or (k in ('confirm_required', 'birthday_enabled') and v not in (0, 1)) or (k = 'confirm_deadline_minutes' and v < 5) then
      raise exception 'Valor inválido para %', k using errcode = 'PT400';
    end if;
    update settings set value = v::text where key = k;
  end loop;
  if setting('confirm_ask_minutes') <= setting('confirm_deadline_minutes') + 15 then
    raise exception 'O pedido de confirmação precisa sair pelo menos 15 minutos antes do prazo.' using errcode = 'PT400';
  end if;
  return admin_get_config();
end $$;

revoke execute on function public._slot_grid(bigint, date, integer, bigint, boolean) from public, anon, authenticated;
revoke execute on function public.day_grid(bigint, date, bigint) from public;
grant execute on function public.day_grid(bigint, date, bigint) to anon, authenticated;
