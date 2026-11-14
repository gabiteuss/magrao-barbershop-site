-- Comissões com senha para o admin e parte do barbeiro editável.
-- A senha guardada é só o hash (bcrypt), gravado direto no banco: nunca no repositório.

-- porcentagem congelada em cada atendimento: mudar a % não reescreve o que já foi concluído
alter table public.bookings add column if not exists commission_percent integer;

update public.bookings b set commission_percent = br.commission_percent
from public.barbers br
where br.id = b.barber_id and b.status = 'concluido' and b.commission_percent is null;

create or replace function public._freeze_commission()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'concluido' and new.commission_percent is null then
    select commission_percent into new.commission_percent from barbers where id = new.barber_id;
  end if;
  return new;
end $$;

create trigger freeze_commission before insert or update of status on public.bookings
  for each row execute function public._freeze_commission();

-- valor combinado por fora: troca a conta pela % naquele período
create table public.commission_overrides (
  id bigint generated always as identity primary key,
  barber_id bigint not null references public.barbers(id) on delete cascade,
  date_from date not null,
  date_to date not null,
  barber_cents integer not null check (barber_cents >= 0),
  created_at timestamptz not null default now(),
  check (date_to >= date_from),
  unique (barber_id, date_from, date_to)
);
alter table public.commission_overrides enable row level security;

create table public.commission_lock (
  id smallint primary key default 1 check (id = 1),
  pass_hash text,
  fails integer not null default 0,
  locked_until timestamptz,
  token_hash text,
  token_expires timestamptz
);
alter table public.commission_lock enable row level security;
insert into public.commission_lock (id) values (1);

-- quanto vai para o barbeiro: valor combinado que caiba no período + % dos atendimentos fora dele
create function public._barber_share(p_barber bigint, p_from date, p_to date)
returns integer language sql stable security definer set search_path = public as $$
  select (coalesce((
      select sum(round(_charged(b) * coalesce(b.commission_percent, br.commission_percent) / 100.0))
      from bookings b join barbers br on br.id = b.barber_id
      where b.barber_id = p_barber and b.status = 'concluido' and b.start_at::date between p_from and p_to
        and not exists (select 1 from commission_overrides o
                        where o.barber_id = p_barber and o.date_from >= p_from and o.date_to <= p_to
                          and b.start_at::date between o.date_from and o.date_to)), 0)
    + coalesce((select sum(o.barber_cents) from commission_overrides o
                where o.barber_id = p_barber and o.date_from >= p_from and o.date_to <= p_to), 0))::int
$$;
revoke all on function public._barber_share(bigint, date, date) from public, anon, authenticated;

-- senha certa devolve uma chave que vale 30 min; errar 5 vezes trava por 10 min
create function public.admin_commission_unlock(p_pass text)
returns json language plpgsql security definer set search_path = public as $$
declare
  r commission_lock;
  v_token text := gen_random_uuid()::text;
begin
  perform _require_admin();
  select * into r from commission_lock where id = 1 for update;
  if r.locked_until > now() then
    return json_build_object('ok', false, 'error', 'Muitas tentativas. Espere alguns minutos e tente de novo.');
  end if;
  if r.pass_hash is null or r.pass_hash <> extensions.crypt(coalesce(p_pass, ''), r.pass_hash) then
    update commission_lock set fails = case when r.fails >= 4 then 0 else r.fails + 1 end,
           locked_until = case when r.fails >= 4 then now() + interval '10 minutes' end where id = 1;
    return json_build_object('ok', false, 'error', 'Senha errada.');
  end if;
  update commission_lock set fails = 0, locked_until = null,
         token_hash = encode(sha256(convert_to(v_token, 'UTF8')), 'hex'),
         token_expires = now() + interval '30 minutes' where id = 1;
  return json_build_object('ok', true, 'token', v_token);
end $$;

create function public._require_commission_token(p_token text)
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if is_admin() and not exists (
      select 1 from commission_lock where id = 1 and token_expires > now()
        and token_hash = encode(sha256(convert_to(coalesce(p_token, ''), 'UTF8')), 'hex')) then
    raise exception 'Digite a senha das comissões.' using errcode = 'PT403';
  end if;
end $$;
revoke all on function public._require_commission_token(text) from public, anon, authenticated;

drop function public.admin_commissions(date, date);
create function public.admin_commissions(p_from date, p_to date, p_token text default null)
returns json language plpgsql stable security definer set search_path = public as $$
declare
  v_barber bigint := case when is_admin() then null else my_barber_id() end;
begin
  perform _require_staff();
  perform _require_commission_token(p_token);
  if p_to < p_from or p_to - p_from > 370 then
    raise exception 'Período inválido.' using errcode = 'PT400';
  end if;
  return (
    select coalesce(json_agg(x order by x.total_cents desc), '[]') from (
      select s.*, s.total_cents - s.barbeiro_cents as casa_cents from (
        select br.id as barber_id, br.name as barber_name, br.commission_percent,
               count(b.id) as atendimentos, count(b.id) filter (where b.walk_in) as encaixes,
               coalesce(sum(_charged(b)), 0)::int as total_cents,
               _barber_share(br.id, p_from, p_to) as barbeiro_cents,
               (select o.barber_cents from commission_overrides o
                where o.barber_id = br.id and o.date_from = p_from and o.date_to = p_to) as combinado_cents,
               exists (select 1 from commission_overrides o
                       where o.barber_id = br.id and o.date_from >= p_from and o.date_to <= p_to) as tem_combinado
        from barbers br
        left join bookings b on b.barber_id = br.id and b.status = 'concluido'
                            and b.start_at::date between p_from and p_to
        where v_barber is null or br.id = v_barber
        group by br.id) s
    ) x);
end $$;

drop function public.admin_payment_summary(date, date);
create function public.admin_payment_summary(p_from date, p_to date, p_token text default null)
returns json language plpgsql stable security definer set search_path = public as $$
begin
  perform _require_admin();
  perform _require_commission_token(p_token);
  if p_to < p_from or p_to - p_from > 370 then raise exception 'Período inválido.' using errcode = 'PT400'; end if;
  return json_build_object(
    'atendimentos', (select coalesce(json_agg(x), '[]') from (
        select coalesce(pay_method, 'nao_informado') as method, (online_paid_at is not null) as online,
               count(*) as qtd, coalesce(sum(_charged(b)), 0)::int as total_cents
        from bookings b where b.status = 'concluido' and b.start_at::date between p_from and p_to
        group by 1, 2 order by 4 desc) x),
    'pacotes', (select coalesce(json_agg(x), '[]') from (
        select pay_method as method, paid_online as online, count(*) as qtd, sum(price_cents)::int as total_cents
        from client_packages where status in ('ativo', 'cancelado') and paid_at is not null
          and (paid_at at time zone 'America/Sao_Paulo')::date between p_from and p_to
        group by 1, 2 order by 4 desc) x));
end $$;

-- nova % vale para os próximos atendimentos
create function public.admin_commission_percent(p_token text, p_barber bigint, p_percent integer)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _require_admin();
  perform _require_commission_token(p_token);
  if p_percent is null or p_percent not between 0 and 100 then
    raise exception 'Comissão precisa ser de 0 a 100%%.' using errcode = 'PT400';
  end if;
  update barbers set commission_percent = p_percent where id = p_barber;
end $$;

-- p_cents vazio volta para a conta pela %
create function public.admin_commission_value(p_token text, p_barber bigint, p_from date, p_to date, p_cents integer)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _require_admin();
  perform _require_commission_token(p_token);
  if p_to < p_from then raise exception 'Período inválido.' using errcode = 'PT400'; end if;
  delete from commission_overrides where barber_id = p_barber and date_from = p_from and date_to = p_to;
  if p_cents is null then return; end if;
  if p_cents < 0 then raise exception 'O valor não pode ser negativo.' using errcode = 'PT400'; end if;
  if exists (select 1 from commission_overrides where barber_id = p_barber and date_from <= p_to and date_to >= p_from) then
    raise exception 'Já existe valor combinado em parte desse período. Abra o período exato dele para mudar.' using errcode = 'PT400';
  end if;
  insert into commission_overrides (barber_id, date_from, date_to, barber_cents) values (p_barber, p_from, p_to, p_cents);
end $$;

-- o painel do barbeiro mostra o mesmo valor da aba Comissões
do $$
declare
  v_src text := pg_get_functiondef('public.barber_stats(bigint, date, date)'::regprocedure);
  v_new text := replace(v_src,
    $a$coalesce(sum(round(_charged(b) * br.commission_percent / 100.0)) filter (where b.status = 'concluido'), 0)::int$a$,
    $a$_barber_share(br.id, p_from, p_to)$a$);
begin
  if v_new = v_src then raise exception 'barber_stats mudou'; end if;
  execute v_new;
end $$;

revoke all on function public.admin_commissions(date, date, text) from public, anon;
revoke all on function public.admin_payment_summary(date, date, text) from public, anon;
revoke all on function public.admin_commission_unlock(text) from public, anon;
revoke all on function public.admin_commission_percent(text, bigint, integer) from public, anon;
revoke all on function public.admin_commission_value(text, bigint, date, date, integer) from public, anon;
grant execute on function public.admin_commissions(date, date, text) to authenticated;
grant execute on function public.admin_payment_summary(date, date, text) to authenticated;
grant execute on function public.admin_commission_unlock(text) to authenticated;
grant execute on function public.admin_commission_percent(text, bigint, integer) to authenticated;
grant execute on function public.admin_commission_value(text, bigint, date, date, integer) to authenticated;
