-- Flexibilidade para o barbeiro:
-- 1) Fechar / reabrir a agenda com um clique (novos agendamentos; os já marcados continuam).
-- 2) Horário especial por dia (ou período): trabalhar mais tarde no fim de ano, sair cedo, folga, férias.
--    Num dia com horário especial, ele vale no lugar do expediente da semana. Linha sem horário = folga.
create table public.day_hours (
  id         bigserial primary key,
  barber_id  bigint not null references public.barbers(id) on delete cascade,
  day        date not null,
  start_time time,
  end_time   time,
  check ((start_time is null) = (end_time is null) and (start_time is null or end_time > start_time))
);
create index day_hours_barber_day on public.day_hours (barber_id, day);
alter table public.day_hours enable row level security;  -- só pelas funções

-- Expediente que vale num dia: o especial, se tiver; senão o da semana
create or replace function public._day_hours(p_barber bigint, p_day date)
returns table (start_time time, end_time time)
language sql stable security definer set search_path = public as $$
  select d.start_time, d.end_time from day_hours d
  where d.barber_id = p_barber and d.day = p_day and d.start_time is not null
    and exists (select 1 from day_hours x where x.barber_id = p_barber and x.day = p_day)
  union all
  select w.start_time, w.end_time from working_hours w
  where w.barber_id = p_barber and w.weekday = extract(dow from p_day)::int
    and not exists (select 1 from day_hours x where x.barber_id = p_barber and x.day = p_day)
$$;
revoke execute on function public._day_hours(bigint, date) from public, anon, authenticated;

-- A grade de horários, os dias abertos e a ocupação passam a usar o expediente do dia
do $$
declare v_src text; v_new text;
begin
  select pg_get_functiondef(oid) into v_src from pg_proc where proname = '_slot_grid' and pronamespace = 'public'::regnamespace;
  v_new := replace(v_src,
    'select start_time, end_time from working_hours
    where barber_id = p_barber and weekday = extract(dow from p_day)::int
    order by start_time',
    'select h.start_time, h.end_time from _day_hours(p_barber, p_day) h
    order by h.start_time');
  if v_new = v_src then raise exception '_slot_grid mudou; ajuste a migração'; end if;
  execute v_new;

  select pg_get_functiondef(oid) into v_src from pg_proc where proname = 'available_days' and pronamespace = 'public'::regnamespace;
  v_new := replace(v_src,
    '''open'', exists (select 1 from working_hours w join barbers b on b.id = w.barber_id
                             where b.active and (p_barber is null or b.id = p_barber) and w.weekday = extract(dow from d)::int),',
    '''open'', exists (select 1 from barbers b cross join lateral _day_hours(b.id, d::date) h
                             where b.active and (p_barber is null or b.id = p_barber)),');
  if v_new = v_src then raise exception 'available_days mudou; ajuste a migração'; end if;
  execute v_new;

  select pg_get_functiondef(oid) into v_src from pg_proc where proname = 'admin_day_load' and pronamespace = 'public'::regnamespace;
  v_new := replace(v_src,
    'from working_hours w join barbers b on b.id = w.barber_id
      where b.active and w.weekday = extract(dow from d)::int and (v_barber is null or b.id = v_barber)) c',
    'from barbers b cross join lateral _day_hours(b.id, d::date) w
      where b.active and (v_barber is null or b.id = v_barber)) c');
  if v_new = v_src then raise exception 'admin_day_load mudou; ajuste a migração'; end if;
  execute v_new;
end $$;

-- ------------------------------------------------------------- fechar / reabrir agenda
create or replace function public.staff_set_agenda_open(p_barber bigint, p_open boolean) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform _staff_can(p_barber);
  -- fechar = "aberta até ontem": hoje e os próximos dias deixam de aceitar novos agendamentos
  update barbers set open_until = case when p_open then null else local_now()::date - 1 end where id = p_barber;
  return json_build_object('open', p_open,
    'futuros', (select count(*) from bookings where barber_id = p_barber and status = 'confirmado' and start_at > local_now()));
end $$;

-- ------------------------------------------------------------- horário especial por dia/período
-- p_hours: [{"start":"07:00","end":"12:00"}, ...]; vazio = folga. p_hours null = volta ao expediente normal.
create or replace function public.staff_set_day_hours(p_barber bigint, p_from date, p_to date, p_hours jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare
  d date;
  h jsonb;
  v_fora int;
begin
  perform _staff_can(p_barber);
  if p_to is null then p_to := p_from; end if;
  if p_from is null or p_to < p_from then raise exception 'Período inválido.' using errcode = 'PT400'; end if;
  if p_from < local_now()::date then raise exception 'Escolha hoje ou um dia futuro.' using errcode = 'PT400'; end if;
  if p_to - p_from > 62 then raise exception 'No máximo 2 meses de uma vez.' using errcode = 'PT400'; end if;
  for h in select * from jsonb_array_elements(coalesce(p_hours, '[]')) loop
    if (h->>'start') !~ '^\d{2}:\d{2}$' or (h->>'end') !~ '^\d{2}:\d{2}$' or (h->>'end')::time <= (h->>'start')::time then
      raise exception 'Horário inválido: % a %', h->>'start', h->>'end' using errcode = 'PT400';
    end if;
  end loop;

  delete from day_hours where barber_id = p_barber and day between p_from and p_to;
  if p_hours is not null then
    for d in select generate_series(p_from, p_to, interval '1 day')::date loop
      if jsonb_array_length(p_hours) = 0 then
        insert into day_hours (barber_id, day) values (p_barber, d);
      else
        insert into day_hours (barber_id, day, start_time, end_time)
        select p_barber, d, (x->>'start')::time, (x->>'end')::time from jsonb_array_elements(p_hours) x;
      end if;
    end loop;
  end if;

  -- clientes já marcados que ficaram fora do novo horário (não são desmarcados: o barbeiro decide)
  select count(*) into v_fora from bookings b
  where b.barber_id = p_barber and b.status = 'confirmado' and b.start_at::date between p_from and p_to
    and not exists (select 1 from _day_hours(p_barber, b.start_at::date) w
                    where b.start_at::time >= w.start_time and b.end_at::time <= w.end_time);
  return json_build_object('fora_do_horario', v_fora);
end $$;

-- Dias com horário especial daqui para frente
create or replace function public.staff_day_hours(p_barber bigint) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  perform _staff_can(p_barber);
  return (select coalesce(json_agg(json_build_object('day', day, 'hours', hrs) order by day), '[]') from (
    select day, json_agg(json_build_object('start', to_char(start_time, 'HH24:MI'), 'end', to_char(end_time, 'HH24:MI'))
                         order by start_time) filter (where start_time is not null) as hrs
    from day_hours where barber_id = p_barber and day >= local_now()::date group by day) x);
end $$;

revoke execute on function public.staff_set_agenda_open(bigint, boolean), public.staff_set_day_hours(bigint, date, date, jsonb),
  public.staff_day_hours(bigint) from public, anon;
grant execute on function public.staff_set_agenda_open(bigint, boolean), public.staff_set_day_hours(bigint, date, date, jsonb),
  public.staff_day_hours(bigint) to authenticated;
