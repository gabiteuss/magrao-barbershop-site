-- =====================================================================
-- 1) Comissão: cada barbeiro tem a sua porcentagem (padrão 60% barbeiro / 40% casa)
-- 2) Valor final cobrado ao concluir (químicas são "a partir de")
-- 3) Cliente de balcão: cadastrado pela equipe só com nome e telefone, sem login
-- 4) Agendamento feito pela equipe (sem Pix: paga na barbearia)
-- =====================================================================

alter table public.barbers add column commission_percent integer not null default 60
  check (commission_percent between 0 and 100);
alter table public.bookings add column final_price_cents integer check (final_price_cents >= 0);
alter table public.bookings add column created_by text not null default 'cliente';

-- Perfil pode existir sem conta de login (cliente de balcão)
alter table public.profiles add column has_login boolean not null default true;
alter table public.profiles drop constraint profiles_id_fkey;

-- Conta apagada no login => perfil apagado (antes era a chave estrangeira que fazia isso)
create or replace function public.handle_deleted_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from public.profiles where id = old.id;
  return old;
end $$;
create trigger on_auth_user_deleted after delete on auth.users
  for each row execute function public.handle_deleted_user();

-- Cadastro pelo site: se o telefone já foi cadastrado no balcão, avisa em vez de assumir o histórico
-- (sem confirmação por SMS não dá para provar que o telefone é de quem está se cadastrando)
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_phone text := regexp_replace(coalesce(new.raw_user_meta_data ->> 'phone', ''), '\D', '', 'g');
begin
  if length(v_phone) in (10, 11) then
    v_phone := '55' || v_phone;
  end if;
  if v_phone !~ '^55[0-9]{10,11}$' then
    raise exception 'WhatsApp inválido. Use DDD + número.' using errcode = 'P0001';
  end if;
  if length(trim(coalesce(new.raw_user_meta_data ->> 'name', ''))) < 2 then
    raise exception 'Digite seu nome.' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.profiles where phone = v_phone and not has_login) then
    raise exception 'Esse WhatsApp já foi cadastrado pela barbearia. Fale com a gente para liberar o seu acesso.' using errcode = 'P0001';
  end if;
  begin
    insert into public.profiles (id, name, phone, privacy_accepted_at)
    values (new.id, left(trim(new.raw_user_meta_data ->> 'name'), 80), v_phone,
            case when new.raw_user_meta_data ->> 'privacy' = 'true' then now() end);
  exception when unique_violation then
    raise exception 'Esse WhatsApp já tem cadastro. Use "Já tenho conta".' using errcode = 'P0001';
  end;
  return new;
end $$;

-- ------------------------------------------------------------- valor cobrado e status
create or replace function public._charged(b bookings) returns integer
language sql immutable as $$ select coalesce(b.final_price_cents, b.price_cents) $$;

drop function public.admin_set_status(bigint, text, boolean);
create function public.admin_set_status(p_id bigint, p_status text, p_refund boolean default true,
                                        p_final_cents integer default null) returns json
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
  update bookings set status = p_status,
         final_price_cents = case when p_status = 'concluido' then coalesce(p_final_cents, final_price_cents) end
  where id = p_id;
  return json_build_object('ok', true);
end $$;

-- ------------------------------------------------------------- comissões
-- Por barbeiro no período: atendimentos concluídos, total cobrado, parte do barbeiro e da casa
create or replace function public.admin_commissions(p_from date, p_to date) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  v_barber bigint := case when is_admin() then null else my_barber_id() end;
begin
  perform _require_staff();
  if p_to < p_from or p_to - p_from > 370 then
    raise exception 'Período inválido.' using errcode = 'PT400';
  end if;
  return (
    select coalesce(json_agg(x order by x.total_cents desc), '[]') from (
      select br.id as barber_id, br.name as barber_name, br.commission_percent,
             count(b.id) as atendimentos,
             coalesce(sum(_charged(b)), 0)::int as total_cents,
             coalesce(sum(round(_charged(b) * br.commission_percent / 100.0)), 0)::int as barbeiro_cents,
             coalesce(sum(_charged(b) - round(_charged(b) * br.commission_percent / 100.0)), 0)::int as casa_cents
      from barbers br
      left join bookings b on b.barber_id = br.id and b.status = 'concluido'
                          and b.start_at::date between p_from and p_to
      where v_barber is null or br.id = v_barber
      group by br.id
    ) x);
end $$;

-- ------------------------------------------------------------- barbeiros (com comissão)
create or replace function public.admin_barbers() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  perform _require_staff();
  return (select coalesce(json_agg(json_build_object('id', b.id, 'name', b.name, 'title', b.title, 'bio', b.bio, 'photo', b.photo,
            'active', b.active, 'commission_percent', b.commission_percent,
            'hours', (select coalesce(json_agg(json_build_object('weekday', w.weekday,
               'start', to_char(w.start_time, 'HH24:MI'), 'end', to_char(w.end_time, 'HH24:MI')) order by w.weekday, w.start_time), '[]')
               from working_hours w where w.barber_id = b.id)) order by b.id), '[]')
          from barbers b);
end $$;

create or replace function public.admin_save_barber(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_id bigint := nullif(p->>'id', '')::bigint;
  v_pct integer := coalesce((p->>'commission_percent')::int, 60);
  h jsonb;
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
  delete from working_hours where barber_id = v_id;
  for h in select * from jsonb_array_elements(coalesce(p->'hours', '[]')) loop
    insert into working_hours (barber_id, weekday, start_time, end_time)
    values (v_id, (h->>'weekday')::smallint, (h->>'start')::time, (h->>'end')::time);
  end loop;
end $$;

-- ------------------------------------------------------------- clientes de balcão
create or replace function public.admin_create_client(p_name text, p_phone text) returns json
language plpgsql security definer set search_path = public as $$
declare
  v_phone text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  v_id uuid;
begin
  perform _require_staff();
  if length(v_phone) in (10, 11) then v_phone := '55' || v_phone; end if;
  if v_phone !~ '^55[0-9]{10,11}$' then
    raise exception 'Telefone inválido. Use DDD + número.' using errcode = 'PT400';
  end if;
  if length(trim(coalesce(p_name, ''))) < 2 then
    raise exception 'Digite o nome do cliente.' using errcode = 'PT400';
  end if;
  select id into v_id from profiles where phone = v_phone;
  if v_id is not null then  -- já existe: devolve o mesmo cliente
    return (select json_build_object('id', id, 'name', name, 'phone', phone, 'has_login', has_login, 'existing', true)
            from profiles where id = v_id);
  end if;
  insert into profiles (id, name, phone, has_login) values (gen_random_uuid(), left(trim(p_name), 80), v_phone, false)
  returning id into v_id;
  return json_build_object('id', v_id, 'name', left(trim(p_name), 80), 'phone', v_phone, 'has_login', false, 'existing', false);
end $$;

-- Busca rápida para agendar pelo balcão (equipe): só nome e telefone, no máximo 10
create or replace function public.admin_find_clients(p_q text) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  v_digits text := regexp_replace(coalesce(p_q, ''), '\D', '', 'g');
begin
  perform _require_staff();
  if length(trim(coalesce(p_q, ''))) < 2 then return '[]'; end if;
  return (select coalesce(json_agg(json_build_object('id', id, 'name', name, 'phone', phone, 'has_login', has_login)), '[]')
          from (select * from profiles
                where name ilike '%' || trim(p_q) || '%' or (length(v_digits) >= 4 and phone like '%' || v_digits || '%')
                order by name limit 10) x);
end $$;

-- Lista completa (administrador): inclui clientes de balcão (sem e-mail)
create or replace function public.admin_clients(p_q text default '') returns json
language plpgsql stable security definer set search_path = public as $$
begin
  perform _require_admin();
  return (select coalesce(json_agg(x order by x.created_at desc), '[]') from (
    select p.id, p.name, p.phone, u.email, p.role, p.barber_id, p.created_at, p.has_login,
           (select count(*) from bookings b where b.user_id = p.id and b.status = 'concluido') as cortes,
           (select count(*) from bookings b where b.user_id = p.id and b.status = 'faltou') as faltas
    from profiles p left join auth.users u on u.id = p.id
    where p_q = '' or p.name ilike '%' || p_q || '%'
       or (regexp_replace(p_q, '\D', '', 'g') <> '' and p.phone like '%' || regexp_replace(p_q, '\D', '', 'g') || '%')
    order by p.created_at desc limit 100) x);
end $$;

-- Papel só para quem tem login
create or replace function public.admin_set_role(p_user uuid, p_role text, p_barber bigint default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require_admin();
  if p_user = auth.uid() and p_role <> 'admin' then
    raise exception 'Você não pode tirar o seu próprio acesso de administrador.' using errcode = 'PT400';
  end if;
  if p_role not in ('client', 'barber', 'admin') then raise exception 'Papel inválido.' using errcode = 'PT400'; end if;
  if p_role <> 'client' and not exists (select 1 from profiles where id = p_user and has_login) then
    raise exception 'Cliente de balcão não tem login. Ele precisa criar uma conta no site primeiro.' using errcode = 'PT400';
  end if;
  if p_role = 'barber' and p_barber is null then
    raise exception 'Escolha qual barbeiro é essa conta.' using errcode = 'PT400';
  end if;
  update profiles set role = p_role, barber_id = case when p_role = 'barber' then p_barber end where id = p_user;
end $$;

-- ------------------------------------------------------------- agendamento pela equipe
-- Sem Pix (paga tudo na barbearia). p_force = encaixe fora do expediente.
create or replace function public.admin_create_booking(p_user uuid, p_service bigint, p_date date, p_time text,
                                                        p_barber bigint, p_force boolean default false) returns json
language plpgsql security definer set search_path = public as $$
declare
  s services;
  p profiles;
  v_start timestamp;
  v_id bigint;
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

  insert into bookings (user_id, barber_id, service_id, start_at, end_at, status, price_cents, deposit_cents, created_at, created_by)
  values (p.id, p_barber, s.id, v_start, v_start + make_interval(mins => s.duration_min), 'confirmado',
          s.price_cents, 0, local_now(), 'barbearia')
  returning id into v_id;

  perform enqueue_message(p.phone, 'confirmacao', jsonb_build_array(first_name(p.name), s.name,
          (select name from barbers where id = p_barber), fmt_quando(v_start)));
  return _booking_json(v_id, true);
end $$;

-- Horários livres para agendar pelo balcão (sem a antecedência mínima do site)
create or replace function public.admin_free_slots(p_service bigint, p_date date, p_barber bigint) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  v_dur integer;
begin
  perform _staff_can(p_barber);
  select duration_min into v_dur from services where id = p_service and active;
  if v_dur is null then raise exception 'Serviço não encontrado.' using errcode = 'PT404'; end if;
  return (select coalesce(json_agg(to_char(t, 'HH24:MI') order by t), '[]') from _free_slots(p_barber, p_date, v_dur, null, false) t);
end $$;

-- O cartão da agenda mostra quem agendou e o valor final
create or replace function public._booking_json(p_id bigint, p_staff boolean default false) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'id', b.id, 'status', b.status, 'start_at', b.start_at, 'end_at', b.end_at,
    'quando', fmt_quando(b.start_at), 'service_id', b.service_id, 'service_name', s.name, 'price_from', s.price_from,
    'barber_id', b.barber_id, 'barber_name', br.name,
    'price_cents', b.price_cents, 'deposit_cents', b.deposit_cents, 'remaining_cents', b.price_cents - b.deposit_cents,
    'final_price_cents', b.final_price_cents,
    'paid', b.paid_at is not null, 'refund_status', b.refund_status,
    'moved_by_shop', b.moved_by_shop, 'moved_from', case when b.moved_from is not null then fmt_quando(b.moved_from) end,
    'pix_code', case when b.status = 'pendente' then b.pix_code end,
    'pix_qr_base64', case when b.status = 'pendente' then b.pix_qr_base64 end,
    'hold_seconds_left', case when b.status = 'pendente' then greatest(0, extract(epoch from b.hold_expires_at - local_now())::int) else 0 end,
    'refund_if_cancel', _can_refund(b), 'cancel_hours', setting('cancel_hours'),
    'client_name', case when p_staff then p.name end,
    'client_phone', case when p_staff then p.phone end,
    'client_has_login', case when p_staff then p.has_login end,
    'created_by', case when p_staff then b.created_by end,
    'cancelled_by', b.cancelled_by)
  from bookings b join services s on s.id = b.service_id join barbers br on br.id = b.barber_id
  join profiles p on p.id = b.user_id
  where b.id = p_id
$$;

-- ------------------------------------------------------------- permissões
revoke execute on function public.handle_deleted_user(), public._charged(bookings) from public, anon, authenticated;
revoke execute on function public.admin_set_status(bigint, text, boolean, integer), public.admin_commissions(date, date),
  public.admin_create_client(text, text), public.admin_find_clients(text), public.admin_create_booking(uuid, bigint, date, text, bigint, boolean),
  public.admin_free_slots(bigint, date, bigint) from public, anon;
grant execute on function public.admin_set_status(bigint, text, boolean, integer), public.admin_commissions(date, date),
  public.admin_create_client(text, text), public.admin_find_clients(text), public.admin_create_booking(uuid, bigint, date, text, bigint, boolean),
  public.admin_free_slots(bigint, date, bigint) to authenticated;
