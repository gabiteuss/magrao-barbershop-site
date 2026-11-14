-- =====================================================================
-- Confirmação de presença: o cliente confirma até X minutos antes, senão a vaga é liberada.
-- Liga/desliga em Configurações (confirm_required). Agendamentos do balcão ficam fora da regra.
-- =====================================================================

insert into public.settings (key, value) values
  ('confirm_required', '0'),          -- 1 = exige confirmação de presença
  ('confirm_ask_minutes', '180'),     -- pede a confirmação X minutos antes (3 horas)
  ('confirm_deadline_minutes', '20')  -- sem confirmação até X minutos antes, libera a vaga
on conflict (key) do nothing;

alter table public.bookings add column confirm_token text unique;
alter table public.bookings add column confirm_asked_at timestamptz;
alter table public.bookings add column attendance_confirmed_at timestamptz;

-- Todo agendamento nasce com um código secreto para o link de confirmação
create or replace function public._booking_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.confirm_token := coalesce(new.confirm_token, encode(extensions.gen_random_bytes(18), 'hex'));
  if new.created_by = 'barbearia' then
    new.attendance_confirmed_at := coalesce(new.attendance_confirmed_at, now());
  end if;
  return new;
end $$;
create trigger booking_defaults before insert on public.bookings
  for each row execute function public._booking_defaults();
update public.bookings set confirm_token = encode(extensions.gen_random_bytes(18), 'hex') where confirm_token is null;

-- Mensagens (inclui o pedido de confirmação)
create or replace function public.msg_text(p_kind text, p jsonb) returns text
language sql immutable set search_path = public as $$
  select case p_kind
    when 'confirmacao'  then format('Olá, %s! Seu horário na Magrão Barber Shop está confirmado: %s com %s em %s. Até lá! 💈', p->>0, p->>1, p->>2, p->>3)
    when 'lembrete'     then format('Fala, %s! Passando pra lembrar: seu horário é hoje às %s com %s. Estamos te esperando! 💈', p->>0, p->>1, p->>2)
    when 'lista_espera' then format('Olá, %s! Abriu um horário em %s na Magrão Barber Shop. Corre pra garantir: %s', p->>0, p->>1, p->>2)
    when 'remarcado'    then format('Olá, %s! A Magrão Barber Shop precisou mudar seu horário de %s para %s com %s. Se não puder, cancele pelo site: %s', p->>0, p->>1, p->>2, p->>3, p->>4)
    when 'cancelamento' then format('Olá, %s! Seu horário de %s foi cancelado. %s', p->>0, p->>1, p->>2)
    when 'confirmar_presenca' then format('Olá, %s! Você vem hoje? %s com %s às %s. Confirme até as %s, senão o horário é liberado para outro cliente: %s', p->>0, p->>1, p->>2, p->>3, p->>4, p->>5)
    else p::text end
$$;

-- ------------------------------------------------------------- rotina (a cada minuto)
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
  -- Pix não pago dentro do prazo
  for r in select id from bookings where status = 'pendente' and hold_expires_at <= v_now loop
    update bookings set status = 'expirado' where id = r.id and status = 'pendente';
    perform _notify_waitlist(r.id);
  end loop;

  if v_req then
    -- Pede a confirmação de presença (ou confirma sozinho quem marcou já dentro do prazo)
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

    -- Sem confirmação até o prazo: libera a vaga
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

  -- Lembrete (só para quem continua com horário)
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
end $$;

-- ------------------------------------------------------------- confirmar pelo link (sem login)
-- O link leva um código secreto de 36 caracteres: só quem recebeu a mensagem consegue abrir.
create or replace function public.attendance_info(p_token text) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  b bookings;
begin
  if p_token !~ '^[0-9a-f]{36}$' then raise exception 'Link inválido.' using errcode = 'PT404'; end if;
  select * into b from bookings where confirm_token = p_token;
  if b.id is null then raise exception 'Link inválido ou vencido.' using errcode = 'PT404'; end if;
  return (select json_build_object(
    'status', b.status, 'quando', fmt_quando(b.start_at), 'service_name', s.name, 'barber_name', br.name,
    'first_name', first_name(p.name), 'confirmed', b.attendance_confirmed_at is not null,
    'deadline', to_char(b.start_at - make_interval(mins => setting('confirm_deadline_minutes')), 'HH24:MI'),
    'past_deadline', local_now() >= b.start_at - make_interval(mins => setting('confirm_deadline_minutes')),
    'cancelled_by', b.cancelled_by)
    from services s, barbers br, profiles p where s.id = b.service_id and br.id = b.barber_id and p.id = b.user_id);
end $$;

create or replace function public.confirm_attendance(p_token text, p_going boolean) returns json
language plpgsql security definer set search_path = public as $$
declare
  b bookings;
begin
  if p_token !~ '^[0-9a-f]{36}$' then raise exception 'Link inválido.' using errcode = 'PT404'; end if;
  select * into b from bookings where confirm_token = p_token for update;
  if b.id is null then raise exception 'Link inválido ou vencido.' using errcode = 'PT404'; end if;
  if b.status <> 'confirmado' then
    raise exception 'Esse horário não está mais ativo.' using errcode = 'PT400';
  end if;
  if b.start_at <= local_now() then raise exception 'O horário já passou.' using errcode = 'PT400'; end if;
  if p_going then
    if local_now() >= b.start_at - make_interval(mins => setting('confirm_deadline_minutes'))
       and b.attendance_confirmed_at is null and b.confirm_asked_at is not null then
      raise exception 'O prazo para confirmar já passou.' using errcode = 'PT400';
    end if;
    update bookings set attendance_confirmed_at = coalesce(attendance_confirmed_at, now()) where id = b.id;
  else
    perform _cancel(b.id, 'cliente', _can_refund(b));
  end if;
  return attendance_info(p_token);
end $$;

-- Confirmar em "Minha conta"
create or replace function public.my_confirm_attendance(p_id bigint) returns json
language plpgsql security definer set search_path = public as $$
declare
  v_token text;
begin
  select confirm_token into v_token from bookings where id = p_id and user_id = auth.uid();
  if v_token is null then raise exception 'Agendamento não encontrado.' using errcode = 'PT404'; end if;
  perform confirm_attendance(v_token, true);
  return _booking_json(p_id);
end $$;

-- Barbeiro confirma (cliente avisou por telefone)
create or replace function public.admin_confirm_attendance(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare
  b bookings;
begin
  select * into b from bookings where id = p_id;
  if b.id is null then raise exception 'Agendamento não encontrado.' using errcode = 'PT404'; end if;
  perform _staff_can(b.barber_id);
  if b.status <> 'confirmado' then raise exception 'Esse horário não está ativo.' using errcode = 'PT400'; end if;
  update bookings set attendance_confirmed_at = coalesce(attendance_confirmed_at, now()) where id = p_id;
end $$;

-- ------------------------------------------------------------- dados mostrados no site e no painel
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
    'attendance_confirmed', b.attendance_confirmed_at is not null,
    'confirm_asked', b.confirm_asked_at is not null,
    'confirm_deadline', to_char(b.start_at - make_interval(mins => setting('confirm_deadline_minutes')), 'HH24:MI'),
    'client_name', case when p_staff then p.name end,
    'client_phone', case when p_staff then p.phone end,
    'client_has_login', case when p_staff then p.has_login end,
    'created_by', case when p_staff then b.created_by end,
    'cancelled_by', b.cancelled_by)
  from bookings b join services s on s.id = b.service_id join barbers br on br.id = b.barber_id
  join profiles p on p.id = b.user_id
  where b.id = p_id
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
    'settings', json_build_object('deposit_percent', setting('deposit_percent'), 'cancel_hours', setting('cancel_hours'),
                                  'hold_minutes', setting('hold_minutes'), 'days_ahead', setting('days_ahead'),
                                  'confirm_required', setting('confirm_required'), 'confirm_ask_minutes', setting('confirm_ask_minutes'),
                                  'confirm_deadline_minutes', setting('confirm_deadline_minutes')),
    'payment_provider', setting_text('payment_provider'))
$$;

-- Configurações: inclui a confirmação de presença
create or replace function public.admin_set_config(p jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare
  k text;
  v integer;
begin
  perform _require_admin();
  for k in select jsonb_object_keys(p) loop
    continue when k not in ('deposit_percent', 'reminder_minutes', 'hold_minutes', 'cancel_hours', 'slot_step_min',
                            'min_lead_min', 'days_ahead', 'waitlist_notify_count',
                            'confirm_required', 'confirm_ask_minutes', 'confirm_deadline_minutes');
    v := (p->>k)::integer;
    if v < 0 or (k = 'deposit_percent' and v > 100) or (k in ('slot_step_min', 'hold_minutes') and v < 5)
       or (k = 'confirm_required' and v not in (0, 1)) or (k = 'confirm_deadline_minutes' and v < 5) then
      raise exception 'Valor inválido para %', k using errcode = 'PT400';
    end if;
    update settings set value = v::text where key = k;
  end loop;
  if setting('confirm_ask_minutes') <= setting('confirm_deadline_minutes') + 15 then
    raise exception 'O pedido de confirmação precisa sair pelo menos 15 minutos antes do prazo.' using errcode = 'PT400';
  end if;
  return admin_get_config();
end $$;

-- Painel do barbeiro: conta também as vagas liberadas por falta de confirmação
create or replace function public.barber_stats(p_barber bigint, p_from date, p_to date) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  perform _staff_can(p_barber);
  if p_to < p_from or p_to - p_from > 370 then raise exception 'Período inválido.' using errcode = 'PT400'; end if;
  return (
    select json_build_object(
      'barber_id', br.id, 'barber_name', br.name, 'commission_percent', br.commission_percent, 'open_until', br.open_until,
      'cortes', count(*) filter (where b.status = 'concluido'),
      'faturamento_cents', coalesce(sum(_charged(b)) filter (where b.status = 'concluido'), 0)::int,
      'comissao_cents', coalesce(sum(round(_charged(b) * br.commission_percent / 100.0)) filter (where b.status = 'concluido'), 0)::int,
      'desmarques_cliente', count(*) filter (where b.status = 'cancelado' and b.cancelled_by = 'cliente'),
      'desmarques_barbearia', count(*) filter (where b.status = 'cancelado' and b.cancelled_by = 'barbearia'),
      'sem_confirmacao', count(*) filter (where b.status = 'cancelado' and b.cancelled_by = 'sistema'),
      'faltas', count(*) filter (where b.status = 'faltou'),
      'reagendamentos', coalesce(sum(b.reschedule_count), 0)::int,
      'clientes', count(distinct b.user_id) filter (where b.status = 'concluido'),
      'proximos', (select count(*) from bookings x where x.barber_id = br.id and x.status = 'confirmado' and x.start_at > local_now()))
    from barbers br
    left join bookings b on b.barber_id = br.id and b.start_at::date between p_from and p_to and b.status <> 'expirado'
    where br.id = p_barber
    group by br.id);
end $$;

revoke execute on function public._booking_defaults() from public, anon, authenticated;
revoke execute on function public.attendance_info(text), public.confirm_attendance(text, boolean),
  public.my_confirm_attendance(bigint), public.admin_confirm_attendance(bigint) from public;
grant execute on function public.attendance_info(text), public.confirm_attendance(text, boolean) to anon, authenticated;
grant execute on function public.my_confirm_attendance(bigint), public.admin_confirm_attendance(bigint) to authenticated;
