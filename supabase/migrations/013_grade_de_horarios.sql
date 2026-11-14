-- =====================================================================
-- Correção: os horários de cada barbeiro eram contados a partir do início do expediente dele.
-- Com intervalo de 40 min, quem começa às 07:00 tinha 07:00, 07:40, 08:20 (sem 08:00) e quem
-- começa às 08:00 tinha 08:00, 08:40... Agora todos usam a mesma grade do relógio.
-- =====================================================================

-- Intervalo de 20 minutos (07:00, 07:20, 07:40, 08:00...). A duração do serviço continua
-- definindo quanto tempo o horário fica ocupado.
update public.settings set value = '20' where key = 'slot_step_min';

create or replace function public._free_slots(
  p_barber bigint, p_day date, p_duration integer,
  p_ignore bigint default null, p_respect_window boolean default true
) returns setof timestamp
language plpgsql stable security definer set search_path = public as $$
declare
  v_now      timestamp := local_now();
  v_step_min integer   := greatest(coalesce(setting('slot_step_min'), 20), 5);
  v_step     interval  := make_interval(mins => v_step_min);
  v_dur      interval  := make_interval(mins => p_duration);
  v_earliest timestamp := v_now + make_interval(mins => setting('min_lead_min'));
  v_latest   timestamp := _latest_for(p_barber);
  v_start_min integer;
  w record;
  t timestamp;
begin
  for w in
    select start_time, end_time from working_hours
    where barber_id = p_barber and weekday = extract(dow from p_day)::int
    order by start_time
  loop
    -- Primeiro horário da grade do relógio dentro do expediente (ex.: expediente 07:10 → 07:20)
    v_start_min := (extract(epoch from w.start_time) / 60)::int;
    v_start_min := ((v_start_min + v_step_min - 1) / v_step_min) * v_step_min;
    t := p_day + make_interval(mins => v_start_min);
    while t + v_dur <= p_day + w.end_time loop
      if t > v_now
         and (not p_respect_window or (t >= v_earliest and t < v_latest))
         and not exists (
           select 1 from bookings b
           where b.barber_id = p_barber and b.id is distinct from p_ignore
             and b.start_at < t + v_dur and b.end_at > t
             and (b.status = 'confirmado' or (b.status = 'pendente' and b.hold_expires_at > v_now)))
         and not exists (
           select 1 from blocks k where k.barber_id = p_barber and k.start_at < t + v_dur and k.end_at > t)
      then
        return next t;
      end if;
      t := t + v_step;
    end loop;
  end loop;
end $$;

-- Configurações: o intervalo só aceita valores que fecham a hora (10, 15, 20, 30 ou 60)
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
    if k = 'slot_step_min' and v not in (10, 15, 20, 30, 60) then
      raise exception 'O intervalo entre horários precisa ser 10, 15, 20, 30 ou 60 minutos.' using errcode = 'PT400';
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
