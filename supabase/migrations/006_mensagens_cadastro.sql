-- Cadastro: mensagens claras para WhatsApp repetido/inválido e nome vazio (em vez do erro técnico do banco)
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
  begin
    insert into public.profiles (id, name, phone, privacy_accepted_at)
    values (new.id,
            left(trim(new.raw_user_meta_data ->> 'name'), 80),
            v_phone,
            case when new.raw_user_meta_data ->> 'privacy' = 'true' then now() end);
  exception when unique_violation then
    raise exception 'Esse WhatsApp já tem cadastro. Use "Já tenho conta".' using errcode = 'P0001';
  end;
  return new;
end $$;
