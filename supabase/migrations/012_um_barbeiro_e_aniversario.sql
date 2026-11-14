-- =====================================================================
-- 1) Cliente com horário marcado só agenda de novo com o MESMO barbeiro e nunca em horários sobrepostos
-- 2) Data de nascimento no cadastro + mensagem de aniversário com brinde
-- =====================================================================

alter table public.profiles add column birth_date date
  check (birth_date is null or (birth_date >= date '1900-01-01' and birth_date <= current_date));
alter table public.profiles add column birthday_sent_year integer;

insert into public.settings (key, value) values
  ('birthday_enabled', '1'),
  ('birthday_gift', 'uma sobrancelha na navalha de presente no seu próximo corte (vale por 30 dias)')
on conflict (key) do nothing;

-- ------------------------------------------------------------- cadastro com data de nascimento
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_phone text := regexp_replace(coalesce(new.raw_user_meta_data ->> 'phone', ''), '\D', '', 'g');
  v_birth date;
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
  begin
    v_birth := nullif(new.raw_user_meta_data ->> 'birth_date', '')::date;
  exception when others then
    raise exception 'Data de nascimento inválida.' using errcode = 'P0001';
  end;
  if v_birth is not null and (v_birth < date '1900-01-01' or v_birth > current_date) then
    raise exception 'Data de nascimento inválida.' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.profiles where phone = v_phone and not has_login) then
    raise exception 'Esse WhatsApp já foi cadastrado pela barbearia. Fale com a gente para liberar o seu acesso.' using errcode = 'P0001';
  end if;
  begin
    insert into public.profiles (id, name, phone, birth_date, privacy_accepted_at)
    values (new.id, left(trim(new.raw_user_meta_data ->> 'name'), 80), v_phone, v_birth,
            case when new.raw_user_meta_data ->> 'privacy' = 'true' then now() end);
  exception when unique_violation then
    raise exception 'Esse WhatsApp já tem cadastro. Use "Já tenho conta".' using errcode = 'P0001';
  end;
  return new;
end $$;

create or replace function public.my_profile() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('id', p.id, 'name', p.name, 'phone', p.phone, 'email', u.email,
                           'role', p.role, 'barber_id', p.barber_id, 'birth_date', p.birth_date)
  from profiles p join auth.users u on u.id = p.id where p.id = auth.uid()
$$;

drop function public.update_my_profile(text, text);
create function public.update_my_profile(p_name text, p_phone text, p_birth_date date default null) returns json
language plpgsql security definer set search_path = public as $$
declare
  v_phone text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  if auth.uid() is null then
    raise exception 'Entre na sua conta.' using errcode = 'PT401';
  end if;
  if length(v_phone) in (10, 11) then v_phone := '55' || v_phone; end if;
  if v_phone !~ '^55[0-9]{10,11}$' then
    raise exception 'WhatsApp inválido.' using errcode = 'PT400';
  end if;
  if p_birth_date is not null and (p_birth_date < date '1900-01-01' or p_birth_date > current_date) then
    raise exception 'Data de nascimento inválida.' using errcode = 'PT400';
  end if;
  begin
    update profiles set name = left(trim(p_name), 80), phone = v_phone,
           birth_date = coalesce(p_birth_date, birth_date)
    where id = auth.uid();
  exception when unique_violation then
    raise exception 'Esse WhatsApp já está em outra conta.' using errcode = 'PT409';
  end;
  return my_profile();
end $$;

-- Balcão: data de nascimento opcional
drop function public.admin_create_client(text, text);
create function public.admin_create_client(p_name text, p_phone text, p_birth_date date default null) returns json
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
  if p_birth_date is not null and (p_birth_date < date '1900-01-01' or p_birth_date > current_date) then
    raise exception 'Data de nascimento inválida.' using errcode = 'PT400';
  end if;
  select id into v_id from profiles where phone = v_phone;
  if v_id is not null then
    update profiles set birth_date = coalesce(birth_date, p_birth_date) where id = v_id;
    return (select json_build_object('id', id, 'name', name, 'phone', phone, 'has_login', has_login, 'existing', true)
            from profiles where id = v_id);
  end if;
  insert into profiles (id, name, phone, birth_date, has_login)
  values (gen_random_uuid(), left(trim(p_name), 80), v_phone, p_birth_date, false)
  returning id into v_id;
  return json_build_object('id', v_id, 'name', left(trim(p_name), 80), 'phone', v_phone, 'has_login', false, 'existing', false);
end $$;

-- ------------------------------------------------------------- agendamento: um barbeiro por cliente
-- Barbeiro com quem o cliente já tem horário marcado (futuro e confirmado)
create or replace function public._client_barber(p_user uuid) returns bigint
language sql stable security definer set search_path = public as $$
  select barber_id from bookings
  where user_id = p_user and status = 'confirmado' and start_at > local_now()
  order by start_at limit 1
$$;

create or replace function public.my_locked_barber() returns json
language sql stable security definer set search_path = public as $$
  select case when b.id is null then null
         else json_build_object('id', b.id, 'name', b.name) end
  from (select _client_barber(auth.uid()) as bid) x left join barbers b on b.id = x.bid
$$;

create or replace function public.create_booking(p_service bigint, p_date date, p_time text, p_barber bigint default null) returns json
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

  -- Já tem horário marcado? Então só com o mesmo barbeiro
  v_locked := _client_barber(v_uid);
  if v_locked is not null and p_barber is not null and p_barber <> v_locked then
    raise exception 'Você já tem horário marcado com %. Novos horários ficam com ele até lá (ou cancele o atual).',
      (select name from barbers where id = v_locked) using errcode = 'PT409';
  end if;

  -- Nunca dois horários do mesmo cliente ao mesmo tempo
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

  v_dep := round(s.price_cents * setting('deposit_percent') / 100.0);
  insert into bookings (user_id, barber_id, service_id, start_at, end_at, status, price_cents, deposit_cents, hold_expires_at, created_at)
  values (v_uid, v_barber, s.id, v_start, v_start + make_interval(mins => s.duration_min),
          case when v_dep = 0 then 'confirmado' else 'pendente' end,
          s.price_cents, v_dep, v_now + make_interval(mins => setting('hold_minutes')), v_now)
  returning id into v_id;

  if v_dep = 0 then
    perform enqueue_message(p.phone, 'confirmacao', jsonb_build_array(first_name(p.name), s.name,
            (select name from barbers where id = v_barber), fmt_quando(v_start)));
  end if;

  update waitlist set status = 'atendido'
  where user_id = v_uid and date = p_date and status in ('aguardando', 'avisado');

  return _booking_json(v_id);
end $$;

-- ------------------------------------------------------------- aniversário
create or replace function public.msg_text(p_kind text, p jsonb) returns text
language sql immutable set search_path = public as $$
  select case p_kind
    when 'confirmacao'  then format('Olá, %s! Seu horário na Magrão Barber Shop está confirmado: %s com %s em %s. Até lá! 💈', p->>0, p->>1, p->>2, p->>3)
    when 'lembrete'     then format('Fala, %s! Passando pra lembrar: seu horário é hoje às %s com %s. Estamos te esperando! 💈', p->>0, p->>1, p->>2)
    when 'lista_espera' then format('Olá, %s! Abriu um horário em %s na Magrão Barber Shop. Corre pra garantir: %s', p->>0, p->>1, p->>2)
    when 'remarcado'    then format('Olá, %s! A Magrão Barber Shop precisou mudar seu horário de %s para %s com %s. Se não puder, cancele pelo site: %s', p->>0, p->>1, p->>2, p->>3, p->>4)
    when 'cancelamento' then format('Olá, %s! Seu horário de %s foi cancelado. %s', p->>0, p->>1, p->>2)
    when 'confirmar_presenca' then format('Olá, %s! Você vem hoje? %s com %s às %s. Confirme até as %s, senão o horário é liberado para outro cliente: %s', p->>0, p->>1, p->>2, p->>3, p->>4, p->>5)
    when 'aniversario'  then format('Parabéns, %s! 🎉 A Magrão Barber Shop deseja um feliz aniversário. Seu presente: %s. Agende aqui: %s', p->>0, p->>1, p->>2)
    else p::text end
$$;

-- Aniversário hoje? (29/02 comemora em 28/02 nos anos que não são bissextos)
create or replace function public._is_birthday(p_birth date, p_day date) returns boolean
language sql immutable as $$
  select p_birth is not null and (
    (extract(month from p_birth) = extract(month from p_day) and extract(day from p_birth) = extract(day from p_day))
    or (extract(month from p_birth) = 2 and extract(day from p_birth) = 29 and extract(month from p_day) = 2
        and extract(day from p_day) = 28
        and not (extract(year from p_day)::int % 4 = 0 and (extract(year from p_day)::int % 100 <> 0 or extract(year from p_day)::int % 400 = 0))))
$$;

-- A rotina (a cada minuto) manda os parabéns uma vez por ano, a partir das 9h
create or replace function public._send_birthdays() returns void
language plpgsql security definer set search_path = public as $$
declare
  r record;
  v_now timestamp := local_now();
begin
  if coalesce(setting('birthday_enabled'), 0) <> 1 or v_now::time < time '09:00' then return; end if;
  for r in
    select id, name, phone from profiles
    where _is_birthday(birth_date, v_now::date)
      and coalesce(birthday_sent_year, 0) < extract(year from v_now)::int
  loop
    update profiles set birthday_sent_year = extract(year from v_now)::int where id = r.id;
    perform enqueue_message(r.phone, 'aniversario', jsonb_build_array(first_name(r.name),
            setting_text('birthday_gift'), setting_text('site_url') || '/agendar.html'));
  end loop;
end $$;

-- Liga os parabéns na rotina existente (tick continua igual e chama o aniversário no fim)
create or replace function public.tick() returns void
language plpgsql security definer set search_path = public as $$
declare
  r record;
  v_now timestamp := local_now();
  v_min integer := setting('reminder_minutes');
  v_req boolean := coalesce(setting('confirm_required'), 0) = 1;
  v_ask interval := make_interval(mins => coalesce(setting('confirm_ask_minutes'), 180));
  v_dead interval := make_interval(mins => coalesce(setting('confirm_deadline_minutes'), 20));
begin
  for r in select id from bookings where status = 'pendente' and hold_expires_at <= v_now loop
    update bookings set status = 'expirado' where id = r.id and status = 'pendente';
    perform _notify_waitlist(r.id);
  end loop;

  if v_req then
    for r in
      select b.id, b.start_at, b.created_at, b.created_by, b.confirm_token, p.name, p.phone, s.name as service, br.name as barber
      from bookings b join profiles p on p.id = b.user_id join services s on s.id = b.service_id join barbers br on br.id = b.barber_id
      where b.status = 'confirmado' and b.attendance_confirmed_at is null and b.confirm_asked_at is null
        and b.start_at > v_now and b.start_at - v_ask <= v_now
    loop
      if r.created_by = 'barbearia' or r.created_at >= r.start_at - v_ask then
        update bookings set attendance_confirmed_at = now() where id = r.id;
      else
        update bookings set confirm_asked_at = now() where id = r.id;
        perform enqueue_message(r.phone, 'confirmar_presenca', jsonb_build_array(first_name(r.name), r.service, r.barber,
                to_char(r.start_at, 'HH24:MI'), to_char(r.start_at - v_dead, 'HH24:MI'),
                setting_text('site_url') || '/confirmar.html?c=' || r.confirm_token));
      end if;
    end loop;

    for r in
      select b.id, b.start_at, p.name, p.phone
      from bookings b join profiles p on p.id = b.user_id
      where b.status = 'confirmado' and b.attendance_confirmed_at is null and b.confirm_asked_at is not null
        and b.start_at - v_dead <= v_now and b.start_at > v_now - interval '1 hour'
    loop
      update bookings set status = 'cancelado', cancelled_at = now(), cancelled_by = 'sistema'
      where id = r.id and status = 'confirmado';
      perform _notify_waitlist(r.id);
      perform enqueue_message(r.phone, 'cancelamento', jsonb_build_array(first_name(r.name), fmt_quando(r.start_at),
              'Como não recebemos a sua confirmação a tempo, o horário foi liberado. Se quiser, agende de novo pelo site.'));
    end loop;
  end if;

  for r in
    select b.id, b.start_at, b.created_at, p.name, p.phone, br.name as barber
    from bookings b join profiles p on p.id = b.user_id join barbers br on br.id = b.barber_id
    where b.status = 'confirmado' and b.reminder_sent_at is null
      and b.start_at > v_now and b.start_at <= v_now + make_interval(mins => v_min)
  loop
    update bookings set reminder_sent_at = now() where id = r.id;
    if r.created_at < r.start_at - make_interval(mins => v_min) then
      perform enqueue_message(r.phone, 'lembrete', jsonb_build_array(first_name(r.name), to_char(r.start_at, 'HH24:MI'), r.barber));
    end if;
  end loop;

  update waitlist set status = 'cancelado' where status in ('aguardando', 'avisado') and date < v_now::date;

  perform _send_birthdays();
end $$;

-- Painel: aniversariantes do mês (equipe vê nome, telefone, dia e idade)
create or replace function public.admin_birthdays(p_month integer default null) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  v_today date := local_now()::date;
  v_month integer := coalesce(p_month, extract(month from v_today)::int);
begin
  perform _require_staff();
  if v_month not between 1 and 12 then raise exception 'Mês inválido.' using errcode = 'PT400'; end if;
  return (select coalesce(json_agg(x order by x.dia, x.name), '[]') from (
    select p.id, p.name, p.phone, p.has_login, extract(day from p.birth_date)::int as dia,
           extract(year from v_today)::int - extract(year from p.birth_date)::int as idade,
           _is_birthday(p.birth_date, v_today) as hoje,
           p.birthday_sent_year = extract(year from v_today)::int as parabens_enviado
    from profiles p
    where extract(month from p.birth_date) = v_month) x);
end $$;

-- Configurações: aniversário (liga/desliga e texto do brinde)
create or replace function public.admin_get_config() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  perform _require_admin();
  return (select json_object_agg(key, value) from settings);
end $$;

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
                            'confirm_required', 'confirm_ask_minutes', 'confirm_deadline_minutes', 'birthday_enabled');
    v := (p->>k)::integer;
    if v < 0 or (k = 'deposit_percent' and v > 100) or (k in ('slot_step_min', 'hold_minutes') and v < 5)
       or (k in ('confirm_required', 'birthday_enabled') and v not in (0, 1)) or (k = 'confirm_deadline_minutes' and v < 5) then
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
revoke execute on function public._client_barber(uuid), public._is_birthday(date, date), public._send_birthdays()
  from public, anon, authenticated;
revoke execute on function public.update_my_profile(text, text, date), public.admin_create_client(text, text, date),
  public.my_locked_barber(), public.admin_birthdays(integer) from public, anon;
grant execute on function public.update_my_profile(text, text, date), public.admin_create_client(text, text, date),
  public.my_locked_barber(), public.admin_birthdays(integer) to authenticated;
