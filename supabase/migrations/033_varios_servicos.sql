-- O cliente escolhe mais de um serviço no mesmo horário (ex.: corte + barba + alisamento).
-- Fica UM agendamento: o primeiro serviço é o principal e os outros vão em extra_service_ids.
-- Tempo = soma das durações (a grade procura um horário em que caibam todos); preço = soma dos preços.
alter table public.bookings add column if not exists extra_service_ids bigint[] not null default '{}';

-- Nome que aparece em todo lugar: "Degradê e Barba + Alisamento + Luzes"
create or replace function public._service_label(b bookings) returns text
language sql stable security definer set search_path = public as $$
  select (select name from services where id = b.service_id)
      || coalesce((select string_agg(' + ' || s.name, '' order by x.ord)
                   from unnest(b.extra_service_ids) with ordinality x(id, ord) join services s on s.id = x.id), '')
$$;

-- Tempo, preço e "a partir de" de um conjunto de serviços (principal + extras, sem repetir)
create or replace function public._combo(p_service bigint, p_extras bigint[])
returns table (duration_min integer, price_cents integer, price_from boolean, extras bigint[], ok boolean)
language sql stable security definer set search_path = public as $$
  with ids as (
    select p_service as id, 0::bigint as ord
    union all
    select x.id, x.ord from unnest(coalesce(p_extras, '{}')) with ordinality x(id, ord) where x.id is distinct from p_service
  ), u as (select distinct on (id) id, ord from ids order by id, ord)
  select coalesce(sum(s.duration_min), 0)::int, coalesce(sum(s.price_cents), 0)::int, coalesce(bool_or(s.price_from), false),
         coalesce(array_agg(u.id order by u.ord) filter (where u.id <> p_service), '{}'),
         count(s.id) = count(*) and count(*) <= 6
  from u left join services s on s.id = u.id and s.active
$$;
revoke execute on function public._service_label(bookings), public._combo(bigint, bigint[]) from public, anon, authenticated;

-- Grade e dias livres com o tempo somado
drop function public.day_grid(bigint, date, bigint);
create function public.day_grid(p_service bigint, p_day date, p_barber bigint default null, p_extras bigint[] default null) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  c record;
begin
  select * into c from _combo(p_service, p_extras);
  if not c.ok or c.duration_min = 0 then raise exception 'Serviço não encontrado.' using errcode = 'PT404'; end if;
  return (
    select coalesce(json_agg(json_build_object(
             'barber_id', b.id, 'barber_name', b.name, 'photo', b.photo,
             'slots', (select coalesce(json_agg(json_build_object('time', to_char(g.slot, 'HH24:MI'), 'status', g.status) order by g.slot), '[]')
                       from _slot_grid(b.id, p_day, c.duration_min) g))
           order by b.id), '[]')
    from barbers b
    where b.active and (p_barber is null or b.id = p_barber));
end $$;

drop function public.available_days(bigint, bigint);
create function public.available_days(p_service bigint, p_barber bigint default null, p_extras bigint[] default null) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  c record;
  v_today date := local_now()::date;
begin
  select * into c from _combo(p_service, p_extras);
  if not c.ok or c.duration_min = 0 then raise exception 'Serviço não encontrado.' using errcode = 'PT404'; end if;
  return (
    select json_agg(json_build_object(
             'date', d::date,
             'open', exists (select 1 from barbers b cross join lateral _day_hours(b.id, d::date) h
                             where b.active and (p_barber is null or b.id = p_barber)),
             'released', exists (select 1 from barbers b where b.active and (p_barber is null or b.id = p_barber)
                                 and d::date < _latest_for(b.id)::date + case when b.open_until is null then 1 else 0 end),
             'free', (select count(distinct t) from barbers b cross join lateral _free_slots(b.id, d::date, c.duration_min) t
                      where b.active and (p_barber is null or b.id = p_barber)))
           order by d)
    from generate_series(v_today, greatest(_calendar_end(p_barber), v_today + 6), interval '1 day') d);
end $$;

grant execute on function public.day_grid(bigint, date, bigint, bigint[]), public.available_days(bigint, bigint, bigint[]) to anon, authenticated;

-- Agendar com extras: tempo, preço e nome somados. Pacote vale só para um serviço sozinho.
do $$
declare v_src text; v_new text;
begin
  select pg_get_functiondef(oid) into v_src from pg_proc where proname = 'create_booking' and pronamespace = 'public'::regnamespace;
  v_new := v_src;
  v_new := replace(v_new, 'p_child bigint DEFAULT NULL::bigint)', 'p_child bigint DEFAULT NULL::bigint, p_extras bigint[] DEFAULT NULL::bigint[])');
  v_new := replace(v_new, '  v_child  text;', '  v_child  text;
  c        record;');
  v_new := replace(v_new, '  if p_child is not null then', '  select * into c from _combo(s.id, p_extras);
  if not c.ok then raise exception ''Algum serviço escolhido não está mais disponível.'' using errcode = ''PT404''; end if;
  if p_pay = ''pacote'' and cardinality(c.extras) > 0 then
    raise exception ''O pacote vale só para o serviço dele. Com serviços a mais, escolha pagar na barbearia.'' using errcode = ''PT400'';
  end if;
  if p_child is not null then');
  v_new := replace(v_new, '(setting(''online_pay'') <> 1 or s.price_from)', '(setting(''online_pay'') <> 1 or c.price_from)');
  v_new := replace(v_new, 'start_at < v_start + make_interval(mins => s.duration_min) and end_at > v_start', 'start_at < v_start + make_interval(mins => c.duration_min) and end_at > v_start');
  v_new := replace(v_new, '_free_slots(cand, p_date, s.duration_min)', '_free_slots(cand, p_date, c.duration_min)');
  v_new := replace(v_new, 'round(s.price_cents * setting(''deposit_percent'') / 100.0)', 'round(c.price_cents * setting(''deposit_percent'') / 100.0)');
  v_new := replace(v_new, 'client_package_id, final_price_cents, child_id)', 'client_package_id, final_price_cents, child_id, extra_service_ids)');
  v_new := replace(v_new, 'values (v_uid, v_barber, s.id, v_start, v_start + make_interval(mins => s.duration_min),', 'values (v_uid, v_barber, s.id, v_start, v_start + make_interval(mins => c.duration_min),');
  v_new := replace(v_new, '          s.price_cents, v_dep, v_now', '          c.price_cents, v_dep, v_now');
  v_new := replace(v_new, '(select round(price_cents::numeric / qty)::int from client_packages where id = v_cp), p_child)', '(select round(price_cents::numeric / qty)::int from client_packages where id = v_cp), p_child, c.extras)');
  v_new := replace(v_new, '            s.name || coalesce('' para '' || v_child, ''''),', '            s.name || coalesce((select string_agg('' + '' || x.name, '''') from services x where x.id = any(c.extras)), '''') || coalesce('' para '' || v_child, ''''),');
  if (length(v_new) - length(v_src)) < 400 or position('c.extras)' in v_new) = 0 or position('p_extras bigint[]' in v_new) = 0
     or position('s.duration_min' in v_new) > 0 or position('          s.price_cents, v_dep' in v_new) > 0 then
    raise exception 'create_booking mudou; ajuste a migração';
  end if;
  execute 'drop function public.create_booking(bigint, date, text, bigint, text, bigint)';
  execute v_new;

  -- nome combinado na agenda, Minha conta, Caixa e grade do painel
  select pg_get_functiondef(oid) into v_src from pg_proc where proname = '_booking_json' and pronamespace = 'public'::regnamespace;
  v_new := replace(v_src, '''service_name'', s.name, ''price_from'', s.price_from,',
    '''service_name'', _service_label(b), ''extra_service_ids'', b.extra_service_ids, ''price_from'', s.price_from or exists (select 1 from services x where x.id = any(b.extra_service_ids) and x.price_from),');
  if v_new = v_src then raise exception '_booking_json mudou'; end if;
  execute v_new;

  select pg_get_functiondef(oid) into v_src from pg_proc where proname = 'staff_cashbox' and pronamespace = 'public'::regnamespace;
  v_new := replace(v_src, 's.name || case when b.settled_at is not null', '_service_label(b) || case when b.settled_at is not null');
  if v_new = v_src then raise exception 'staff_cashbox mudou'; end if;
  execute v_new;

  select pg_get_functiondef(oid) into v_src from pg_proc where proname = 'staff_day_slots' and pronamespace = 'public'::regnamespace;
  v_new := replace(v_src, '''servico'', s.name,', '''servico'', s.name || coalesce((select string_agg('' + '' || x.name, '''') from services x where x.id = any(bk.extra_service_ids)), ''''),');
  if v_new = v_src then raise exception 'staff_day_slots mudou'; end if;
  execute v_new;
end $$;

revoke execute on function public.create_booking(bigint, date, text, bigint, text, bigint, bigint[]) from public, anon;
grant execute on function public.create_booking(bigint, date, text, bigint, text, bigint, bigint[]) to authenticated;

-- Confirmação lista os extras na ordem em que o cliente escolheu
do $$
declare v_src text; v_new text;
begin
  select pg_get_functiondef(oid) into v_src from pg_proc where proname = 'create_booking' and pronamespace = 'public'::regnamespace;
  v_new := replace(v_src, 'string_agg('' + '' || x.name, '''') from services x where x.id = any(c.extras)',
                          'string_agg('' + '' || x.name, '''' order by array_position(c.extras, x.id)) from services x where x.id = any(c.extras)');
  if v_new = v_src then raise exception 'create_booking mudou'; end if;
  execute v_new;
end $$;
