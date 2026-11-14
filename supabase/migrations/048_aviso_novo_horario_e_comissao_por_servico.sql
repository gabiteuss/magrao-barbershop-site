-- 1) Aviso de horário novo para o barbeiro: quando o CLIENTE marca pelo site, o barbeiro recebe
--    a mensagem no WhatsApp dele (fila de mensagens; sai sozinha quando o WhatsApp oficial estiver ligado)
--    e o painel aberto mostra o alerta no canto da tela (staff_alerts).
-- 2) Comissão por serviço: cada serviço pode ter a % que vai para o barbeiro (o resto é da casa).
--    Vazio = vale a % de cada barbeiro (aba Comissões). Barbeiro com 100% (o dono) continua com 100%.

-- ------------------------------------------------------------------ 2) comissão por serviço
alter table public.services add column if not exists commission_percent integer
  check (commission_percent between 0 and 100);

-- com vários serviços no mesmo horário, a % fica proporcional ao preço de cada um (por isso numeric)
alter table public.bookings alter column commission_percent type numeric(6,3);

create or replace function public._commission_for(b bookings) returns numeric
language sql stable security definer set search_path = public as $$
  select case when br.commission_percent >= 100 then 100::numeric
    else coalesce(
      (select round(sum(s.price_cents * coalesce(s.commission_percent, br.commission_percent))::numeric / nullif(sum(s.price_cents), 0), 3)
       from services s where s.id = b.service_id or s.id = any(b.extra_service_ids)),
      (select round(avg(coalesce(s.commission_percent, br.commission_percent)), 3)
       from services s where s.id = b.service_id or s.id = any(b.extra_service_ids)),
      br.commission_percent) end
  from barbers br where br.id = b.barber_id
$$;
revoke execute on function public._commission_for(bookings) from public, anon, authenticated;

create or replace function public._freeze_commission()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'concluido' and new.commission_percent is null then
    new.commission_percent := _commission_for(new);
  end if;
  return new;
end $$;

-- mesma senha da aba Comissões; vale para os próximos atendimentos concluídos
create or replace function public.admin_service_commission(p_token text, p_service bigint, p_percent integer)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _require_admin();
  perform _require_commission_token(p_token);
  if p_percent is not null and p_percent not between 0 and 100 then
    raise exception 'Comissão precisa ser de 0 a 100%%.' using errcode = 'PT400';
  end if;
  update services set commission_percent = p_percent where id = p_service;
  if not found then raise exception 'Serviço não encontrado.' using errcode = 'PT404'; end if;
end $$;
revoke all on function public.admin_service_commission(text, bigint, integer) from public, anon;
grant execute on function public.admin_service_commission(text, bigint, integer) to authenticated;

-- ------------------------------------------------------------------ 1) aviso de horário novo
create table if not exists public.staff_alerts (
  id bigint generated always as identity primary key,
  barber_id bigint not null references public.barbers(id) on delete cascade,
  booking_id bigint references public.bookings(id) on delete cascade,
  client_name text not null,
  service text not null,
  start_at timestamp not null,
  created_at timestamptz not null default now()
);
create index if not exists staff_alerts_created on public.staff_alerts (created_at);
alter table public.staff_alerts enable row level security;  -- só pelas funções abaixo

-- texto igual ao modelo "novo_agendamento" (docs/modelos-whatsapp.md)
do $$
declare v_src text; v_new text;
begin
  v_src := pg_get_functiondef('public.msg_text(text, jsonb)'::regprocedure);
  v_new := replace(v_src, '    else p::text end',
    '    when ''novo_agendamento'' then format(''Novo horário, %s! %s marcou %s para %s. Os detalhes estão no painel da Magrão Barber Shop. 💈'', p->>0, p->>1, p->>2, p->>3)
    else p::text end');
  if v_new = v_src then raise exception 'msg_text mudou'; end if;
  execute v_new;
end $$;

-- Só horário marcado pelo próprio cliente (no site): encaixe e "+ Agendar cliente" da equipe não avisam.
-- Com sinal no Pix, avisa quando o pagamento confirma (pendente -> confirmado).
create or replace function public._alert_new_booking() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  br barbers;
  v_client text;
  v_service text;
begin
  if new.status <> 'confirmado' or new.walk_in then return null; end if;
  if tg_op = 'INSERT' then
    if auth.uid() is distinct from new.user_id then return null; end if;
  elsif old.status <> 'pendente' then
    return null;
  end if;

  select * into br from barbers where id = new.barber_id;
  select coalesce((select c.name || ' (filho de ' || first_name(p.name) || ')' from children c where c.id = new.child_id), p.name)
    into v_client from profiles p where p.id = new.user_id;
  v_service := _service_label(new);

  delete from staff_alerts where created_at < now() - interval '7 days';
  insert into staff_alerts (barber_id, booking_id, client_name, service, start_at)
  values (br.id, new.id, coalesce(v_client, 'Cliente'), v_service, new.start_at);

  if coalesce(br.whatsapp, '') <> '' then
    insert into messages (to_phone, kind, params, body, barber_id)
    select br.whatsapp, 'novo_agendamento', x.params, msg_text('novo_agendamento', x.params), br.id
    from (select jsonb_build_array(first_name(br.name), coalesce(v_client, 'Cliente'), v_service, fmt_quando(new.start_at)) as params) x;
  end if;
  return null;
end $$;
revoke execute on function public._alert_new_booking() from public, anon, authenticated;

drop trigger if exists alert_new_booking on public.bookings;
create trigger alert_new_booking after insert or update of status on public.bookings
  for each row execute function public._alert_new_booking();

-- Painel aberto pergunta a cada poucos segundos. Sem p_after: só devolve o último id (não repete avisos antigos).
-- Barbeiro vê só os dele; administrador vê de todos.
create or replace function public.staff_alerts(p_after bigint default null) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  v_barber bigint := case when is_admin() then null else my_barber_id() end;
begin
  perform _require_staff();
  if p_after is null then
    return json_build_object('last', (select coalesce(max(id), 0) from staff_alerts), 'alerts', '[]'::json);
  end if;
  return (
    select json_build_object('last', greatest(p_after, coalesce(max(x.id), p_after)),
                             'alerts', coalesce(json_agg(x order by x.id), '[]'))
    from (select a.id, a.booking_id, a.client_name, a.service, br.name as barber_name, a.barber_id,
                 to_char(a.start_at, 'YYYY-MM-DD') as date, fmt_quando(a.start_at) as quando
          from staff_alerts a join barbers br on br.id = a.barber_id
          where a.id > p_after and a.created_at > now() - interval '1 day'
            and (v_barber is null or a.barber_id = v_barber)
          order by a.id limit 20) x);
end $$;
revoke all on function public.staff_alerts(bigint) from public, anon;
grant execute on function public.staff_alerts(bigint) to authenticated;
