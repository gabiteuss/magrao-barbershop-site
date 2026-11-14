-- Prepara o teste de pico de agendamento: 500 clientes de teste + função que agenda em nome deles.
-- Apagar tudo depois com tests/carga_limpar.sql.
insert into public.settings (key, value) values ('loadtest_key', md5(random()::text || clock_timestamp()::text))
on conflict (key) do update set value = excluded.value;

insert into auth.users (id, instance_id, aud, role, email, raw_user_meta_data, created_at, updated_at)
select gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'loadtest' || i || '@teste.invalid',
       jsonb_build_object('name', 'Teste Carga ' || lpad(i::text, 3, '0'), 'phone', '1990' || lpad(i::text, 7, '0'), 'privacy', 'true'),
       now(), now()
from generate_series(1, 500) i;

-- Lista dos clientes de teste (só com a chave)
create or replace function public.loadtest_users(p_key text) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if p_key is distinct from (select value from settings where key = 'loadtest_key') then
    raise exception 'chave inválida' using errcode = 'PT403';
  end if;
  return (select json_agg(id order by email) from auth.users where email like 'loadtest%@teste.invalid');
end $$;

-- Agenda como se fosse o cliente de teste (mesmo caminho do site: create_booking com trava e checagens)
create or replace function public.loadtest_book(p_key text, p_user uuid, p_service bigint, p_date date, p_time text, p_barber bigint) returns json
language plpgsql security definer set search_path = public as $$
begin
  if p_key is distinct from (select value from settings where key = 'loadtest_key')
     or not exists (select 1 from auth.users where id = p_user and email like 'loadtest%@teste.invalid') then
    raise exception 'chave inválida' using errcode = 'PT403';
  end if;
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  return create_booking(p_service, p_date, p_time, p_barber, 'local', null);
end $$;

revoke execute on function public.loadtest_users(text), public.loadtest_book(text, uuid, bigint, date, text, bigint) from public;
grant execute on function public.loadtest_users(text), public.loadtest_book(text, uuid, bigint, date, text, bigint) to anon, authenticated;

select value as chave from settings where key = 'loadtest_key';
