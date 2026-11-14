-- =====================================================================
-- Regras de negócio. Todas as funções públicas conferem auth.uid() e o papel.
-- Erros com código PTxxx viram o status HTTP xxx no Supabase (PostgREST).
-- =====================================================================

-- ------------------------------------------------------------- utilitários
create or replace function public.local_now() returns timestamp
language sql stable as $$
  select date_trunc('minute', now() at time zone 'America/Sao_Paulo')::timestamp
$$;

create or replace function public.setting(k text) returns integer
language sql stable security definer set search_path = public as $$
  select value::integer from settings where key = k
$$;

create or replace function public.setting_text(k text) returns text
language sql stable security definer set search_path = public as $$
  select value from settings where key = k
$$;

create or replace function public.fmt_quando(t timestamp) returns text
language sql immutable as $$
  select (array['dom','seg','ter','qua','qui','sex','sáb'])[extract(dow from t)::int + 1]
         || ' ' || to_char(t, 'DD/MM') || ' às ' || to_char(t, 'HH24:MI')
$$;

create or replace function public.fmt_dia(d date) returns text
language sql immutable as $$
  select (array['dom','seg','ter','qua','qui','sex','sáb'])[extract(dow from d)::int + 1] || ' ' || to_char(d, 'DD/MM')
$$;

create or replace function public.first_name(n text) returns text
language sql immutable as $$ select split_part(trim(n), ' ', 1) $$;

-- ------------------------------------------------------------- mensagens
-- Texto de cada mensagem. No WhatsApp oficial cada tipo é um modelo aprovado com os mesmos parâmetros.
create or replace function public.msg_text(p_kind text, p jsonb) returns text
language sql immutable as $$
  select case p_kind
    when 'confirmacao'  then format('Olá, %s! Seu horário na Magrão Barber Shop está confirmado: %s com %s em %s. Sinal recebido. Até lá! 💈', p->>0, p->>1, p->>2, p->>3)
    when 'lembrete'     then format('Fala, %s! Passando pra lembrar: seu horário é hoje às %s com %s. Estamos te esperando! 💈', p->>0, p->>1, p->>2)
    when 'lista_espera' then format('Olá, %s! Abriu um horário em %s na Magrão Barber Shop. Corre pra garantir: %s', p->>0, p->>1, p->>2)
    when 'remarcado'    then format('Olá, %s! A Magrão Barber Shop precisou mudar seu horário de %s para %s com %s. Se não puder, cancele pelo site e devolvemos o sinal: %s', p->>0, p->>1, p->>2, p->>3, p->>4)
    when 'cancelamento' then format('Olá, %s! Seu horário de %s foi cancelado. %s', p->>0, p->>1, p->>2)
    else p::text end
$$;

create or replace function public.enqueue_message(p_phone text, p_kind text, p_params jsonb) returns void
language sql security definer set search_path = public as $$
  insert into messages (to_phone, kind, params, body) values (p_phone, p_kind, p_params, msg_text(p_kind, p_params))
$$;

-- ------------------------------------------------------------- horários livres
create or replace function public._free_slots(
  p_barber bigint, p_day date, p_duration integer,
  p_ignore bigint default null, p_respect_window boolean default true
) returns setof timestamp
language plpgsql stable security definer set search_path = public as $$
declare
  v_now      timestamp := local_now();
  v_step     interval  := make_interval(mins => setting('slot_step_min'));
  v_dur      interval  := make_interval(mins => p_duration);
  v_earliest timestamp := v_now + make_interval(mins => setting('min_lead_min'));
  v_latest   timestamp := v_now + make_interval(days => setting('days_ahead'));
  w record;
  t timestamp;
begin
  for w in
    select start_time, end_time from working_hours
    where barber_id = p_barber and weekday = extract(dow from p_day)::int
    order by start_time
  loop
    t := p_day + w.start_time;
    while t + v_dur <= p_day + w.end_time loop
      if t > v_now
         and (not p_respect_window or (t >= v_earliest and t <= v_latest))
         and not exists (
           select 1 from bookings b
           where b.barber_id = p_barber and b.id is distinct from p_ignore
             and b.start_at < t + v_dur and b.end_at > t
             and (b.status = 'confirmado' or (b.status = 'pendente' and b.hold_expires_at > v_now)))
         and not exists (
           select 1 from blocks k where k.barber_id = p_barber and k.start_at < t + v_dur and k.end_at > t)
      then
        return next t;
      end if;
      t := t + v_step;
    end loop;
  end loop;
end $$;

-- Horários livres de um serviço num dia: [{time, barbers:[{id,name}]}]
create or replace function public.availability(p_service bigint, p_day date, p_barber bigint default null) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  v_dur integer;
begin
  select duration_min into v_dur from services where id = p_service and active;
  if v_dur is null then
    raise exception 'Serviço não encontrado.' using errcode = 'PT404';
  end if;
  return (
    select coalesce(json_agg(json_build_object('time', to_char(t, 'HH24:MI'), 'barbers', bs) order by t), '[]'::json)
    from (
      select t, json_agg(json_build_object('id', b.id, 'name', b.name) order by b.id) as bs
      from barbers b cross join lateral _free_slots(b.id, p_day, v_dur) as t
      where b.active and (p_barber is null or b.id = p_barber)
      group by t
    ) x);
end $$;

-- Próximos dias com quantidade de vagas (para o calendário)
create or replace function public.available_days(p_service bigint, p_barber bigint default null) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  v_dur integer;
  v_today date := local_now()::date;
begin
  select duration_min into v_dur from services where id = p_service and active;
  if v_dur is null then
    raise exception 'Serviço não encontrado.' using errcode = 'PT404';
  end if;
  return (
    select json_agg(json_build_object(
             'date', d::date,
             'open', exists (select 1 from working_hours w join barbers b on b.id = w.barber_id
                             where b.active and (p_barber is null or b.id = p_barber) and w.weekday = extract(dow from d)::int),
             'free', (select count(distinct t) from barbers b cross join lateral _free_slots(b.id, d::date, v_dur) t
                      where b.active and (p_barber is null or b.id = p_barber)))
           order by d)
    from generate_series(v_today, v_today + setting('days_ahead'), interval '1 day') d);
end $$;

-- Dados públicos do site: serviços, barbeiros, regras e horário de funcionamento
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
    'settings', json_build_object('deposit_percent', setting('deposit_percent'), 'cancel_hours', setting('cancel_hours'),
                                  'hold_minutes', setting('hold_minutes'), 'days_ahead', setting('days_ahead')),
    'payment_provider', setting_text('payment_provider'))
$$;

-- ------------------------------------------------------------- agendamento
create or replace function public._can_refund(b bookings) returns boolean
language sql stable set search_path = public as $$
  select b.status = 'confirmado'
     and (b.moved_by_shop or b.start_at - local_now() >= make_interval(hours => setting('cancel_hours')))
$$;

create or replace function public._booking_json(p_id bigint, p_staff boolean default false) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'id', b.id, 'status', b.status, 'start_at', b.start_at, 'end_at', b.end_at,
    'quando', fmt_quando(b.start_at), 'service_id', b.service_id, 'service_name', s.name,
    'barber_id', b.barber_id, 'barber_name', br.name,
    'price_cents', b.price_cents, 'deposit_cents', b.deposit_cents, 'remaining_cents', b.price_cents - b.deposit_cents,
    'paid', b.paid_at is not null, 'refund_status', b.refund_status,
    'moved_by_shop', b.moved_by_shop, 'moved_from', case when b.moved_from is not null then fmt_quando(b.moved_from) end,
    'pix_code', case when b.status = 'pendente' then b.pix_code end,
    'pix_qr_base64', case when b.status = 'pendente' then b.pix_qr_base64 end,
    'hold_seconds_left', case when b.status = 'pendente' then greatest(0, extract(epoch from b.hold_expires_at - local_now())::int) else 0 end,
    'refund_if_cancel', _can_refund(b), 'cancel_hours', setting('cancel_hours'),
    'client_name', case when p_staff then p.name end,
    'client_phone', case when p_staff then p.phone end,
    'cancelled_by', b.cancelled_by)
  from bookings b join services s on s.id = b.service_id join barbers br on br.id = b.barber_id
  join profiles p on p.id = b.user_id
  where b.id = p_id
$$;

create or replace function public.create_booking(p_service bigint, p_date date, p_time text, p_barber bigint default null) returns json
language plpgsql security definer set search_path = public as $$
declare
  v_uid    uuid := auth.uid();
  v_now    timestamp := local_now();
  s        services;
  v_start  timestamp;
  v_barber bigint;
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

  -- Fila única de escrita na agenda: dois clientes nunca pegam o mesmo horário
  perform pg_advisory_xact_lock(hashtext('agenda'));

  update bookings set status = 'cancelado', cancelled_at = now(), cancelled_by = 'cliente'
  where user_id = v_uid and status = 'pendente';

  for cand in select id from barbers where active and (p_barber is null or id = p_barber) order by id loop
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

  if v_dep = 0 then  -- sem sinal: já confirma
    perform enqueue_message(p.phone, 'confirmacao', jsonb_build_array(first_name(p.name), s.name,
            (select name from barbers where id = v_barber), fmt_quando(v_start)));
  end if;

  update waitlist set status = 'atendido'
  where user_id = v_uid and date = p_date and status in ('aguardando', 'avisado');

  return _booking_json(v_id);
end $$;

create or replace function public.booking_status(p_id bigint) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from bookings where id = p_id and (user_id = auth.uid() or is_admin())) then
    raise exception 'Agendamento não encontrado.' using errcode = 'PT404';
  end if;
  return _booking_json(p_id);
end $$;

create or replace function public.my_bookings() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(_booking_json(id) order by start_at desc), '[]')
  from (select id, start_at from bookings
        where user_id = auth.uid() and status <> 'expirado'
        order by start_at desc limit 30) x
$$;

create or replace function public.my_profile() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('id', p.id, 'name', p.name, 'phone', p.phone, 'email', u.email,
                           'role', p.role, 'barber_id', p.barber_id)
  from profiles p join auth.users u on u.id = p.id where p.id = auth.uid()
$$;

create or replace function public.update_my_profile(p_name text, p_phone text) returns json
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
  begin
    update profiles set name = left(trim(p_name), 80), phone = v_phone where id = auth.uid();
  exception when unique_violation then
    raise exception 'Esse WhatsApp já está em outra conta.' using errcode = 'PT409';
  end;
  return my_profile();
end $$;

-- ------------------------------------------------------------- Pix, cancelamento e lista de espera
-- Abriu vaga: avisa os primeiros da lista de espera daquele dia
create or replace function public._notify_waitlist_slot(p_barber bigint, p_start timestamp) returns void
language plpgsql security definer set search_path = public as $$
declare
  w record;
begin
  if p_start <= local_now() then return; end if;
  for w in
    select wl.*, pr.name, pr.phone from waitlist wl join profiles pr on pr.id = wl.user_id
    where wl.status = 'aguardando' and wl.date = p_start::date and (wl.barber_id is null or wl.barber_id = p_barber)
    order by wl.created_at limit setting('waitlist_notify_count')
  loop
    perform enqueue_message(w.phone, 'lista_espera', jsonb_build_array(first_name(w.name), fmt_dia(w.date),
            setting_text('site_url') || '/agendar.html?servico=' || w.service_id || '&data=' || w.date || coalesce('&barbeiro=' || w.barber_id, '')));
    update waitlist set status = 'avisado', notified_at = now() where id = w.id;
  end loop;
end $$;

create or replace function public._notify_waitlist(p_booking bigint) returns void
language sql security definer set search_path = public as $$
  select _notify_waitlist_slot(barber_id, start_at) from bookings where id = p_booking
$$;

-- Chamado só pelas funções do servidor (webhook do Pix), nunca pelo navegador
create or replace function public.confirm_payment(p_booking bigint) returns void
language plpgsql security definer set search_path = public as $$
declare
  b bookings;
  p profiles;
  v_ok boolean;
begin
  perform pg_advisory_xact_lock(hashtext('agenda'));
  select * into b from bookings where id = p_booking for update;
  if b.id is null or b.paid_at is not null then return; end if;
  select * into p from profiles where id = b.user_id;

  v_ok := b.status = 'pendente'
       or (b.status = 'expirado' and b.start_at > local_now()
           and exists (select 1 from _free_slots(b.barber_id, b.start_at::date, (extract(epoch from b.end_at - b.start_at) / 60)::int, b.id, false) t
                       where t = b.start_at));
  if v_ok then
    begin
      update bookings set status = 'confirmado', paid_at = now() where id = b.id;
    exception when exclusion_violation then
      v_ok := false;
    end;
  end if;

  if v_ok then
    perform enqueue_message(p.phone, 'confirmacao', jsonb_build_array(first_name(p.name),
            (select name from services where id = b.service_id), (select name from barbers where id = b.barber_id), fmt_quando(b.start_at)));
  else
    -- Pix chegou tarde e o horário já foi ocupado (ou foi cancelado): devolve
    update bookings set paid_at = now(), refund_status = 'pendente' where id = b.id;
    perform enqueue_message(p.phone, 'cancelamento', jsonb_build_array(first_name(p.name), fmt_quando(b.start_at),
            'O Pix chegou depois do prazo e o horário já tinha sido ocupado. Vamos devolver o seu sinal.'));
  end if;
end $$;

create or replace function public._cancel(p_id bigint, p_by text, p_refund boolean) returns json
language plpgsql security definer set search_path = public as $$
declare
  b bookings;
begin
  select * into b from bookings where id = p_id for update;
  if b.status not in ('pendente', 'confirmado') then
    raise exception 'Esse agendamento não pode mais ser cancelado.' using errcode = 'PT400';
  end if;
  update bookings set status = 'cancelado', cancelled_at = now(), cancelled_by = p_by,
         refund_status = case when p_refund and b.paid_at is not null then 'pendente' else refund_status end
  where id = p_id;
  perform _notify_waitlist(p_id);
  return json_build_object('ok', true, 'refund', p_refund and b.paid_at is not null);
end $$;

create or replace function public.cancel_booking(p_id bigint) returns json
language plpgsql security definer set search_path = public as $$
declare
  b bookings;
begin
  select * into b from bookings where id = p_id and user_id = auth.uid();
  if b.id is null then
    raise exception 'Agendamento não encontrado.' using errcode = 'PT404';
  end if;
  if b.start_at <= local_now() then
    raise exception 'O horário já passou.' using errcode = 'PT400';
  end if;
  return _cancel(p_id, 'cliente', _can_refund(b));
end $$;

create or replace function public.join_waitlist(p_service bigint, p_date date, p_barber bigint default null) returns json
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then
    raise exception 'Entre na sua conta.' using errcode = 'PT401';
  end if;
  if p_date < local_now()::date or p_date > local_now()::date + setting('days_ahead') then
    raise exception 'Data fora da agenda.' using errcode = 'PT400';
  end if;
  if not exists (select 1 from services where id = p_service and active) then
    raise exception 'Serviço não encontrado.' using errcode = 'PT404';
  end if;
  if exists (select 1 from waitlist where user_id = auth.uid() and date = p_date and status = 'aguardando') then
    raise exception 'Você já está na lista de espera desse dia.' using errcode = 'PT409';
  end if;
  if (select count(*) from waitlist where user_id = auth.uid() and status = 'aguardando') >= 5 then
    raise exception 'Você já está em 5 listas de espera.' using errcode = 'PT429';
  end if;
  insert into waitlist (user_id, service_id, barber_id, date) values (auth.uid(), p_service, p_barber, p_date);
  return json_build_object('ok', true,
    'position', (select count(*) from waitlist where date = p_date and status = 'aguardando'));
end $$;

create or replace function public.my_waitlist() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('id', w.id, 'date', w.date, 'status', w.status,
                  'service_name', s.name, 'barber_name', b.name) order by w.date), '[]')
  from waitlist w join services s on s.id = w.service_id left join barbers b on b.id = w.barber_id
  where w.user_id = auth.uid() and w.date >= local_now()::date and w.status in ('aguardando', 'avisado')
$$;

create or replace function public.leave_waitlist(p_id bigint) returns void
language sql security definer set search_path = public as $$
  update waitlist set status = 'cancelado' where id = p_id and user_id = auth.uid()
$$;

-- ------------------------------------------------------------- rotina automática (pg_cron, a cada minuto)
create or replace function public.tick() returns void
language plpgsql security definer set search_path = public as $$
declare
  r record;
  v_now timestamp := local_now();
  v_min integer := setting('reminder_minutes');
begin
  for r in select id from bookings where status = 'pendente' and hold_expires_at <= v_now loop
    update bookings set status = 'expirado' where id = r.id and status = 'pendente';
    perform _notify_waitlist(r.id);
  end loop;

  for r in
    select b.id, b.start_at, b.created_at, p.name, p.phone, br.name as barber
    from bookings b join profiles p on p.id = b.user_id join barbers br on br.id = b.barber_id
    where b.status = 'confirmado' and b.reminder_sent_at is null
      and b.start_at > v_now and b.start_at <= v_now + make_interval(mins => v_min)
  loop
    update bookings set reminder_sent_at = now() where id = r.id;
    -- Quem agendou já dentro da janela do lembrete acabou de receber a confirmação
    if r.created_at < r.start_at - make_interval(mins => v_min) then
      perform enqueue_message(r.phone, 'lembrete', jsonb_build_array(first_name(r.name), to_char(r.start_at, 'HH24:MI'), r.barber));
    end if;
  end loop;

  update waitlist set status = 'cancelado' where status in ('aguardando', 'avisado') and date < v_now::date;
end $$;

-- ------------------------------------------------------------- painel da equipe
create or replace function public._require_staff() returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_staff() then
    raise exception 'Acesso só para a equipe.' using errcode = 'PT403';
  end if;
end $$;

create or replace function public._require_admin() returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then
    raise exception 'Acesso só para o administrador.' using errcode = 'PT403';
  end if;
end $$;

-- Barbeiro só mexe na própria agenda; administrador mexe em tudo
create or replace function public._staff_can(p_barber bigint) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  perform _require_staff();
  if not is_admin() and p_barber is distinct from my_barber_id() then
    raise exception 'Você só pode mexer na sua agenda.' using errcode = 'PT403';
  end if;
end $$;

create or replace function public.admin_agenda(p_date date, p_barber bigint default null) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  v_barber bigint := case when is_admin() then p_barber else my_barber_id() end;
begin
  perform _require_staff();
  return json_build_object(
    'bookings', (select coalesce(json_agg(_booking_json(id, true) order by start_at), '[]') from bookings
                 where start_at::date = p_date and status <> 'expirado' and (v_barber is null or barber_id = v_barber)),
    'blocks', (select coalesce(json_agg(json_build_object('id', k.id, 'barber_id', k.barber_id, 'barber_name', b.name,
                 'start_at', k.start_at, 'end_at', k.end_at, 'reason', k.reason) order by k.start_at), '[]')
               from blocks k join barbers b on b.id = k.barber_id
               where k.start_at::date <= p_date and k.end_at::date >= p_date and (v_barber is null or k.barber_id = v_barber)),
    'waitlist', (select coalesce(json_agg(json_build_object('id', w.id, 'status', w.status, 'name', p.name, 'phone', p.phone,
                   'service_name', s.name, 'barber_name', b.name) order by w.created_at), '[]')
                 from waitlist w join profiles p on p.id = w.user_id join services s on s.id = w.service_id
                 left join barbers b on b.id = w.barber_id
                 where w.date = p_date and w.status in ('aguardando', 'avisado')
                   and (v_barber is null or w.barber_id is null or w.barber_id = v_barber)));
end $$;

create or replace function public.admin_set_status(p_id bigint, p_status text, p_refund boolean default true) returns json
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
  update bookings set status = p_status where id = p_id;
  return json_build_object('ok', true);
end $$;

create or replace function public.admin_retry_refund(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require_admin();
  update bookings set refund_status = 'pendente' where id = p_id and refund_status = 'erro';
end $$;

-- Ocupação dos próximos dias (para escolher dias mais vazios ao remanejar)
create or replace function public.admin_day_load(p_from date, p_days integer default 14, p_barber bigint default null) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  v_barber bigint := case when is_admin() then p_barber else my_barber_id() end;
begin
  perform _require_staff();
  return (
    select json_agg(json_build_object('date', d::date, 'bookings', n, 'capacity_min', cap, 'booked_min', used,
                    'percent', case when cap > 0 then round(100.0 * used / cap) else null end) order by d)
    from generate_series(p_from, p_from + least(p_days, 60) - 1, interval '1 day') d
    cross join lateral (
      select coalesce(sum(extract(epoch from w.end_time - w.start_time) / 60), 0)::int as cap
      from working_hours w join barbers b on b.id = w.barber_id
      where b.active and w.weekday = extract(dow from d)::int and (v_barber is null or b.id = v_barber)) c
    cross join lateral (
      select count(*) as n, coalesce(sum(extract(epoch from end_at - start_at) / 60), 0)::int as used
      from bookings where start_at::date = d::date and status in ('confirmado', 'pendente', 'concluido')
        and (v_barber is null or barber_id = v_barber)) u);
end $$;

-- Horários para onde dá pra mover um agendamento (ignora o próprio)
create or replace function public.admin_move_slots(p_id bigint, p_date date, p_barber bigint) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  b bookings;
begin
  select * into b from bookings where id = p_id;
  if b.id is null then raise exception 'Agendamento não encontrado.' using errcode = 'PT404'; end if;
  perform _staff_can(b.barber_id);
  perform _staff_can(p_barber);
  return (select coalesce(json_agg(to_char(t, 'HH24:MI') order by t), '[]')
          from _free_slots(p_barber, p_date, (extract(epoch from b.end_at - b.start_at) / 60)::int, p_id, false) t);
end $$;

-- Remanejar: muda dia/horário/barbeiro de qualquer cliente e avisa no WhatsApp.
-- p_force = encaixe fora do expediente (só não deixa sobrepor outro cliente nem bloqueio).
create or replace function public.admin_move_booking(p_id bigint, p_date date, p_time text, p_barber bigint,
                                                      p_force boolean default false, p_notify boolean default true) returns json
language plpgsql security definer set search_path = public as $$
declare
  b bookings;
  p profiles;
  v_start timestamp;
  v_dur interval;
begin
  perform pg_advisory_xact_lock(hashtext('agenda'));
  select * into b from bookings where id = p_id for update;
  if b.id is null then raise exception 'Agendamento não encontrado.' using errcode = 'PT404'; end if;
  perform _staff_can(b.barber_id);
  perform _staff_can(p_barber);
  if b.status not in ('confirmado', 'pendente') then
    raise exception 'Só dá pra mover horários ativos.' using errcode = 'PT400';
  end if;
  if p_time !~ '^\d{2}:\d{2}$' then raise exception 'Horário inválido.' using errcode = 'PT400'; end if;
  v_start := p_date + p_time::time;
  v_dur := b.end_at - b.start_at;
  if v_start <= local_now() then
    raise exception 'Escolha um horário no futuro.' using errcode = 'PT400';
  end if;

  if p_force then
    if exists (select 1 from bookings x where x.barber_id = p_barber and x.id <> p_id
                 and x.start_at < v_start + v_dur and x.end_at > v_start
                 and (x.status = 'confirmado' or (x.status = 'pendente' and x.hold_expires_at > local_now())))
       or exists (select 1 from blocks k where k.barber_id = p_barber and k.start_at < v_start + v_dur and k.end_at > v_start) then
      raise exception 'Já tem cliente ou bloqueio nesse horário.' using errcode = 'PT409';
    end if;
  elsif not exists (select 1 from _free_slots(p_barber, p_date, (extract(epoch from v_dur) / 60)::int, p_id, false) t where t = v_start) then
    raise exception 'Esse horário não está livre.' using errcode = 'PT409';
  end if;

  update bookings set start_at = v_start, end_at = v_start + v_dur, barber_id = p_barber,
         moved_by_shop = true, moved_from = coalesce(moved_from, b.start_at), reminder_sent_at = null
  where id = p_id;

  if p_notify and b.status = 'confirmado' then
    select * into p from profiles where id = b.user_id;
    perform enqueue_message(p.phone, 'remarcado', jsonb_build_array(first_name(p.name), fmt_quando(b.start_at), fmt_quando(v_start),
            (select name from barbers where id = p_barber), setting_text('site_url') || '/conta.html'));
  end if;
  -- O horário antigo vagou: avisa a lista de espera daquele dia
  if b.start_at::date <> p_date or b.barber_id <> p_barber or b.start_at <> v_start then
    perform _notify_waitlist_slot(b.barber_id, b.start_at);
  end if;
  return _booking_json(p_id, true);
end $$;

create or replace function public.admin_add_block(p_barber bigint, p_start timestamp, p_end timestamp, p_reason text default '') returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _staff_can(p_barber);
  if p_end <= p_start then raise exception 'O fim precisa ser depois do início.' using errcode = 'PT400'; end if;
  insert into blocks (barber_id, start_at, end_at, reason) values (p_barber, p_start, p_end, left(coalesce(p_reason, ''), 100));
end $$;

create or replace function public.admin_delete_block(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_barber bigint;
begin
  select barber_id into v_barber from blocks where id = p_id;
  if v_barber is null then return; end if;
  perform _staff_can(v_barber);
  delete from blocks where id = p_id;
end $$;

create or replace function public.admin_services() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  perform _require_staff();
  return (select coalesce(json_agg(row_to_json(s) order by sort, id), '[]') from services s);
end $$;

create or replace function public.admin_save_service(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require_admin();
  if p ? 'id' and p->>'id' is not null then
    update services set name = p->>'name', description = coalesce(p->>'description', ''), price_cents = (p->>'price_cents')::int,
           price_from = coalesce((p->>'price_from')::boolean, false), duration_min = (p->>'duration_min')::int,
           sort = coalesce((p->>'sort')::int, 0), active = coalesce((p->>'active')::boolean, true)
    where id = (p->>'id')::bigint;
  else
    insert into services (name, description, price_cents, price_from, duration_min, sort, active)
    values (p->>'name', coalesce(p->>'description', ''), (p->>'price_cents')::int, coalesce((p->>'price_from')::boolean, false),
            (p->>'duration_min')::int, coalesce((p->>'sort')::int, 0), coalesce((p->>'active')::boolean, true));
  end if;
end $$;

create or replace function public.admin_barbers() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  perform _require_staff();
  return (select coalesce(json_agg(json_build_object('id', b.id, 'name', b.name, 'title', b.title, 'bio', b.bio, 'photo', b.photo,
            'active', b.active, 'hours', (select coalesce(json_agg(json_build_object('weekday', w.weekday,
               'start', to_char(w.start_time, 'HH24:MI'), 'end', to_char(w.end_time, 'HH24:MI')) order by w.weekday, w.start_time), '[]')
               from working_hours w where w.barber_id = b.id)) order by b.id), '[]')
          from barbers b);
end $$;

create or replace function public.admin_save_barber(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_id bigint := nullif(p->>'id', '')::bigint;
  h jsonb;
begin
  perform _require_admin();
  if v_id is null then
    insert into barbers (name, title, bio, photo, active)
    values (p->>'name', coalesce(p->>'title', 'Barbeiro'), coalesce(p->>'bio', ''), coalesce(p->>'photo', ''), coalesce((p->>'active')::boolean, true))
    returning id into v_id;
  else
    update barbers set name = p->>'name', title = coalesce(p->>'title', 'Barbeiro'), bio = coalesce(p->>'bio', ''),
           photo = coalesce(p->>'photo', ''), active = coalesce((p->>'active')::boolean, true)
    where id = v_id;
  end if;
  delete from working_hours where barber_id = v_id;
  for h in select * from jsonb_array_elements(coalesce(p->'hours', '[]')) loop
    insert into working_hours (barber_id, weekday, start_time, end_time)
    values (v_id, (h->>'weekday')::smallint, (h->>'start')::time, (h->>'end')::time);
  end loop;
end $$;

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
    -- só as regras numéricas podem ser mudadas pelo painel
    continue when k not in ('deposit_percent', 'reminder_minutes', 'hold_minutes', 'cancel_hours', 'slot_step_min',
                            'min_lead_min', 'days_ahead', 'waitlist_notify_count');
    v := (p->>k)::integer;
    if v < 0 or (k = 'deposit_percent' and v > 100) or (k in ('slot_step_min', 'hold_minutes') and v < 5) then
      raise exception 'Valor inválido para %', k using errcode = 'PT400';
    end if;
    update settings set value = v::text where key = k;
  end loop;
  return admin_get_config();
end $$;

create or replace function public.admin_clients(p_q text default '') returns json
language plpgsql stable security definer set search_path = public as $$
begin
  perform _require_admin();
  return (select coalesce(json_agg(x order by x.created_at desc), '[]') from (
    select p.id, p.name, p.phone, u.email, p.role, p.barber_id, p.created_at,
           (select count(*) from bookings b where b.user_id = p.id and b.status = 'concluido') as cortes,
           (select count(*) from bookings b where b.user_id = p.id and b.status = 'faltou') as faltas
    from profiles p join auth.users u on u.id = p.id
    where p_q = '' or p.name ilike '%' || p_q || '%'
       or (regexp_replace(p_q, '\D', '', 'g') <> '' and p.phone like '%' || regexp_replace(p_q, '\D', '', 'g') || '%')
    order by p.created_at desc limit 100) x);
end $$;

create or replace function public.admin_set_role(p_user uuid, p_role text, p_barber bigint default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require_admin();
  if p_user = auth.uid() and p_role <> 'admin' then
    raise exception 'Você não pode tirar o seu próprio acesso de administrador.' using errcode = 'PT400';
  end if;
  if p_role not in ('client', 'barber', 'admin') then raise exception 'Papel inválido.' using errcode = 'PT400'; end if;
  if p_role = 'barber' and p_barber is null then
    raise exception 'Escolha qual barbeiro é essa conta.' using errcode = 'PT400';
  end if;
  update profiles set role = p_role, barber_id = case when p_role = 'barber' then p_barber end where id = p_user;
end $$;

create or replace function public.admin_messages() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  perform _require_admin();
  return (select coalesce(json_agg(row_to_json(m) order by m.id desc), '[]')
          from (select id, to_phone, kind, body, status, error, created_at from messages order by id desc limit 100) m);
end $$;

-- ------------------------------------------------------------- permissões de execução
-- Por padrão o Postgres deixa qualquer um executar funções. Fechamos tudo e abrimos só o necessário.
revoke execute on all functions in schema public from public, anon, authenticated;

grant execute on function public.public_info(), public.availability(bigint, date, bigint),
  public.available_days(bigint, bigint), public.local_now(), public.is_admin(), public.is_staff(), public.my_barber_id()
  to anon, authenticated;

grant execute on function public.create_booking(bigint, date, text, bigint), public.booking_status(bigint),
  public.my_bookings(), public.my_profile(), public.update_my_profile(text, text), public.cancel_booking(bigint),
  public.join_waitlist(bigint, date, bigint), public.my_waitlist(), public.leave_waitlist(bigint),
  public.admin_agenda(date, bigint), public.admin_set_status(bigint, text, boolean), public.admin_retry_refund(bigint),
  public.admin_day_load(date, integer, bigint), public.admin_move_slots(bigint, date, bigint),
  public.admin_move_booking(bigint, date, text, bigint, boolean, boolean),
  public.admin_add_block(bigint, timestamp, timestamp, text), public.admin_delete_block(bigint),
  public.admin_services(), public.admin_save_service(jsonb), public.admin_barbers(), public.admin_save_barber(jsonb),
  public.admin_get_config(), public.admin_set_config(jsonb), public.admin_clients(text),
  public.admin_set_role(uuid, text, bigint), public.admin_messages()
  to authenticated;

-- Segredo da rotina automática (fica no Vault; só o servidor lê)
create or replace function public.worker_secret() returns text
language sql stable security definer set search_path = public as $$
  select decrypted_secret from vault.decrypted_secrets where name = 'worker_secret'
$$;
revoke execute on function public.worker_secret() from public, anon, authenticated;

-- confirm_payment, tick e as funções com "_" só rodam pelo servidor (service_role) ou internamente
grant execute on function public.confirm_payment(bigint), public.tick(), public.worker_secret() to service_role;

-- Funções criadas depois também nascem fechadas
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
