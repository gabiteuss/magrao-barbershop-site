-- (Aplicada direto no banco em 29/10/2026, fora do repositório; copiada aqui do histórico de migrações do Supabase.)
-- WhatsApp de cada barbeiro: o cliente fala direto com o barbeiro do horário
alter table public.barbers add column if not exists whatsapp text not null default '';

-- Só números, com 55 na frente (ex.: 5519999999999); vazio = usa o WhatsApp da barbearia
create or replace function public._norm_whatsapp(p text) returns text
language plpgsql immutable set search_path = public as $$
declare v text := regexp_replace(coalesce(p, ''), '\D', '', 'g');
begin
  if v = '' then return ''; end if;
  if length(v) in (10, 11) then v := '55' || v; end if;
  if length(v) not in (12, 13) then
    raise exception 'WhatsApp do barbeiro inválido: digite com DDD, ex.: (19) 99999-9999.' using errcode = 'PT400';
  end if;
  return v;
end $$;
revoke execute on function public._norm_whatsapp(text) from public, anon, authenticated;

create or replace function public.public_info() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'services', (select coalesce(json_agg(json_build_object('id', id, 'name', name, 'description', description,
                   'price_cents', price_cents, 'price_from', price_from, 'duration_min', duration_min) order by sort, id), '[]')
                 from services where active),
    'barbers', (select coalesce(json_agg(json_build_object('id', id, 'name', name, 'title', title, 'bio', bio, 'photo', photo,
                   'whatsapp', whatsapp) order by id), '[]')
                from barbers where active),
    'hours', (select coalesce(json_agg(json_build_object('weekday', wd, 'open', to_char(o, 'HH24:MI'), 'close', to_char(c, 'HH24:MI')) order by wd), '[]')
              from (select w.weekday as wd, min(w.start_time) o, max(w.end_time) c
                    from working_hours w join barbers b on b.id = w.barber_id where b.active group by w.weekday) h),
    'packages', _catalog(),
    'settings', json_build_object('deposit_percent', setting('deposit_percent'), 'cancel_hours', setting('cancel_hours'),
                                  'hold_minutes', setting('hold_minutes'), 'days_ahead', setting('days_ahead'),
                                  'confirm_required', setting('confirm_required'), 'confirm_ask_minutes', setting('confirm_ask_minutes'),
                                  'confirm_deadline_minutes', setting('confirm_deadline_minutes'), 'online_pay', setting('online_pay')),
    'payment_provider', setting_text('payment_provider'))
$$;

create or replace function public.admin_barbers() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  perform _require_staff();
  return (select coalesce(json_agg(json_build_object('id', b.id, 'name', b.name, 'title', b.title, 'bio', b.bio, 'photo', b.photo,
            'active', b.active, 'commission_percent', b.commission_percent, 'open_until', b.open_until, 'whatsapp', b.whatsapp,
            'accounts', (select coalesce(json_agg(p.name order by p.name), '[]') from profiles p where p.barber_id = b.id and p.role = 'barber'),
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
  v_until date := nullif(p->>'open_until', '')::date;
  v_wa text := _norm_whatsapp(p->>'whatsapp');
begin
  perform _require_admin();
  if v_pct not between 0 and 100 then raise exception 'Comissão precisa ser de 0 a 100%%.' using errcode = 'PT400'; end if;
  if v_id is null then
    insert into barbers (name, title, bio, photo, active, commission_percent, whatsapp)
    values (p->>'name', coalesce(p->>'title', 'Barbeiro'), coalesce(p->>'bio', ''), coalesce(p->>'photo', ''),
            coalesce((p->>'active')::boolean, true), v_pct, v_wa)
    returning id into v_id;
  else
    update barbers set name = p->>'name', title = coalesce(p->>'title', 'Barbeiro'), bio = coalesce(p->>'bio', ''),
           photo = coalesce(p->>'photo', ''), active = coalesce((p->>'active')::boolean, true), commission_percent = v_pct,
           whatsapp = case when p ? 'whatsapp' then v_wa else whatsapp end
    where id = v_id;
  end if;
  perform staff_save_schedule(v_id, coalesce(p->'hours', '[]'), v_until);
end $$;
