-- 1) Encaixe / atendimento de balcão: o barbeiro registra um corte que já fez (ou está fazendo), mesmo fora
--    do horário ou em cima de outro, com serviço, hora que chegou, barbeiro, valor e forma de pagamento.
--    Entra direto como concluído: vai para Comissões, Caixa e o resumo do dia.
--    Cliente sem cadastro: basta o nome (fica num cadastro "Cliente avulso" e o nome vai no atendimento);
--    com telefone, o cliente é cadastrado.
-- 2) Notas: bloco de notas de cada pessoa da equipe, salvo no banco.

alter table public.bookings add column if not exists walk_in boolean not null default false;
alter table public.bookings add column if not exists walkin_name text;

-- Cadastro único para quem não deixou telefone
insert into public.profiles (id, name, phone, has_login)
select gen_random_uuid(), 'Cliente avulso', '5500000000000', false
where not exists (select 1 from public.profiles where phone = '5500000000000');

create or replace function public.staff_walkin(p_barber bigint, p_service bigint, p_date date, p_time text, p_price_cents integer,
                                               p_pay_method text, p_user uuid default null, p_name text default null,
                                               p_phone text default null, p_items jsonb default null) returns json
language plpgsql security definer set search_path = public as $$
declare
  s services;
  v_user uuid := p_user;
  v_name text := nullif(left(trim(coalesce(p_name, '')), 80), '');
  v_start timestamp;
  v_id bigint;
  it jsonb;
  pr products;
begin
  perform _staff_can(p_barber);
  select * into s from services where id = p_service;
  if s.id is null then raise exception 'Serviço não encontrado.' using errcode = 'PT404'; end if;
  if p_time !~ '^\d{1,2}:\d{2}$' then raise exception 'Hora inválida.' using errcode = 'PT400'; end if;
  if p_date > local_now()::date or p_date < local_now()::date - 7 then
    raise exception 'O encaixe vale para hoje ou até 7 dias atrás.' using errcode = 'PT400';
  end if;
  if p_price_cents is null or p_price_cents < 0 or p_price_cents > 1000000 then raise exception 'Valor inválido.' using errcode = 'PT400'; end if;
  if coalesce(p_pay_method, '') not in ('dinheiro', 'credito', 'debito', 'pix', 'pendente') then
    raise exception 'Escolha a forma de pagamento.' using errcode = 'PT400';
  end if;

  if v_user is null then
    if nullif(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), '') is not null then
      v_user := (admin_create_client(coalesce(v_name, ''), p_phone, null)->>'id')::uuid;
      v_name := null;  -- cliente cadastrado: o nome já está no cadastro
    else
      if v_name is null or length(v_name) < 2 then raise exception 'Digite o nome do cliente.' using errcode = 'PT400'; end if;
      if p_pay_method = 'pendente' then
        raise exception 'Pendente só para cliente com cadastro (telefone): é na conta dele que fica.' using errcode = 'PT400';
      end if;
      select id into v_user from profiles where phone = '5500000000000';
    end if;
  else
    v_name := null;
    if not exists (select 1 from profiles where id = v_user) then raise exception 'Cliente não encontrado.' using errcode = 'PT404'; end if;
  end if;

  v_start := p_date + p_time::time;
  insert into bookings (user_id, barber_id, service_id, start_at, end_at, status, price_cents, deposit_cents, created_at, created_by,
                        pay_choice, pay_method, final_price_cents, walk_in, walkin_name, attendance_confirmed_at, reminder_sent_at)
  values (v_user, p_barber, s.id, v_start, v_start + make_interval(mins => s.duration_min), 'concluido', s.price_cents, 0,
          local_now(), 'barbearia', 'local', p_pay_method, p_price_cents, true, v_name, now(), now())
  returning id into v_id;

  for it in select * from jsonb_array_elements(coalesce(p_items, '[]')) loop
    select * into pr from products where id = (it->>'product_id')::bigint and active;
    if pr.id is not null then
      insert into booking_items (booking_id, product_id, name, qty, unit_cents, pay_method)
      values (v_id, pr.id, pr.name, greatest(1, least(50, coalesce((it->>'qty')::int, 1))), pr.price_cents, p_pay_method);
    end if;
  end loop;

  return _booking_json(v_id, true);
end $$;

revoke execute on function public.staff_walkin(bigint, bigint, date, text, integer, text, uuid, text, text, jsonb) from public, anon;
grant execute on function public.staff_walkin(bigint, bigint, date, text, integer, text, uuid, text, text, jsonb) to authenticated;

-- Encaixe aparece com o nome certo e marcado como encaixe (agenda, Caixa) e conta separado em Comissões
do $$
declare v_src text; v_new text;
begin
  select pg_get_functiondef(oid) into v_src from pg_proc where proname = '_booking_json' and pronamespace = 'public'::regnamespace;
  v_new := replace(v_src, '''child_id'', b.child_id,', '''child_id'', b.child_id, ''walk_in'', b.walk_in, ''walkin_name'', b.walkin_name,');
  if v_new = v_src then raise exception '_booking_json mudou'; end if;
  execute v_new;

  select pg_get_functiondef(oid) into v_src from pg_proc where proname = 'staff_cashbox' and pronamespace = 'public'::regnamespace;
  v_new := replace(v_src,
    'coalesce((select name from children where id = b.child_id) || '' (filho de '' || p.name || '')'', p.name) as cliente',
    'coalesce(b.walkin_name, (select name from children where id = b.child_id) || '' (filho de '' || p.name || '')'', p.name) as cliente');
  if v_new = v_src then raise exception 'staff_cashbox mudou'; end if;
  execute v_new;

  select pg_get_functiondef(oid) into v_src from pg_proc where proname = 'admin_commissions' and pronamespace = 'public'::regnamespace;
  v_new := replace(v_src, 'count(b.id) as atendimentos,', 'count(b.id) as atendimentos, count(b.id) filter (where b.walk_in) as encaixes,');
  if v_new = v_src then raise exception 'admin_commissions mudou'; end if;
  execute v_new;
end $$;

-- ------------------------------------------------------------- notas
create table if not exists public.staff_notes (
  user_id    uuid primary key references public.profiles(id) on delete cascade,
  body       text not null default '' check (length(body) <= 20000),
  updated_at timestamptz not null default now()
);
alter table public.staff_notes enable row level security;  -- só pelas funções

create or replace function public.my_note() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  perform _require_staff();
  return coalesce((select json_build_object('body', body, 'updated_at', updated_at) from staff_notes where user_id = auth.uid()),
                  json_build_object('body', '', 'updated_at', null));
end $$;

create or replace function public.save_my_note(p_body text) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform _require_staff();
  if length(coalesce(p_body, '')) > 20000 then raise exception 'Nota grande demais (máximo 20 mil letras).' using errcode = 'PT400'; end if;
  insert into staff_notes (user_id, body, updated_at) values (auth.uid(), coalesce(p_body, ''), now())
  on conflict (user_id) do update set body = excluded.body, updated_at = now();
  return json_build_object('ok', true, 'updated_at', now());
end $$;

revoke execute on function public.my_note(), public.save_my_note(text) from public, anon;
grant execute on function public.my_note(), public.save_my_note(text) to authenticated;
