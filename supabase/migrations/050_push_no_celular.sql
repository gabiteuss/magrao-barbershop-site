-- Notificação no celular (push), mesmo com o painel fechado ou a tela desligada.
-- Cada barbeiro ativa no próprio celular ("Receber avisos no celular" no painel). A cada aviso de horário
-- novo (staff_alerts) o banco chama a função "push", que manda a notificação para o celular do barbeiro do
-- horário e para os do administrador.
-- As chaves VAPID ficam só no Vault: 'push_vapid_public' e 'push_vapid_private' (criadas fora deste arquivo).

create table if not exists public.push_subscriptions (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  device text,
  created_at timestamptz not null default now(),
  last_ok_at timestamptz
);
alter table public.push_subscriptions enable row level security;  -- só pelas funções abaixo

-- chave pública para o celular se inscrever
create or replace function public.push_public_key() returns text
language plpgsql stable security definer set search_path = public as $$
begin
  perform _require_staff();
  return (select decrypted_secret from vault.decrypted_secrets where name = 'push_vapid_public');
end $$;

create or replace function public.push_subscribe(p_endpoint text, p_p256dh text, p_auth text, p_device text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _require_staff();
  if coalesce(p_endpoint, '') !~ '^https://' or coalesce(p_p256dh, '') = '' or coalesce(p_auth, '') = '' then
    raise exception 'Inscrição inválida.' using errcode = 'PT400';
  end if;
  insert into push_subscriptions (user_id, endpoint, p256dh, auth, device)
  values (auth.uid(), p_endpoint, p_p256dh, p_auth, left(p_device, 200))
  on conflict (endpoint) do update set user_id = excluded.user_id, p256dh = excluded.p256dh,
    auth = excluded.auth, device = excluded.device, created_at = now();
end $$;

create or replace function public.push_unsubscribe(p_endpoint text) returns void
language sql security definer set search_path = public as $$
  delete from push_subscriptions where endpoint = p_endpoint and user_id = auth.uid();
$$;

-- usado só pela função "push" (service_role): o aviso e os celulares que devem receber
create or replace function public.push_targets(p_alert bigint) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'alert', (select json_build_object('id', a.id, 'client_name', a.client_name, 'service', a.service,
                'barber_id', a.barber_id, 'barber_name', br.name, 'date', to_char(a.start_at, 'YYYY-MM-DD'),
                'quando', fmt_quando(a.start_at))
              from staff_alerts a join barbers br on br.id = a.barber_id where a.id = p_alert),
    'subs', (select coalesce(json_agg(json_build_object('id', s.id, 'endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth)), '[]')
             from push_subscriptions s join profiles p on p.id = s.user_id
             join staff_alerts a on a.id = p_alert
             where p.role = 'admin' or (p.role = 'barber' and p.barber_id = a.barber_id)));
$$;

create or replace function public.push_vapid_keys() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'public', (select decrypted_secret from vault.decrypted_secrets where name = 'push_vapid_public'),
    'private', (select decrypted_secret from vault.decrypted_secrets where name = 'push_vapid_private'))
$$;

-- aviso novo -> chama a função "push" (mesmo segredo da rotina automática)
create or replace function public._push_new_alert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from push_subscriptions) then
    perform net.http_post(
      url := 'https://xiefcjpkgcdvmhpisrge.supabase.co/functions/v1/push',
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-worker-secret', worker_secret()),
      body := jsonb_build_object('alert_id', new.id));
  end if;
  return null;
end $$;

drop trigger if exists push_new_alert on public.staff_alerts;
create trigger push_new_alert after insert on public.staff_alerts
  for each row execute function public._push_new_alert();

revoke all on function public.push_public_key(), public.push_subscribe(text, text, text, text),
  public.push_unsubscribe(text), public.push_targets(bigint), public.push_vapid_keys(), public._push_new_alert()
  from public, anon, authenticated;
grant execute on function public.push_public_key(), public.push_subscribe(text, text, text, text),
  public.push_unsubscribe(text) to authenticated;
grant execute on function public.push_targets(bigint), public.push_vapid_keys(), public.push_public_key() to service_role;
grant select, insert, update, delete on public.push_subscriptions to service_role;
