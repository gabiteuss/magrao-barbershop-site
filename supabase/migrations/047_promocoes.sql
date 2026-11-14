-- Promoções da página inicial editadas no painel (Serviços e preços)
create table if not exists public.promotions (
  id bigserial primary key,
  tag text not null default '',             -- etiqueta pequena, ex.: "Seg a Qua"
  title text not null,
  body text not null default '',
  from_cents integer,                       -- preço riscado (opcional)
  price_cents integer,                      -- preço da promoção (vazio = sem preço)
  service_id bigint references public.services(id) on delete set null,  -- serviço do cardápio (opcional)
  sort integer not null default 0,
  active boolean not null default true,     -- disponível (verde) ou indisponível (vermelho) para o cliente
  visible boolean not null default true,    -- aparece na página inicial
  created_at timestamptz not null default now()
);
alter table public.promotions enable row level security;  -- só pelas funções abaixo

-- As 3 que estavam fixas no site
insert into public.promotions (tag, title, body, from_cents, price_cents, sort)
select * from (values
  ('Seg a Qua', 'Degradê e Barba', 'Fuja da fila de quinta a sábado: o combo completo nos dias mais tranquilos.', 6000, 5500, 1),
  ('Indique', 'Traga um amigo', 'Indicou e ele cortou? O seu próximo pezinho sai de graça.', null, null, 2),
  ('Família', 'Pai e filho', 'Dois cortes no mesmo horário com desconto.', null, null, 3)
) v where not exists (select 1 from public.promotions);

create or replace function public.admin_promotions() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  perform _require_staff();
  return (select coalesce(json_agg(row_to_json(p) order by p.sort, p.id), '[]') from promotions p);
end $$;

create or replace function public.admin_save_promotion(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_title text := trim(coalesce(p->>'title', ''));
  v_from integer := nullif(p->>'from_cents', '')::int;
  v_price integer := nullif(p->>'price_cents', '')::int;
  v_svc bigint := nullif(p->>'service_id', '')::bigint;
begin
  perform _require_admin();
  if v_title = '' then raise exception 'Dê um título para a promoção.' using errcode = 'PT400'; end if;
  if v_price < 0 or v_from < 0 then raise exception 'Preço inválido.' using errcode = 'PT400'; end if;
  if v_price is null then v_from := null; end if;  -- preço riscado só faz sentido com preço
  if v_svc is not null and not exists (select 1 from services where id = v_svc) then
    raise exception 'Serviço não encontrado.' using errcode = 'PT400';
  end if;
  if p ? 'id' and p->>'id' is not null then
    update promotions set tag = left(trim(coalesce(p->>'tag', '')), 30), title = left(v_title, 60),
           body = left(trim(coalesce(p->>'body', '')), 240), from_cents = v_from, price_cents = v_price,
           service_id = v_svc, sort = coalesce((p->>'sort')::int, 0), active = coalesce((p->>'active')::boolean, true),
           visible = coalesce((p->>'visible')::boolean, true)
    where id = (p->>'id')::bigint;
  else
    insert into promotions (tag, title, body, from_cents, price_cents, service_id, sort, active, visible)
    values (left(trim(coalesce(p->>'tag', '')), 30), left(v_title, 60), left(trim(coalesce(p->>'body', '')), 240),
            v_from, v_price, v_svc, coalesce((p->>'sort')::int, 0), coalesce((p->>'active')::boolean, true),
            coalesce((p->>'visible')::boolean, true));
  end if;
end $$;

create or replace function public.admin_delete_promotion(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require_admin();
  delete from promotions where id = p_id;
end $$;

revoke execute on function public.admin_promotions(), public.admin_save_promotion(jsonb), public.admin_delete_promotion(bigint)
  from public, anon;
grant execute on function public.admin_promotions(), public.admin_save_promotion(jsonb), public.admin_delete_promotion(bigint)
  to authenticated;

-- Página inicial: as promoções visíveis, com a etiqueta de disponível/indisponível
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
    'promos', (select coalesce(json_agg(json_build_object('tag', p.tag, 'title', p.title, 'body', p.body,
                   'from_cents', p.from_cents, 'price_cents', p.price_cents, 'available', p.active,
                   'service', s.name) order by p.active desc, p.sort, p.id), '[]')
               from promotions p left join services s on s.id = p.service_id where p.visible),
    'packages', _catalog(),
    'settings', json_build_object('deposit_percent', setting('deposit_percent'), 'cancel_hours', setting('cancel_hours'),
                                  'hold_minutes', setting('hold_minutes'), 'days_ahead', setting('days_ahead'),
                                  'confirm_required', setting('confirm_required'), 'confirm_ask_minutes', setting('confirm_ask_minutes'),
                                  'confirm_deadline_minutes', setting('confirm_deadline_minutes'), 'online_pay', setting('online_pay')),
    'payment_provider', setting_text('payment_provider'))
$$;
