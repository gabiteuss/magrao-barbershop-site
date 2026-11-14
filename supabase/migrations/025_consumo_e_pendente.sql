-- 1) Consumíveis (bebidas etc.): cadastrados no painel e lançados ao concluir o atendimento, somados ao corte.
--    Consumo vai todo para a casa (não entra na comissão).
-- 2) Pagamento pendente: ex.: o filho corta sozinho e o pai paga depois. O atendimento fica "pendente"
--    na conta do pai até alguém clicar em "Receber"; aí entra no Caixa no dia em que foi recebido.

-- ------------------------------------------------------------- tabelas
create table public.products (
  id          bigserial primary key,
  name        text not null check (length(trim(name)) between 2 and 60),
  price_cents integer not null check (price_cents between 0 and 1000000),
  sort        integer not null default 0,
  active      boolean not null default true
);
alter table public.products enable row level security;

create table public.booking_items (
  id          bigserial primary key,
  booking_id  bigint not null references public.bookings(id) on delete cascade,
  product_id  bigint references public.products(id) on delete set null,
  name        text not null,
  qty         integer not null check (qty between 1 and 50),
  unit_cents  integer not null check (unit_cents >= 0),
  pay_method  text not null check (pay_method in ('dinheiro', 'credito', 'debito', 'pix', 'pendente')),
  settled_at  timestamptz,
  created_at  timestamptz not null default now()
);
create index booking_items_booking on public.booking_items (booking_id);
alter table public.booking_items enable row level security;

alter table public.bookings drop constraint bookings_pay_method_check;
alter table public.bookings add constraint bookings_pay_method_check
  check (pay_method in ('dinheiro', 'credito', 'debito', 'pix', 'pacote', 'pendente'));
alter table public.bookings add column settled_at timestamptz;

-- Quanto falta pagar de um atendimento (serviço pendente + consumo pendente)
create or replace function public._pending_cents(p_booking bigint) returns integer
language sql stable security definer set search_path = public as $$
  select coalesce((select _charged(b) from bookings b where b.id = p_booking and b.status = 'concluido' and b.pay_method = 'pendente'), 0)
       + coalesce((select sum(qty * unit_cents) from booking_items i join bookings b on b.id = i.booking_id
                   where i.booking_id = p_booking and i.pay_method = 'pendente' and b.status = 'concluido'), 0)::int
$$;
revoke execute on function public._pending_cents(bigint) from public, anon, authenticated;

-- ------------------------------------------------------------- consumíveis (cadastro)
create or replace function public.admin_products() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  perform _require_staff();
  return (select coalesce(json_agg(row_to_json(p) order by p.sort, p.id), '[]') from products p);
end $$;

create or replace function public.admin_save_product(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require_admin();
  if p ? 'id' and p->>'id' is not null then
    update products set name = trim(p->>'name'), price_cents = (p->>'price_cents')::int,
           sort = coalesce((p->>'sort')::int, 0), active = coalesce((p->>'active')::boolean, true)
    where id = (p->>'id')::bigint;
  else
    insert into products (name, price_cents, sort, active)
    values (trim(p->>'name'), (p->>'price_cents')::int, coalesce((p->>'sort')::int, 0), coalesce((p->>'active')::boolean, true));
  end if;
end $$;

-- ------------------------------------------------------------- concluir com consumo e/ou pendente
drop function public.admin_set_status(bigint, text, boolean, integer, text);
create function public.admin_set_status(p_id bigint, p_status text, p_refund boolean default true,
                                        p_final_cents integer default null, p_pay_method text default null,
                                        p_items jsonb default null) returns json
language plpgsql security definer set search_path = public as $$
declare
  b bookings;
  it jsonb;
  pr products;
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
  if p_pay_method is not null and p_pay_method not in ('dinheiro', 'credito', 'debito', 'pix', 'pendente') then
    raise exception 'Forma de pagamento inválida.' using errcode = 'PT400';
  end if;
  if p_status = 'concluido' and jsonb_array_length(coalesce(p_items, '[]')) > 0 then
    if p_pay_method is null then raise exception 'Escolha como foi pago o consumo.' using errcode = 'PT400'; end if;
    for it in select * from jsonb_array_elements(p_items) loop
      select * into pr from products where id = (it->>'product_id')::bigint and active;
      if pr.id is null then raise exception 'Produto não encontrado.' using errcode = 'PT404'; end if;
      insert into booking_items (booking_id, product_id, name, qty, unit_cents, pay_method)
      values (p_id, pr.id, pr.name, greatest(1, least(50, coalesce((it->>'qty')::int, 1))), pr.price_cents, p_pay_method);
    end loop;
  end if;
  update bookings set status = p_status,
         final_price_cents = case when p_status = 'concluido' then coalesce(p_final_cents, final_price_cents) end,
         pay_method = case when p_status = 'concluido' and pay_method is null and online_paid_at is null then p_pay_method else pay_method end
  where id = p_id;
  return json_build_object('ok', true);
end $$;

-- Corrigir forma: vale também para "pendente" e corrige junto o consumo do atendimento
create or replace function public.staff_fix_pay_method(p_id bigint, p_method text) returns json
language plpgsql security definer set search_path = public as $$
declare
  b bookings;
begin
  select * into b from bookings where id = p_id;
  if b.id is null then raise exception 'Agendamento não encontrado.' using errcode = 'PT404'; end if;
  perform _staff_can(b.barber_id);
  if b.status <> 'concluido' then raise exception 'Só atendimentos concluídos.' using errcode = 'PT400'; end if;
  if coalesce(p_method, '') not in ('dinheiro', 'credito', 'debito', 'pix', 'pendente') then
    raise exception 'Forma de pagamento inválida.' using errcode = 'PT400';
  end if;
  if b.online_paid_at is null and b.pay_method is distinct from 'pacote' then
    update bookings set pay_method = p_method, settled_at = null where id = p_id;
  end if;
  update booking_items set pay_method = p_method, settled_at = null where booking_id = p_id;
  return json_build_object('ok', true);
end $$;

-- Receber um pendente: serviço e consumo pendentes passam para a forma escolhida, com a data de hoje
create or replace function public.staff_settle(p_id bigint, p_method text) returns json
language plpgsql security definer set search_path = public as $$
declare
  b bookings;
begin
  select * into b from bookings where id = p_id;
  if b.id is null then raise exception 'Agendamento não encontrado.' using errcode = 'PT404'; end if;
  perform _staff_can(b.barber_id);
  if coalesce(p_method, '') not in ('dinheiro', 'credito', 'debito', 'pix') then
    raise exception 'Forma de pagamento inválida.' using errcode = 'PT400';
  end if;
  if _pending_cents(p_id) = 0 then raise exception 'Nada pendente nesse atendimento.' using errcode = 'PT400'; end if;
  update bookings set pay_method = p_method, settled_at = now() where id = p_id and pay_method = 'pendente';
  update booking_items set pay_method = p_method, settled_at = now() where booking_id = p_id and pay_method = 'pendente';
  return json_build_object('ok', true);
end $$;

-- ------------------------------------------------------------- caixa (recebido no período + pendentes em aberto)
create or replace function public.staff_cashbox(p_from date, p_to date, p_barber bigint default null) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  v_barber bigint := case when is_admin() then p_barber else my_barber_id() end;
begin
  perform _require_admin();
  if p_to < p_from or p_to - p_from > 370 then raise exception 'Período inválido.' using errcode = 'PT400'; end if;
  return json_build_object(
    'entradas', (select coalesce(json_agg(x order by x.quando desc), '[]') from (
        -- serviço (no dia do corte, ou no dia em que o pendente foi recebido)
        select 'atendimento' as tipo, b.id, coalesce((b.settled_at at time zone 'America/Sao_Paulo'), b.start_at) as quando,
               coalesce((select name from children where id = b.child_id) || ' (filho de ' || p.name || ')', p.name) as cliente,
               s.name || case when b.settled_at is not null then ' · recebido depois (corte de ' || to_char(b.start_at, 'DD/MM') || ')' else '' end as item,
               br.name as barbeiro, coalesce(b.pay_method, 'nao_informado') as method, b.online_paid_at is not null as online, _charged(b) as total_cents
        from bookings b join profiles p on p.id = b.user_id join services s on s.id = b.service_id join barbers br on br.id = b.barber_id
        where b.status = 'concluido' and b.pay_method is distinct from 'pacote' and b.pay_method is distinct from 'pendente'
          and coalesce((b.settled_at at time zone 'America/Sao_Paulo')::date, b.start_at::date) between p_from and p_to
          and (v_barber is null or b.barber_id = v_barber)
        union all
        -- consumo
        select 'consumo', b.id, coalesce((min(i.settled_at) at time zone 'America/Sao_Paulo'), b.start_at),
               coalesce((select name from children where id = b.child_id) || ' (filho de ' || p.name || ')', p.name),
               string_agg(i.qty || 'x ' || i.name, ', ' order by i.id), br.name, i.pay_method, false, sum(i.qty * i.unit_cents)::int
        from booking_items i join bookings b on b.id = i.booking_id join profiles p on p.id = b.user_id join barbers br on br.id = b.barber_id
        where b.status = 'concluido' and i.pay_method <> 'pendente'
          and coalesce((i.settled_at at time zone 'America/Sao_Paulo')::date, b.start_at::date) between p_from and p_to
          and (v_barber is null or b.barber_id = v_barber)
        group by b.id, p.name, br.name, i.pay_method, (i.settled_at is not null)
        union all
        select 'pacote', c.id, (c.paid_at at time zone 'America/Sao_Paulo'), p.name, c.name, null,
               c.pay_method, c.paid_online, c.price_cents
        from client_packages c join profiles p on p.id = c.user_id
        where v_barber is null and c.status in ('ativo', 'cancelado') and c.paid_at is not null
          and (c.paid_at at time zone 'America/Sao_Paulo')::date between p_from and p_to) x),
    'cortes_pacote', (select count(*) from bookings b
        where b.status = 'concluido' and b.pay_method = 'pacote'
          and b.start_at::date between p_from and p_to and (v_barber is null or b.barber_id = v_barber)),
    -- tudo o que está em aberto, de qualquer data
    'pendentes', (select coalesce(json_agg(x order by x.quando), '[]') from (
        select b.id, b.start_at as quando, p.name as cliente, p.phone,
               (select name from children where id = b.child_id) as filho, s.name as servico, br.name as barbeiro,
               _pending_cents(b.id) as total_cents,
               (select string_agg(i.qty || 'x ' || i.name, ', ') from booking_items i where i.booking_id = b.id and i.pay_method = 'pendente') as consumo
        from bookings b join profiles p on p.id = b.user_id join services s on s.id = b.service_id join barbers br on br.id = b.barber_id
        where b.status = 'concluido' and _pending_cents(b.id) > 0 and (v_barber is null or b.barber_id = v_barber)) x));
end $$;

revoke execute on function public.admin_products(), public.admin_save_product(jsonb),
  public.admin_set_status(bigint, text, boolean, integer, text, jsonb), public.staff_settle(bigint, text) from public, anon;
grant execute on function public.admin_products(), public.admin_save_product(jsonb),
  public.admin_set_status(bigint, text, boolean, integer, text, jsonb), public.staff_settle(bigint, text) to authenticated;

-- ------------------------------------------------------------- consumo e pendente no agendamento
do $$
declare v_src text; v_new text;
begin
  select pg_get_functiondef(oid) into v_src from pg_proc where proname = '_booking_json' and pronamespace = 'public'::regnamespace;
  v_new := replace(v_src, '''child_id'', b.child_id,',
    '''child_id'', b.child_id,
    ''items'', (select coalesce(json_agg(json_build_object(''name'', i.name, ''qty'', i.qty, ''unit_cents'', i.unit_cents, ''pay_method'', i.pay_method) order by i.id), ''[]'') from booking_items i where i.booking_id = b.id),
    ''items_cents'', (select coalesce(sum(i.qty * i.unit_cents), 0) from booking_items i where i.booking_id = b.id),
    ''pending_cents'', _pending_cents(b.id),
    ''client_debt_cents'', case when p_staff then (select coalesce(sum(_pending_cents(x.id)), 0) from bookings x where x.user_id = b.user_id and x.status = ''concluido'') end,');
  if v_new = v_src then raise exception '_booking_json mudou; ajuste a migração'; end if;
  execute v_new;
end $$;

-- Comissão continua só sobre o serviço (consumo é da casa); pendente também conta, porque o corte foi feito.
