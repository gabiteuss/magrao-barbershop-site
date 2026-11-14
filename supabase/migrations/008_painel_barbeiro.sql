-- =====================================================================
-- Painel por barbeiro (moderador) + agenda liberada até uma data escolhida
-- =====================================================================

-- Até que dia os clientes podem agendar com este barbeiro (vazio = próximos X dias, como antes)
alter table public.barbers add column open_until date;
-- Quantas vezes a barbearia mudou o horário deste agendamento
alter table public.bookings add column reschedule_count integer not null default 0;

-- Último horário que o cliente pode marcar com o barbeiro
create or replace function public._latest_for(p_barber bigint) returns timestamp
language sql stable security definer set search_path = public as $$
  select coalesce((select (open_until + 1)::timestamp from barbers where id = p_barber),
                  local_now() + make_interval(days => setting('days_ahead')))
$$;

-- Último dia que aparece no calendário (o mais longe entre os barbeiros)
create or replace function public._calendar_end(p_barber bigint default null) returns date
language sql stable security definer set search_path = public as $$
  select least(local_now()::date + 120,
               coalesce(max(_latest_for(id))::date - case when bool_and(open_until is not null) then 1 else 0 end,
                        local_now()::date + setting('days_ahead')))
  from barbers where active and (p_barber is null or id = p_barber)
$$;

create or replace function public._free_slots(
  p_barber bigint, p_day date, p_duration integer,
  p_ignore bigint default null, p_respect_window boolean default true
) returns setof timestamp
language plpgsql stable security definer set search_path = public as $$
declare
  v_now      timestamp := local_now();
  v_step     interval  := make_interval(mins => setting('slot_step_min'));
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

-- Calendário do site: além das vagas, diz se o dia já foi liberado
create or replace function public.available_days(p_service bigint, p_barber bigint default null) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  v_dur integer;
  v_today date := local_now()::date;
begin
  select duration_min into v_dur from services where id = p_service and active;
  if v_dur is null then
    raise exception 'Serviço não encontrado.' using errcode = 'PT404';
  end if;
  return (
    select json_agg(json_build_object(
             'date', d::date,
             'open', exists (select 1 from working_hours w join barbers b on b.id = w.barber_id
                             where b.active and (p_barber is null or b.id = p_barber) and w.weekday = extract(dow from d)::int),
             'released', exists (select 1 from barbers b where b.active and (p_barber is null or b.id = p_barber)
                                 and d::date < _latest_for(b.id)::date + case when b.open_until is null then 1 else 0 end),
             'free', (select count(distinct t) from barbers b cross join lateral _free_slots(b.id, d::date, v_dur) t
                      where b.active and (p_barber is null or b.id = p_barber)))
           order by d)
    from generate_series(v_today, greatest(_calendar_end(p_barber), v_today + 6), interval '1 day') d);
end $$;

create or replace function public.join_waitlist(p_service bigint, p_date date, p_barber bigint default null) returns json
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then
    raise exception 'Entre na sua conta.' using errcode = 'PT401';
  end if;
  if p_date < local_now()::date or p_date > greatest(_calendar_end(p_barber), local_now()::date + 6) then
    raise exception 'Data fora da agenda.' using errcode = 'PT400';
  end if;
  if not exists (select 1 from services where id = p_service and active) then
    raise exception 'Serviço não encontrado.' using errcode = 'PT404';
  end if;
  if exists (select 1 from waitlist where user_id = auth.uid() and date = p_date and status = 'aguardando') then
    raise exception 'Você já está na lista de espera desse dia.' using errcode = 'PT409';
  end if;
  if (select count(*) from waitlist where user_id = auth.uid() and status = 'aguardando') >= 5 then
    raise exception 'Você já está em 5 listas de espera.' using errcode = 'PT429';
  end if;
  insert into waitlist (user_id, service_id, barber_id, date) values (auth.uid(), p_service, p_barber, p_date);
  return json_build_object('ok', true,
    'position', (select count(*) from waitlist where date = p_date and status = 'aguardando'));
end $$;

-- Reagendamento pela barbearia conta no painel do barbeiro
create or replace function public._count_reschedule() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.moved_by_shop and (new.start_at <> old.start_at or new.barber_id <> old.barber_id) then
    new.reschedule_count := old.reschedule_count + 1;
  end if;
  return new;
end $$;
create trigger count_reschedule before update of start_at, barber_id on public.bookings
  for each row execute function public._count_reschedule();

-- ------------------------------------------------------------- números do barbeiro
create or replace function public.barber_stats(p_barber bigint, p_from date, p_to date) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  perform _staff_can(p_barber);
  if p_to < p_from or p_to - p_from > 370 then raise exception 'Período inválido.' using errcode = 'PT400'; end if;
  return (
    select json_build_object(
      'barber_id', br.id, 'barber_name', br.name, 'commission_percent', br.commission_percent, 'open_until', br.open_until,
      'cortes', count(*) filter (where b.status = 'concluido'),
      'faturamento_cents', coalesce(sum(_charged(b)) filter (where b.status = 'concluido'), 0)::int,
      'comissao_cents', coalesce(sum(round(_charged(b) * br.commission_percent / 100.0)) filter (where b.status = 'concluido'), 0)::int,
      'desmarques_cliente', count(*) filter (where b.status = 'cancelado' and b.cancelled_by = 'cliente'),
      'desmarques_barbearia', count(*) filter (where b.status = 'cancelado' and b.cancelled_by = 'barbearia'),
      'faltas', count(*) filter (where b.status = 'faltou'),
      'reagendamentos', coalesce(sum(b.reschedule_count), 0)::int,
      'clientes', count(distinct b.user_id) filter (where b.status = 'concluido'),
      'proximos', (select count(*) from bookings x where x.barber_id = br.id and x.status = 'confirmado' and x.start_at > local_now()))
    from barbers br
    left join bookings b on b.barber_id = br.id and b.start_at::date between p_from and p_to and b.status <> 'expirado'
    where br.id = p_barber
    group by br.id);
end $$;

-- Clientes do barbeiro (todo o histórico com ele)
create or replace function public.barber_clients(p_barber bigint, p_q text default '') returns json
language plpgsql stable security definer set search_path = public as $$
declare
  v_digits text := regexp_replace(coalesce(p_q, ''), '\D', '', 'g');
begin
  perform _staff_can(p_barber);
  return (select coalesce(json_agg(x order by x.ultima_visita desc nulls last, x.name), '[]') from (
    select p.id, p.name, p.phone, p.has_login,
           count(*) filter (where b.status = 'concluido') as cortes,
           count(*) filter (where b.status = 'cancelado') as desmarques,
           count(*) filter (where b.status = 'faltou') as faltas,
           coalesce(sum(b.reschedule_count), 0)::int as reagendamentos,
           max(b.start_at) filter (where b.status = 'concluido') as ultima_visita,
           min(b.start_at) filter (where b.status = 'confirmado' and b.start_at > local_now()) as proximo
    from bookings b join profiles p on p.id = b.user_id
    where b.barber_id = p_barber and b.status <> 'expirado'
      and (coalesce(p_q, '') = '' or p.name ilike '%' || trim(p_q) || '%' or (length(v_digits) >= 4 and p.phone like '%' || v_digits || '%'))
    group by p.id
    limit 300) x);
end $$;

-- O barbeiro (ou o dono) muda o próprio expediente e até quando a agenda está aberta
create or replace function public.staff_save_schedule(p_barber bigint, p_hours jsonb, p_open_until date default null) returns void
language plpgsql security definer set search_path = public as $$
declare
  h jsonb;
begin
  perform _staff_can(p_barber);
  -- Data no passado = agenda fechada para novos agendamentos pelo site
  if p_open_until is not null and p_open_until > local_now()::date + 120 then
    raise exception 'Dá para abrir a agenda até 120 dias à frente.' using errcode = 'PT400';
  end if;
  update barbers set open_until = p_open_until where id = p_barber;
  delete from working_hours where barber_id = p_barber;
  for h in select * from jsonb_array_elements(coalesce(p_hours, '[]')) loop
    if (h->>'end')::time <= (h->>'start')::time then
      raise exception 'Expediente inválido: % a %', h->>'start', h->>'end' using errcode = 'PT400';
    end if;
    insert into working_hours (barber_id, weekday, start_time, end_time)
    values (p_barber, (h->>'weekday')::smallint, (h->>'start')::time, (h->>'end')::time);
  end loop;
end $$;

-- Lista de barbeiros com a agenda aberta e quem tem acesso a cada um
create or replace function public.admin_barbers() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  perform _require_staff();
  return (select coalesce(json_agg(json_build_object('id', b.id, 'name', b.name, 'title', b.title, 'bio', b.bio, 'photo', b.photo,
            'active', b.active, 'commission_percent', b.commission_percent, 'open_until', b.open_until,
            'accounts', (select coalesce(json_agg(p.name order by p.name), '[]') from profiles p where p.barber_id = b.id and p.role = 'barber'),
            'hours', (select coalesce(json_agg(json_build_object('weekday', w.weekday,
               'start', to_char(w.start_time, 'HH24:MI'), 'end', to_char(w.end_time, 'HH24:MI')) order by w.weekday, w.start_time), '[]')
               from working_hours w where w.barber_id = b.id)) order by b.id), '[]')
          from barbers b);
end $$;

-- Dono salva o barbeiro inteiro (inclui a agenda aberta)
create or replace function public.admin_save_barber(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_id bigint := nullif(p->>'id', '')::bigint;
  v_pct integer := coalesce((p->>'commission_percent')::int, 60);
  v_until date := nullif(p->>'open_until', '')::date;
begin
  perform _require_admin();
  if v_pct not between 0 and 100 then raise exception 'Comissão precisa ser de 0 a 100%%.' using errcode = 'PT400'; end if;
  if v_id is null then
    insert into barbers (name, title, bio, photo, active, commission_percent)
    values (p->>'name', coalesce(p->>'title', 'Barbeiro'), coalesce(p->>'bio', ''), coalesce(p->>'photo', ''),
            coalesce((p->>'active')::boolean, true), v_pct)
    returning id into v_id;
  else
    update barbers set name = p->>'name', title = coalesce(p->>'title', 'Barbeiro'), bio = coalesce(p->>'bio', ''),
           photo = coalesce(p->>'photo', ''), active = coalesce((p->>'active')::boolean, true), commission_percent = v_pct
    where id = v_id;
  end if;
  perform staff_save_schedule(v_id, coalesce(p->'hours', '[]'), v_until);
end $$;

revoke execute on function public._latest_for(bigint), public._calendar_end(bigint), public._count_reschedule()
  from public, anon, authenticated;
revoke execute on function public.barber_stats(bigint, date, date), public.barber_clients(bigint, text),
  public.staff_save_schedule(bigint, jsonb, date) from public, anon;
grant execute on function public.barber_stats(bigint, date, date), public.barber_clients(bigint, text),
  public.staff_save_schedule(bigint, jsonb, date) to authenticated;
