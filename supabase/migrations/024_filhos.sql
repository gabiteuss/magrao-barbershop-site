-- Filhos no cadastro: o pai marca o horário do filho na mesma conta e o site sugere
-- o horário livre mais perto do corte dele (mesmo barbeiro antes/depois ou outro barbeiro na mesma hora).
create table public.children (
  id         bigserial primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  name       text not null check (length(trim(name)) between 2 and 60),
  active     boolean not null default true,
  created_at timestamptz not null default now()
);
create index children_user on public.children (user_id) where active;
alter table public.children enable row level security;  -- só pelas funções abaixo

alter table public.bookings add column child_id bigint references public.children(id) on delete set null;

-- ------------------------------------------------------------- cadastro dos filhos (cliente)
create or replace function public.my_children() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('id', id, 'name', name) order by id), '[]')
  from children where user_id = auth.uid() and active
$$;

create or replace function public.save_my_child(p_id bigint, p_name text) returns json
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_name text := initcap(trim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g')));
begin
  if v_uid is null then raise exception 'Entre na sua conta.' using errcode = 'PT401'; end if;
  if length(v_name) not between 2 and 60 then raise exception 'Digite o nome do filho.' using errcode = 'PT400'; end if;
  if p_id is null then
    if (select count(*) from children where user_id = v_uid and active) >= 6 then
      raise exception 'Limite de 6 filhos no cadastro.' using errcode = 'PT400';
    end if;
    insert into children (user_id, name) values (v_uid, v_name);
  else
    update children set name = v_name where id = p_id and user_id = v_uid and active;
  end if;
  return my_children();
end $$;

create or replace function public.remove_my_child(p_id bigint) returns json
language plpgsql security definer set search_path = public as $$
begin
  update children set active = false where id = p_id and user_id = auth.uid();
  return my_children();
end $$;

-- ------------------------------------------------------------- sugestão de horário para o filho
-- Horários livres do dia do corte do pai, do mais perto para o mais longe:
-- mesmo barbeiro logo depois/antes ou outro barbeiro no mesmo horário.
create or replace function public.child_suggestions(p_booking bigint, p_service bigint) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  b bookings;
  v_dur integer;
begin
  select * into b from bookings where id = p_booking and user_id = auth.uid() and status in ('confirmado', 'pendente');
  if b.id is null then raise exception 'Agendamento não encontrado.' using errcode = 'PT404'; end if;
  select duration_min into v_dur from services where id = p_service and active;
  if v_dur is null then raise exception 'Serviço não encontrado.' using errcode = 'PT404'; end if;
  return (select coalesce(json_agg(x order by x.dist, x.same desc, x.slot), '[]') from (
    select to_char(t, 'HH24:MI') as time, to_char(t, 'YYYY-MM-DD') as date, br.id as barber_id, br.name as barber_name,
           br.id = b.barber_id as same, t as slot,
           case when br.id = b.barber_id
                then least(abs(extract(epoch from t - b.end_at)), abs(extract(epoch from t + make_interval(mins => v_dur) - b.start_at)))
                else abs(extract(epoch from t - b.start_at)) end / 60 as dist
    from barbers br, lateral _free_slots(br.id, b.start_at::date, v_dur) t
    where br.active
    order by 7, 5 desc limit 4) x);
end $$;

-- ------------------------------------------------------------- agendar (com filho opcional)
drop function public.create_booking(bigint, date, text, bigint, text);
create function public.create_booking(p_service bigint, p_date date, p_time text, p_barber bigint default null,
                                      p_pay text default 'local', p_child bigint default null) returns json
language plpgsql security definer set search_path = public as $$
declare
  v_uid    uuid := auth.uid();
  v_now    timestamp := local_now();
  s        services;
  v_start  timestamp;
  v_barber bigint;
  v_locked bigint;
  v_id     bigint;
  v_dep    integer;
  v_cp     bigint;
  cand     bigint;
  p        profiles;
  v_child  text;
begin
  if v_uid is null then
    raise exception 'Entre na sua conta para continuar.' using errcode = 'PT401';
  end if;
  select * into p from profiles where id = v_uid;
  select * into s from services where id = p_service and active;
  if s.id is null then
    raise exception 'Serviço não encontrado.' using errcode = 'PT404';
  end if;
  if p_child is not null then
    select name into v_child from children where id = p_child and user_id = v_uid and active;
    if v_child is null then raise exception 'Filho não encontrado no cadastro.' using errcode = 'PT404'; end if;
  end if;
  if p_time !~ '^\d{2}:\d{2}$' then
    raise exception 'Horário inválido.' using errcode = 'PT400';
  end if;
  if coalesce(p_pay, '') not in ('local', 'online', 'pacote') then
    raise exception 'Forma de pagamento inválida.' using errcode = 'PT400';
  end if;
  if p_pay = 'online' and (setting('online_pay') <> 1 or s.price_from) then
    raise exception 'Pagamento online indisponível para esse serviço. Escolha pagar na barbearia.' using errcode = 'PT400';
  end if;
  v_start := p_date + p_time::time;

  if (select count(*) from bookings where user_id = v_uid and created_at > v_now - interval '1 hour') >= 8 then
    raise exception 'Muitas tentativas. Espere alguns minutos.' using errcode = 'PT429';
  end if;
  -- Limite de 3 horários por pessoa (o pai e cada filho contam separado)
  if (select count(*) from bookings where user_id = v_uid and status = 'confirmado' and start_at > v_now
        and child_id is not distinct from p_child) >= 3 then
    raise exception 'Já são 3 horários marcados para %. Cancele um para marcar outro.',
      coalesce(v_child, 'você') using errcode = 'PT409';
  end if;

  perform pg_advisory_xact_lock(hashtext('agenda'));

  update bookings set status = 'cancelado', cancelled_at = now(), cancelled_by = 'cliente'
  where user_id = v_uid and status = 'pendente';

  if p_pay = 'pacote' then
    v_cp := _usable_package(v_uid, s.id, p_date);
    if v_cp is null then
      raise exception 'Você não tem pacote com saldo para esse serviço nesse dia.' using errcode = 'PT409';
    end if;
  end if;

  v_locked := _client_barber(v_uid);
  if v_locked is not null and p_barber is not null and p_barber <> v_locked then
    raise exception 'Você já tem horário marcado com %. Novos horários ficam com ele até lá (ou cancele o atual).',
      (select name from barbers where id = v_locked) using errcode = 'PT409';
  end if;

  -- A mesma pessoa não fica em duas cadeiras ao mesmo tempo (pai e filho podem)
  if exists (select 1 from bookings where user_id = v_uid and status = 'confirmado' and child_id is not distinct from p_child
             and start_at < v_start + make_interval(mins => s.duration_min) and end_at > v_start) then
    raise exception '% já tem um horário marcado nesse período.', coalesce(v_child, 'Você') using errcode = 'PT409';
  end if;

  for cand in select id from barbers
              where active and (coalesce(p_barber, v_locked) is null or id = coalesce(p_barber, v_locked)) order by id loop
    if exists (select 1 from _free_slots(cand, p_date, s.duration_min) t where t = v_start) then
      v_barber := cand;
      exit;
    end if;
  end loop;
  if v_barber is null then
    raise exception 'Esse horário acabou de ser ocupado. Escolha outro.' using errcode = 'PT409';
  end if;

  v_dep := case when p_pay = 'local' then round(s.price_cents * setting('deposit_percent') / 100.0) else 0 end;
  insert into bookings (user_id, barber_id, service_id, start_at, end_at, status, price_cents, deposit_cents, hold_expires_at, created_at,
                        pay_choice, pay_method, client_package_id, final_price_cents, child_id)
  values (v_uid, v_barber, s.id, v_start, v_start + make_interval(mins => s.duration_min),
          case when v_dep = 0 then 'confirmado' else 'pendente' end,
          s.price_cents, v_dep, v_now + make_interval(mins => setting('hold_minutes')), v_now,
          p_pay, case when p_pay = 'pacote' then 'pacote' end, v_cp,
          (select round(price_cents::numeric / qty)::int from client_packages where id = v_cp), p_child)
  returning id into v_id;

  if v_dep = 0 then
    perform enqueue_message(p.phone, 'confirmacao', jsonb_build_array(first_name(p.name),
            s.name || coalesce(' para ' || v_child, ''),
            (select name from barbers where id = v_barber), fmt_quando(v_start)));
  end if;

  update waitlist set status = 'atendido'
  where user_id = v_uid and date = p_date and status in ('aguardando', 'avisado');

  return _booking_json(v_id);
end $$;

revoke execute on function public.my_children(), public.save_my_child(bigint, text), public.remove_my_child(bigint),
  public.child_suggestions(bigint, bigint), public.create_booking(bigint, date, text, bigint, text, bigint) from public, anon;
grant execute on function public.my_children(), public.save_my_child(bigint, text), public.remove_my_child(bigint),
  public.child_suggestions(bigint, bigint), public.create_booking(bigint, date, text, bigint, text, bigint) to authenticated;

-- ------------------------------------------------------------- nome do filho no agendamento, agenda e lembrete
do $$
declare v_src text; v_new text;
begin
  -- _booking_json: child_name para o cliente e para a equipe
  select pg_get_functiondef(oid) into v_src from pg_proc where proname = '_booking_json' and pronamespace = 'public'::regnamespace;
  v_new := replace(v_src, '''cancelled_by'', b.cancelled_by)',
                   '''cancelled_by'', b.cancelled_by, ''child_id'', b.child_id, ''child_name'', (select name from children where id = b.child_id))');
  if v_new = v_src then raise exception '_booking_json mudou; ajuste a migração'; end if;
  execute v_new;

  -- Lembrete: "hoje às 10:40 (de Pedro) com Pablo"
  select pg_get_functiondef(oid) into v_src from pg_proc where proname = 'tick' and pronamespace = 'public'::regnamespace;
  v_new := replace(replace(v_src,
    'select b.id, b.start_at, b.created_at, p.name, p.phone, br.name as barber',
    'select b.id, b.start_at, b.created_at, b.child_id, p.name, p.phone, br.name as barber'),
    'to_char(r.start_at, ''HH24:MI''), r.barber)',
    'to_char(r.start_at, ''HH24:MI'') || coalesce('' (de '' || (select name from children where id = r.child_id) || '')'', ''''), r.barber)');
  if v_new = v_src or position('b.child_id, p.name' in v_new) = 0 then raise exception 'tick mudou; ajuste a migração'; end if;
  execute v_new;
end $$;

-- Caixa: "Pedro (filho de João)"
do $$
declare v_src text; v_new text;
begin
  select pg_get_functiondef(oid) into v_src from pg_proc where proname = 'staff_cashbox' and pronamespace = 'public'::regnamespace;
  v_new := replace(v_src, 'b.start_at as quando, p.name as cliente',
    'b.start_at as quando, coalesce((select name from children where id = b.child_id) || '' (filho de '' || p.name || '')'', p.name) as cliente');
  if v_new = v_src then raise exception 'staff_cashbox mudou'; end if;
  execute v_new;
end $$;
