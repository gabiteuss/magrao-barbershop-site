-- Comissão por serviço passa a ser POR BARBEIRO: o administrador escolhe o barbeiro (igual à aba Equipe)
-- e define a % de cada serviço para ele. Vazio = a % geral do barbeiro (aba Comissões).
-- Substitui a % única por serviço da 048 (que ainda não tinha nenhum serviço configurado).

create table if not exists public.service_commissions (
  barber_id bigint not null references public.barbers(id) on delete cascade,
  service_id bigint not null references public.services(id) on delete cascade,
  percent integer not null check (percent between 0 and 100),
  primary key (barber_id, service_id)
);
alter table public.service_commissions enable row level security;  -- só pelas funções abaixo

-- leva o que estivesse na % única (para os barbeiros que não são o dono) e remove a coluna antiga
insert into public.service_commissions (barber_id, service_id, percent)
select b.id, s.id, s.commission_percent from public.services s cross join public.barbers b
where s.commission_percent is not null and b.commission_percent < 100
on conflict do nothing;

-- com vários serviços no mesmo horário, a % fica proporcional ao preço de cada um
create or replace function public._commission_for(b bookings) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select round(sum(s.price_cents * coalesce(sc.percent, br.commission_percent))::numeric / nullif(sum(s.price_cents), 0), 3)
     from services s left join service_commissions sc on sc.service_id = s.id and sc.barber_id = br.id
     where s.id = b.service_id or s.id = any(b.extra_service_ids)),
    (select round(avg(coalesce(sc.percent, br.commission_percent)), 3)
     from services s left join service_commissions sc on sc.service_id = s.id and sc.barber_id = br.id
     where s.id = b.service_id or s.id = any(b.extra_service_ids)),
    br.commission_percent)
  from barbers br where br.id = b.barber_id
$$;
revoke execute on function public._commission_for(bookings) from public, anon, authenticated;

drop function if exists public.admin_service_commission(text, bigint, integer);
alter table public.services drop column if exists commission_percent;

-- serviços com a % daquele barbeiro (null = segue a % geral dele)
create or replace function public.admin_service_commissions(p_token text, p_barber bigint) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  perform _require_admin();
  perform _require_commission_token(p_token);
  return json_build_object(
    'barber', (select json_build_object('id', id, 'name', name, 'commission_percent', commission_percent) from barbers where id = p_barber),
    'services', (select coalesce(json_agg(json_build_object('id', s.id, 'name', s.name, 'price_cents', s.price_cents,
                   'price_from', s.price_from, 'active', s.active, 'percent', sc.percent) order by s.sort, s.id), '[]')
                 from services s left join service_commissions sc on sc.service_id = s.id and sc.barber_id = p_barber));
end $$;

-- p_percent vazio = volta para a % geral do barbeiro; p_service vazio = todos os serviços
create or replace function public.admin_service_commission(p_token text, p_barber bigint, p_service bigint, p_percent integer)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _require_admin();
  perform _require_commission_token(p_token);
  if p_percent is not null and p_percent not between 0 and 100 then
    raise exception 'Comissão precisa ser de 0 a 100%%.' using errcode = 'PT400';
  end if;
  if not exists (select 1 from barbers where id = p_barber) then
    raise exception 'Barbeiro não encontrado.' using errcode = 'PT404';
  end if;
  if p_service is not null and not exists (select 1 from services where id = p_service) then
    raise exception 'Serviço não encontrado.' using errcode = 'PT404';
  end if;
  delete from service_commissions where barber_id = p_barber and (p_service is null or service_id = p_service);
  if p_percent is not null then
    insert into service_commissions (barber_id, service_id, percent)
    select p_barber, s.id, p_percent from services s where p_service is null or s.id = p_service;
  end if;
end $$;

-- a aba Comissões avisa quando o barbeiro tem serviço com % própria
do $$
declare v_src text; v_new text;
begin
  v_src := pg_get_functiondef('public.admin_commissions(date, date, text)'::regprocedure);
  v_new := replace(v_src, 'select br.id as barber_id, br.name as barber_name, br.commission_percent,',
    'select br.id as barber_id, br.name as barber_name, br.commission_percent,
               exists (select 1 from service_commissions sc where sc.barber_id = br.id) as tem_pct_servico,');
  if v_new = v_src then raise exception 'admin_commissions mudou'; end if;
  execute v_new;
end $$;

revoke all on function public.admin_service_commissions(text, bigint), public.admin_service_commission(text, bigint, bigint, integer)
  from public, anon;
grant execute on function public.admin_service_commissions(text, bigint), public.admin_service_commission(text, bigint, bigint, integer)
  to authenticated;
