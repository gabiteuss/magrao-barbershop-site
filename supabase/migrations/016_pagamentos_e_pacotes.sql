-- Formas de pagamento (dinheiro, crédito, débito, Pix), pagamento online pela InfinitePay
-- (crédito em até 12x ou Pix, pelo link de pagamento dela) e pacotes/planos de cortes.
-- O site nunca vê dados de cartão: o cliente paga na página da InfinitePay.

-- ------------------------------------------------------------- tabelas
create table public.packages (
  id          bigint generated always as identity primary key,
  kind        text not null default 'pacote' check (kind in ('pacote', 'plano')),   -- plano = mensal
  name        text not null check (length(name) between 2 and 60),
  description text not null default '' check (length(description) <= 200),
  service_id  bigint not null references public.services(id),
  qty         integer not null check (qty between 1 and 30),
  price_cents integer not null check (price_cents between 100 and 1000000),
  valid_days  integer not null default 60 check (valid_days between 7 and 366),
  plan_link   text not null default '' check (plan_link = '' or plan_link ~ '^https://'), -- assinatura feita no app da InfinitePay
  active      boolean not null default true,
  sort        integer not null default 0
);

-- Cada compra vira uma linha (no plano mensal, uma linha por mês pago)
create table public.client_packages (
  id              bigint generated always as identity primary key,
  user_id         uuid not null references public.profiles(id) on delete cascade,
  package_id      bigint references public.packages(id) on delete set null,
  kind            text not null,
  name            text not null,
  service_id      bigint not null references public.services(id),
  qty             integer not null,
  price_cents     integer not null,
  valid_days      integer not null,
  status          text not null default 'pendente' check (status in ('pendente', 'ativo', 'cancelado')),
  valid_until     date,
  pay_method      text check (pay_method in ('dinheiro', 'credito', 'debito', 'pix')),
  paid_online     boolean not null default false,
  order_nsu       text unique,
  checkout_url    text,
  transaction_nsu text,
  receipt_url     text,
  paid_at         timestamptz,
  created_by      text not null default 'cliente' check (created_by in ('cliente', 'barbearia')),
  created_at      timestamptz not null default now()
);
create index client_packages_user on public.client_packages (user_id, status);

alter table public.bookings
  add column pay_choice        text not null default 'local' check (pay_choice in ('local', 'online', 'pacote')),
  add column pay_method        text check (pay_method in ('dinheiro', 'credito', 'debito', 'pix', 'pacote')),
  add column client_package_id bigint references public.client_packages(id) on delete set null,
  add column order_nsu         text unique,
  add column checkout_url      text,
  add column transaction_nsu   text,
  add column receipt_url       text,
  add column online_paid_at    timestamptz;
create index bookings_package on public.bookings (client_package_id) where client_package_id is not null;

alter table public.profiles add column pref_pay text check (pref_pay in ('dinheiro', 'credito', 'debito', 'pix'));

alter table public.packages        enable row level security;
alter table public.client_packages enable row level security;
revoke all on public.packages, public.client_packages from anon, authenticated;
grant all on public.packages, public.client_packages to service_role;
grant usage, select on all sequences in schema public to service_role;

insert into public.settings (key, value) values ('online_pay', '0') on conflict (key) do nothing;

-- ------------------------------------------------------------- auxiliares
-- Cortes já usados de um pacote (falta também gasta o corte; cancelado devolve)
create or replace function public._pkg_used(p_cp bigint) returns integer
language sql stable security definer set search_path = public as $$
  select count(*)::int from bookings where client_package_id = p_cp and status in ('confirmado', 'concluido', 'faltou')
$$;

create or replace function public._pkg_json(c client_packages, p_staff boolean default false) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'id', c.id, 'kind', c.kind, 'name', c.name, 'service_id', c.service_id,
    'service_name', (select name from services where id = c.service_id),
    'qty', c.qty, 'used', _pkg_used(c.id), 'left', greatest(0, c.qty - _pkg_used(c.id)),
    'price_cents', c.price_cents,
    'status', case when c.status = 'ativo' and c.valid_until < local_now()::date then 'vencido' else c.status end,
    'valid_until', c.valid_until, 'valid_until_fmt', to_char(c.valid_until, 'DD/MM/YYYY'),
    'pay_method', c.pay_method, 'paid_online', c.paid_online, 'receipt_url', c.receipt_url,
    'checkout_url', case when c.status = 'pendente' then c.checkout_url end,
    'plan_link', case when c.status = 'pendente' then (select nullif(plan_link, '') from packages where id = c.package_id) end,
    'created_at', c.created_at, 'created_by', c.created_by,
    'client_name', case when p_staff then (select name from profiles where id = c.user_id) end,
    'client_phone', case when p_staff then (select phone from profiles where id = c.user_id) end)
$$;

-- Pacote com saldo para o serviço naquele dia (o que vence primeiro é usado primeiro)
create or replace function public._usable_package(p_user uuid, p_service bigint, p_day date) returns bigint
language sql stable security definer set search_path = public as $$
  select c.id from client_packages c
  where c.user_id = p_user and c.status = 'ativo' and c.service_id = p_service
    and c.valid_until >= p_day and _pkg_used(c.id) < c.qty
  order by c.valid_until, c.id limit 1
$$;

create or replace function public._catalog(p_all boolean default false) returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('id', k.id, 'kind', k.kind, 'name', k.name, 'description', k.description,
           'service_id', k.service_id, 'service_name', s.name, 'qty', k.qty, 'price_cents', k.price_cents,
           'unit_cents', round(k.price_cents::numeric / k.qty)::int, 'valid_days', k.valid_days,
           'has_plan_link', k.plan_link <> '', 'plan_link', case when p_all then k.plan_link end,
           'active', k.active, 'sort', k.sort) order by k.sort, k.id), '[]')
  from packages k join services s on s.id = k.service_id
  where p_all or (k.active and s.active)
$$;

-- ------------------------------------------------------------- agendamento em JSON (com pagamento)
create or replace function public._booking_json(p_id bigint, p_staff boolean default false) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'id', b.id, 'status', b.status, 'start_at', b.start_at, 'end_at', b.end_at,
    'quando', fmt_quando(b.start_at), 'service_id', b.service_id, 'service_name', s.name, 'price_from', s.price_from,
    'barber_id', b.barber_id, 'barber_name', br.name,
    'price_cents', b.price_cents, 'deposit_cents', b.deposit_cents,
    'remaining_cents', case when b.pay_method = 'pacote' or b.online_paid_at is not null then 0 else b.price_cents - b.deposit_cents end,
    'final_price_cents', b.final_price_cents,
    'pay_choice', b.pay_choice, 'pay_method', b.pay_method, 'paid_online', b.online_paid_at is not null,
    'receipt_url', b.receipt_url, 'package_name', cp.name,
    'paid', b.paid_at is not null, 'refund_status', b.refund_status,
    'moved_by_shop', b.moved_by_shop, 'moved_from', case when b.moved_from is not null then fmt_quando(b.moved_from) end,
    'pix_code', case when b.status = 'pendente' then b.pix_code end,
    'pix_qr_base64', case when b.status = 'pendente' then b.pix_qr_base64 end,
    'hold_seconds_left', case when b.status = 'pendente' then greatest(0, extract(epoch from b.hold_expires_at - local_now())::int) else 0 end,
    'refund_if_cancel', _can_refund(b), 'cancel_hours', setting('cancel_hours'),
    'attendance_confirmed', b.attendance_confirmed_at is not null,
    'confirm_asked', b.confirm_asked_at is not null,
    'confirm_deadline', to_char(b.start_at - make_interval(mins => setting('confirm_deadline_minutes')), 'HH24:MI'),
    'client_name', case when p_staff then p.name end,
    'client_phone', case when p_staff then p.phone end,
    'client_has_login', case when p_staff then p.has_login end,
    'client_pref_pay', case when p_staff then p.pref_pay end,
    'created_by', case when p_staff then b.created_by end,
    'cancelled_by', b.cancelled_by)
  from bookings b join services s on s.id = b.service_id join barbers br on br.id = b.barber_id
  join profiles p on p.id = b.user_id
  left join client_packages cp on cp.id = b.client_package_id
  where b.id = p_id
$$;

-- ------------------------------------------------------------- agendar (cliente) com forma de pagamento
drop function public.create_booking(bigint, date, text, bigint);
create function public.create_booking(p_service bigint, p_date date, p_time text, p_barber bigint default null,
                                      p_pay text default 'local') returns json
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
begin
  if v_uid is null then
    raise exception 'Entre na sua conta para continuar.' using errcode = 'PT401';
  end if;
  select * into p from profiles where id = v_uid;
  select * into s from services where id = p_service and active;
  if s.id is null then
    raise exception 'Serviço não encontrado.' using errcode = 'PT404';
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
  if (select count(*) from bookings where user_id = v_uid and status = 'confirmado' and start_at > v_now) >= 3 then
    raise exception 'Você já tem 3 horários marcados. Cancele um para marcar outro.' using errcode = 'PT409';
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

  if exists (select 1 from bookings where user_id = v_uid and status = 'confirmado'
             and start_at < v_start + make_interval(mins => s.duration_min) and end_at > v_start) then
    raise exception 'Você já tem um horário marcado nesse período.' using errcode = 'PT409';
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
                        pay_choice, pay_method, client_package_id, final_price_cents)
  values (v_uid, v_barber, s.id, v_start, v_start + make_interval(mins => s.duration_min),
          case when v_dep = 0 then 'confirmado' else 'pendente' end,
          s.price_cents, v_dep, v_now + make_interval(mins => setting('hold_minutes')), v_now,
          p_pay, case when p_pay = 'pacote' then 'pacote' end, v_cp,
          (select round(price_cents::numeric / qty)::int from client_packages where id = v_cp))
  returning id into v_id;

  if v_dep = 0 then
    perform enqueue_message(p.phone, 'confirmacao', jsonb_build_array(first_name(p.name), s.name,
            (select name from barbers where id = v_barber), fmt_quando(v_start)));
  end if;

  update waitlist set status = 'atendido'
  where user_id = v_uid and date = p_date and status in ('aguardando', 'avisado');

  return _booking_json(v_id);
end $$;

-- ------------------------------------------------------------- agendar pelo balcão (pode usar o pacote do cliente)
drop function public.admin_create_booking(uuid, bigint, date, text, bigint, boolean);
create function public.admin_create_booking(p_user uuid, p_service bigint, p_date date, p_time text, p_barber bigint,
                                            p_force boolean default false, p_use_package boolean default false) returns json
language plpgsql security definer set search_path = public as $$
declare
  s services;
  p profiles;
  v_start timestamp;
  v_id bigint;
  v_cp bigint;
begin
  perform _staff_can(p_barber);
  select * into p from profiles where id = p_user;
  if p.id is null then raise exception 'Cliente não encontrado.' using errcode = 'PT404'; end if;
  select * into s from services where id = p_service and active;
  if s.id is null then raise exception 'Serviço não encontrado.' using errcode = 'PT404'; end if;
  if p_time !~ '^\d{2}:\d{2}$' then raise exception 'Horário inválido.' using errcode = 'PT400'; end if;
  v_start := p_date + p_time::time;
  if v_start <= local_now() then raise exception 'Escolha um horário no futuro.' using errcode = 'PT400'; end if;

  perform pg_advisory_xact_lock(hashtext('agenda'));
  if p_use_package then
    v_cp := _usable_package(p.id, s.id, p_date);
    if v_cp is null then raise exception 'O cliente não tem pacote com saldo para esse serviço nesse dia.' using errcode = 'PT409'; end if;
  end if;
  if p_force then
    if exists (select 1 from bookings x where x.barber_id = p_barber
                 and x.start_at < v_start + make_interval(mins => s.duration_min) and x.end_at > v_start
                 and (x.status = 'confirmado' or (x.status = 'pendente' and x.hold_expires_at > local_now())))
       or exists (select 1 from blocks k where k.barber_id = p_barber
                    and k.start_at < v_start + make_interval(mins => s.duration_min) and k.end_at > v_start) then
      raise exception 'Já tem cliente ou bloqueio nesse horário.' using errcode = 'PT409';
    end if;
  elsif not exists (select 1 from _free_slots(p_barber, p_date, s.duration_min, null, false) t where t = v_start) then
    raise exception 'Esse horário não está livre.' using errcode = 'PT409';
  end if;

  insert into bookings (user_id, barber_id, service_id, start_at, end_at, status, price_cents, deposit_cents, created_at, created_by,
                        pay_choice, pay_method, client_package_id, final_price_cents)
  values (p.id, p_barber, s.id, v_start, v_start + make_interval(mins => s.duration_min), 'confirmado',
          s.price_cents, 0, local_now(), 'barbearia',
          case when v_cp is null then 'local' else 'pacote' end, case when v_cp is not null then 'pacote' end, v_cp,
          (select round(price_cents::numeric / qty)::int from client_packages where id = v_cp))
  returning id into v_id;

  perform enqueue_message(p.phone, 'confirmacao', jsonb_build_array(first_name(p.name), s.name,
          (select name from barbers where id = p_barber), fmt_quando(v_start)));
  return _booking_json(v_id, true);
end $$;

-- ------------------------------------------------------------- concluir registrando como pagou
drop function public.admin_set_status(bigint, text, boolean, integer);
create function public.admin_set_status(p_id bigint, p_status text, p_refund boolean default true,
                                        p_final_cents integer default null, p_pay_method text default null) returns json
language plpgsql security definer set search_path = public as $$
declare
  b bookings;
begin
  select * into b from bookings where id = p_id;
  if b.id is null then raise exception 'Agendamento não encontrado.' using errcode = 'PT404'; end if;
  perform _staff_can(b.barber_id);
  if p_status = 'cancelado' then
    return _cancel(p_id, 'barbearia', p_refund);
  end if;
  if p_status not in ('concluido', 'faltou') then
    raise exception 'Status inválido.' using errcode = 'PT400';
  end if;
  if b.status <> 'confirmado' then
    raise exception 'Só agendamentos confirmados podem ser concluídos ou marcados como falta.' using errcode = 'PT400';
  end if;
  if p_final_cents is not null and (p_final_cents < 0 or p_final_cents > 1000000) then
    raise exception 'Valor inválido.' using errcode = 'PT400';
  end if;
  if p_pay_method is not null and p_pay_method not in ('dinheiro', 'credito', 'debito', 'pix') then
    raise exception 'Forma de pagamento inválida.' using errcode = 'PT400';
  end if;
  update bookings set status = p_status,
         final_price_cents = case when p_status = 'concluido' then coalesce(p_final_cents, final_price_cents) end,
         pay_method = case when p_status = 'concluido' and pay_method is null and online_paid_at is null then p_pay_method else pay_method end
  where id = p_id;
  return json_build_object('ok', true);
end $$;

-- ------------------------------------------------------------- pagamento online
-- Chamado pela função "pagar-online" com o token do cliente: prepara o pedido e devolve o que a InfinitePay precisa
create or replace function public.start_online_payment(p_booking bigint default null, p_package bigint default null) returns json
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  p profiles;
  b bookings;
  k packages;
  v_cp client_packages;
  v_nsu text;
begin
  if v_uid is null then raise exception 'Entre na sua conta para continuar.' using errcode = 'PT401'; end if;
  if setting('online_pay') <> 1 then raise exception 'Pagamento online ainda não está ligado.' using errcode = 'PT400'; end if;
  select * into p from profiles where id = v_uid;

  if p_booking is not null then
    select * into b from bookings where id = p_booking and user_id = v_uid for update;
    if b.id is null then raise exception 'Agendamento não encontrado.' using errcode = 'PT404'; end if;
    if b.status <> 'confirmado' or b.start_at <= local_now() then
      raise exception 'Esse horário não pode mais ser pago online.' using errcode = 'PT400';
    end if;
    if b.online_paid_at is not null or b.pay_method is not null then
      raise exception 'Esse horário já está pago.' using errcode = 'PT400';
    end if;
    if (select price_from from services where id = b.service_id) then
      raise exception 'Esse serviço tem valor "a partir de": o pagamento é feito na barbearia.' using errcode = 'PT400';
    end if;
    v_nsu := coalesce(b.order_nsu, 'ag' || b.id || '-' || encode(extensions.gen_random_bytes(6), 'hex'));
    update bookings set order_nsu = v_nsu, pay_choice = 'online' where id = b.id;
    return json_build_object('order_nsu', v_nsu, 'amount', b.price_cents,
      'description', (select name from services where id = b.service_id) || ' · ' || fmt_quando(b.start_at),
      'name', p.name, 'phone', p.phone, 'checkout_url', b.checkout_url);
  end if;

  select * into k from packages where id = p_package and active;
  if k.id is null then raise exception 'Pacote não encontrado.' using errcode = 'PT404'; end if;
  if (select count(*) from client_packages where user_id = v_uid and created_at > now() - interval '1 hour') >= 6 then
    raise exception 'Muitas tentativas. Espere alguns minutos.' using errcode = 'PT429';
  end if;
  -- reaproveita um pedido aberto do mesmo pacote
  select * into v_cp from client_packages
  where user_id = v_uid and package_id = k.id and status = 'pendente' and created_at > now() - interval '2 days'
  order by id desc limit 1;
  if v_cp.id is null then
    insert into client_packages (user_id, package_id, kind, name, service_id, qty, price_cents, valid_days, order_nsu)
    values (v_uid, k.id, k.kind, k.name, k.service_id, k.qty, k.price_cents,
            case when k.kind = 'plano' then 30 else k.valid_days end, 'pc' || encode(extensions.gen_random_bytes(8), 'hex'))
    returning * into v_cp;
  end if;
  return json_build_object('order_nsu', v_cp.order_nsu, 'amount', v_cp.price_cents,
    'description', v_cp.name || ' (' || v_cp.qty || 'x ' || (select name from services where id = v_cp.service_id) || ')',
    'name', p.name, 'phone', p.phone, 'checkout_url', v_cp.checkout_url,
    'plan_link', nullif(k.plan_link, ''));
end $$;

-- Chamado só pelo servidor depois de conferir na InfinitePay que o pagamento caiu
create or replace function public.online_mark_paid(p_order text, p_paid integer, p_method text, p_tx text, p_receipt text) returns json
language plpgsql security definer set search_path = public as $$
declare
  b bookings;
  c client_packages;
  v_method text := case when coalesce(p_method, '') ilike 'pix%' then 'pix' else 'credito' end;
  v_receipt text := case when p_receipt ~ '^https://' then left(p_receipt, 500) end;
begin
  select * into b from bookings where order_nsu = p_order for update;
  if b.id is not null then
    if b.online_paid_at is null then
      if coalesce(p_paid, 0) < b.price_cents then raise exception 'Valor pago menor que o cobrado.' using errcode = 'PT400'; end if;
      update bookings set online_paid_at = now(), pay_method = v_method, transaction_nsu = left(p_tx, 100), receipt_url = v_receipt
      where id = b.id;
    end if;
    return json_build_object('ok', true, 'kind', 'agendamento', 'id', b.id);
  end if;

  select * into c from client_packages where order_nsu = p_order for update;
  if c.id is null then raise exception 'Pedido não encontrado.' using errcode = 'PT404'; end if;
  if c.status = 'pendente' then
    if coalesce(p_paid, 0) < c.price_cents then raise exception 'Valor pago menor que o cobrado.' using errcode = 'PT400'; end if;
    update client_packages set status = 'ativo', paid_at = now(), paid_online = true, pay_method = v_method,
           transaction_nsu = left(p_tx, 100), receipt_url = v_receipt, valid_until = local_now()::date + c.valid_days
    where id = c.id;
  end if;
  return json_build_object('ok', true, 'kind', 'pacote', 'id', c.id);
end $$;

-- ------------------------------------------------------------- cliente
create or replace function public.my_packages() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'mine', (select coalesce(json_agg(_pkg_json(c) order by c.status = 'ativo' desc, c.valid_until desc nulls last, c.id desc), '[]')
             from client_packages c where c.user_id = auth.uid()
               and (c.status = 'ativo' or (c.status = 'pendente' and c.created_at > now() - interval '2 days'))
               and (c.valid_until is null or c.valid_until > local_now()::date - 60)),
    'catalog', _catalog(),
    'online_pay', setting('online_pay') = 1)
$$;

create or replace function public.set_my_pay_pref(p_pref text) returns json
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Entre na sua conta.' using errcode = 'PT401'; end if;
  if p_pref is not null and p_pref not in ('dinheiro', 'credito', 'debito', 'pix') then
    raise exception 'Forma de pagamento inválida.' using errcode = 'PT400';
  end if;
  update profiles set pref_pay = p_pref where id = auth.uid();
  return my_profile();
end $$;

create or replace function public.my_profile() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('id', p.id, 'name', p.name, 'phone', p.phone, 'email', u.email,
                           'role', p.role, 'barber_id', p.barber_id, 'birth_date', p.birth_date, 'pref_pay', p.pref_pay)
  from profiles p join auth.users u on u.id = p.id where p.id = auth.uid()
$$;

create or replace function public.public_info() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'services', (select coalesce(json_agg(json_build_object('id', id, 'name', name, 'description', description,
                   'price_cents', price_cents, 'price_from', price_from, 'duration_min', duration_min) order by sort, id), '[]')
                 from services where active),
    'barbers', (select coalesce(json_agg(json_build_object('id', id, 'name', name, 'title', title, 'bio', bio, 'photo', photo) order by id), '[]')
                from barbers where active),
    'hours', (select coalesce(json_agg(json_build_object('weekday', wd, 'open', to_char(o, 'HH24:MI'), 'close', to_char(c, 'HH24:MI')) order by wd), '[]')
              from (select w.weekday as wd, min(w.start_time) o, max(w.end_time) c
                    from working_hours w join barbers b on b.id = w.barber_id where b.active group by w.weekday) h),
    'packages', _catalog(),
    'settings', json_build_object('deposit_percent', setting('deposit_percent'), 'cancel_hours', setting('cancel_hours'),
                                  'hold_minutes', setting('hold_minutes'), 'days_ahead', setting('days_ahead'),
                                  'confirm_required', setting('confirm_required'), 'confirm_ask_minutes', setting('confirm_ask_minutes'),
                                  'confirm_deadline_minutes', setting('confirm_deadline_minutes'), 'online_pay', setting('online_pay')),
    'payment_provider', setting_text('payment_provider'))
$$;

-- ------------------------------------------------------------- equipe
create or replace function public.admin_packages() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  perform _require_staff();
  return _catalog(true);
end $$;

create or replace function public.admin_save_package(p jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare
  v_id bigint := nullif(p->>'id', '')::bigint;
begin
  perform _require_admin();
  if not exists (select 1 from services where id = (p->>'service_id')::bigint) then
    raise exception 'Escolha o serviço do pacote.' using errcode = 'PT400';
  end if;
  if v_id is null then
    insert into packages (kind, name, description, service_id, qty, price_cents, valid_days, plan_link, active, sort)
    values (coalesce(p->>'kind', 'pacote'), trim(p->>'name'), coalesce(trim(p->>'description'), ''), (p->>'service_id')::bigint,
            (p->>'qty')::int, (p->>'price_cents')::int, coalesce((p->>'valid_days')::int, 60), coalesce(trim(p->>'plan_link'), ''),
            coalesce((p->>'active')::boolean, true), coalesce((p->>'sort')::int, 0));
  else
    update packages set kind = coalesce(p->>'kind', kind), name = trim(p->>'name'), description = coalesce(trim(p->>'description'), ''),
           service_id = (p->>'service_id')::bigint, qty = (p->>'qty')::int, price_cents = (p->>'price_cents')::int,
           valid_days = coalesce((p->>'valid_days')::int, valid_days), plan_link = coalesce(trim(p->>'plan_link'), ''),
           active = coalesce((p->>'active')::boolean, active), sort = coalesce((p->>'sort')::int, sort)
    where id = v_id;
  end if;
  return _catalog(true);
exception when check_violation or not_null_violation or invalid_text_representation then
  raise exception 'Confira os dados do pacote: nome, quantidade (1 a 30), preço e link (https://).' using errcode = 'PT400';
end $$;

-- Pacotes dos clientes (ativos, pedidos esperando e vencidos recentes)
create or replace function public.admin_client_packages(p_q text default '') returns json
language plpgsql stable security definer set search_path = public as $$
declare
  v_digits text := regexp_replace(coalesce(p_q, ''), '\D', '', 'g');
begin
  perform _require_staff();
  return (select coalesce(json_agg(_pkg_json(c, true) order by c.status = 'pendente' desc, c.valid_until nulls first, c.id desc), '[]')
          from client_packages c
          where c.id in (select x.id from client_packages x join profiles pr on pr.id = x.user_id
                where x.status in ('ativo', 'pendente') and (x.valid_until is null or x.valid_until > local_now()::date - 30)
                  and (x.status = 'ativo' or x.created_at > now() - interval '7 days')
                  and (coalesce(p_q, '') = '' or pr.name ilike '%' || trim(p_q) || '%'
                       or (length(v_digits) >= 4 and pr.phone like '%' || v_digits || '%'))
                order by x.id desc limit 200));
end $$;

-- Venda no balcão (ou renovação do mês do plano): já fica ativo
create or replace function public.admin_sell_package(p_user uuid, p_package bigint, p_method text) returns json
language plpgsql security definer set search_path = public as $$
declare
  k packages;
  v_start date;
  v_id bigint;
begin
  perform _require_staff();
  if coalesce(p_method, '') not in ('dinheiro', 'credito', 'debito', 'pix') then
    raise exception 'Escolha como o cliente pagou.' using errcode = 'PT400';
  end if;
  select * into k from packages where id = p_package;
  if k.id is null then raise exception 'Pacote não encontrado.' using errcode = 'PT404'; end if;
  if not exists (select 1 from profiles where id = p_user) then raise exception 'Cliente não encontrado.' using errcode = 'PT404'; end if;
  -- plano: o mês novo começa quando o atual termina
  v_start := greatest(local_now()::date, coalesce((select max(valid_until) from client_packages
              where user_id = p_user and package_id = k.id and status = 'ativo' and k.kind = 'plano'), local_now()::date));
  insert into client_packages (user_id, package_id, kind, name, service_id, qty, price_cents, valid_days, status,
                               valid_until, pay_method, paid_at, created_by)
  values (p_user, k.id, k.kind, k.name, k.service_id, k.qty, k.price_cents, case when k.kind = 'plano' then 30 else k.valid_days end,
          'ativo', v_start + case when k.kind = 'plano' then 30 else k.valid_days end, p_method, now(), 'barbearia')
  returning id into v_id;
  return (select _pkg_json(c, true) from client_packages c where c.id = v_id);
end $$;

-- Pedido feito pelo site e pago fora (ex.: assinatura no app da InfinitePay): a equipe ativa
create or replace function public.admin_activate_package(p_id bigint, p_method text) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform _require_staff();
  if coalesce(p_method, '') not in ('dinheiro', 'credito', 'debito', 'pix') then
    raise exception 'Escolha como o cliente pagou.' using errcode = 'PT400';
  end if;
  update client_packages set status = 'ativo', pay_method = p_method, paid_at = now(),
         valid_until = local_now()::date + valid_days
  where id = p_id and status = 'pendente';
  if not found then raise exception 'Esse pedido não está esperando pagamento.' using errcode = 'PT400'; end if;
  return (select _pkg_json(c, true) from client_packages c where c.id = p_id);
end $$;

create or replace function public.admin_cancel_package(p_id bigint) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform _require_admin();
  update client_packages set status = 'cancelado' where id = p_id and status in ('pendente', 'ativo');
  update bookings set client_package_id = null, pay_method = null, pay_choice = 'local', final_price_cents = null
  where client_package_id = p_id and status = 'confirmado';
  return json_build_object('ok', true);
end $$;

-- Quanto entrou em cada forma de pagamento (atendimentos concluídos + pacotes vendidos)
create or replace function public.admin_payment_summary(p_from date, p_to date) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  v_barber bigint := case when is_admin() then null else my_barber_id() end;
begin
  perform _require_staff();
  if p_to < p_from or p_to - p_from > 370 then raise exception 'Período inválido.' using errcode = 'PT400'; end if;
  return json_build_object(
    'atendimentos', (select coalesce(json_agg(x), '[]') from (
        select coalesce(pay_method, 'nao_informado') as method, (online_paid_at is not null) as online,
               count(*) as qtd, coalesce(sum(_charged(b)), 0)::int as total_cents
        from bookings b where b.status = 'concluido' and b.start_at::date between p_from and p_to
          and (v_barber is null or b.barber_id = v_barber)
        group by 1, 2 order by 4 desc) x),
    'pacotes', case when v_barber is null then (select coalesce(json_agg(x), '[]') from (
        select pay_method as method, paid_online as online, count(*) as qtd, sum(price_cents)::int as total_cents
        from client_packages where status in ('ativo', 'cancelado') and paid_at is not null
          and (paid_at at time zone 'America/Sao_Paulo')::date between p_from and p_to
        group by 1, 2 order by 4 desc) x) else '[]'::json end);
end $$;

create or replace function public.admin_clients(p_q text default '') returns json
language plpgsql stable security definer set search_path = public as $$
begin
  perform _require_admin();
  return (select coalesce(json_agg(x order by x.created_at desc), '[]') from (
    select p.id, p.name, p.phone, u.email, p.role, p.barber_id, p.created_at, p.has_login, p.pref_pay,
           (select count(*) from bookings b where b.user_id = p.id and b.status = 'concluido') as cortes,
           (select count(*) from bookings b where b.user_id = p.id and b.status = 'faltou') as faltas,
           (select coalesce(sum(greatest(0, c.qty - _pkg_used(c.id))), 0) from client_packages c
             where c.user_id = p.id and c.status = 'ativo' and c.valid_until >= local_now()::date) as cortes_pacote
    from profiles p left join auth.users u on u.id = p.id
    where p_q = '' or p.name ilike '%' || p_q || '%'
       or (regexp_replace(p_q, '\D', '', 'g') <> '' and p.phone like '%' || regexp_replace(p_q, '\D', '', 'g') || '%')
    order by p.created_at desc limit 100) x);
end $$;

-- Configuração: liga/desliga o pagamento online
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
                            'confirm_required', 'confirm_ask_minutes', 'confirm_deadline_minutes', 'birthday_enabled', 'online_pay');
    v := (p->>k)::integer;
    if k = 'slot_step_min' and (v < 10 or v > 120 or v % 5 <> 0) then
      raise exception 'O tempo de cada horário precisa ser de 10 a 120 minutos.' using errcode = 'PT400';
    end if;
    if v < 0 or (k = 'deposit_percent' and v > 100) or (k = 'hold_minutes' and v < 5)
       or (k in ('confirm_required', 'birthday_enabled', 'online_pay') and v not in (0, 1)) or (k = 'confirm_deadline_minutes' and v < 5) then
      raise exception 'Valor inválido para %', k using errcode = 'PT400';
    end if;
    update settings set value = v::text where key = k;
  end loop;
  if setting('confirm_ask_minutes') <= setting('confirm_deadline_minutes') + 15 then
    raise exception 'O pedido de confirmação precisa sair pelo menos 15 minutos antes do prazo.' using errcode = 'PT400';
  end if;
  return admin_get_config();
end $$;

-- ------------------------------------------------------------- permissões
revoke execute on function public._pkg_used(bigint), public._pkg_json(client_packages, boolean), public._usable_package(uuid, bigint, date),
  public._catalog(boolean), public.online_mark_paid(text, integer, text, text, text) from public, anon, authenticated;
grant execute on function public.online_mark_paid(text, integer, text, text, text) to service_role;
revoke execute on function public.create_booking(bigint, date, text, bigint, text),
  public.admin_create_booking(uuid, bigint, date, text, bigint, boolean, boolean),
  public.admin_set_status(bigint, text, boolean, integer, text), public.start_online_payment(bigint, bigint),
  public.my_packages(), public.set_my_pay_pref(text), public.admin_packages(), public.admin_save_package(jsonb),
  public.admin_client_packages(text), public.admin_sell_package(uuid, bigint, text), public.admin_activate_package(bigint, text),
  public.admin_cancel_package(bigint), public.admin_payment_summary(date, date) from public, anon;
grant execute on function public.create_booking(bigint, date, text, bigint, text),
  public.admin_create_booking(uuid, bigint, date, text, bigint, boolean, boolean),
  public.admin_set_status(bigint, text, boolean, integer, text), public.start_online_payment(bigint, bigint),
  public.my_packages(), public.set_my_pay_pref(text), public.admin_packages(), public.admin_save_package(jsonb),
  public.admin_client_packages(text), public.admin_sell_package(uuid, bigint, text), public.admin_activate_package(bigint, text),
  public.admin_cancel_package(bigint), public.admin_payment_summary(date, date) to authenticated;
