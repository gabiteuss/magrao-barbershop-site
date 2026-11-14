-- O Magrão prefere conversar com o cliente que marcar dois horários com barbeiros diferentes
-- (pode ser pai e filho) a bloquear pelo site. A regra "um barbeiro por cliente" fica desligada;
-- para religar: settings one_barber = 1. Continua valendo: no máximo 3 horários e nunca dois no mesmo período.
insert into public.settings (key, value) values ('one_barber', '0')
on conflict (key) do update set value = '0';

create or replace function public._client_barber(p_user uuid) returns bigint
language sql stable security definer set search_path = public as $$
  select barber_id from bookings
  where coalesce(setting('one_barber'), 0) = 1
    and user_id = p_user and status = 'confirmado' and start_at > local_now()
  order by start_at limit 1
$$;
