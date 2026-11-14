-- Cliente cadastrado pelo balcão ou num encaixe (com telefone) consegue criar a conta pelo site com o mesmo WhatsApp.
-- Antes o cadastro era bloqueado ("Esse WhatsApp já foi cadastrado pela barbearia"). Agora a conta nova assume
-- o cadastro do balcão: horários, histórico, filhos, pacotes, lista de espera e notas da equipe passam para ela,
-- e os dados que faltavam (e-mail, senha, nascimento, aceite de privacidade) vêm do formulário.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_phone text := regexp_replace(coalesce(new.raw_user_meta_data ->> 'phone', ''), '\D', '', 'g');
  v_birth date;
  v_name text := left(trim(coalesce(new.raw_user_meta_data ->> 'name', '')), 80);
  old profiles;
  v_tmp text;
begin
  if length(v_phone) in (10, 11) then
    v_phone := '55' || v_phone;
  end if;
  if v_phone !~ '^55[0-9]{10,11}$' or v_phone = '5500000000000' then
    raise exception 'WhatsApp inválido. Use DDD + número.' using errcode = 'P0001';
  end if;
  if length(v_name) < 2 then
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

  select * into old from public.profiles where phone = v_phone and not has_login for update;
  if found then
    -- Libera o telefone (número provisório só até o fim desta função), cria o perfil da conta nova
    -- e passa tudo do cadastro do balcão para ela
    loop
      v_tmp := '5501' || lpad((floor(random() * 1000000000))::bigint::text, 9, '0');
      exit when not exists (select 1 from public.profiles where phone = v_tmp);
    end loop;
    update public.profiles set phone = v_tmp where id = old.id;
    insert into public.profiles (id, name, phone, birth_date, privacy_accepted_at, pref_pay, birthday_sent_year, created_at)
    values (new.id, v_name, v_phone, coalesce(v_birth, old.birth_date),
            case when new.raw_user_meta_data ->> 'privacy' = 'true' then now() end,
            old.pref_pay, old.birthday_sent_year, old.created_at);
    update public.bookings        set user_id = new.id where user_id = old.id;
    update public.waitlist        set user_id = new.id where user_id = old.id;
    update public.client_packages set user_id = new.id where user_id = old.id;
    update public.children        set user_id = new.id where user_id = old.id;
    update public.staff_notes     set user_id = new.id where user_id = old.id;
    delete from public.profiles where id = old.id;
    return new;
  end if;

  begin
    insert into public.profiles (id, name, phone, birth_date, privacy_accepted_at)
    values (new.id, v_name, v_phone, v_birth,
            case when new.raw_user_meta_data ->> 'privacy' = 'true' then now() end);
  exception when unique_violation then
    raise exception 'Esse WhatsApp já tem cadastro. Use "Já tenho conta".' using errcode = 'P0001';
  end;
  return new;
end $$;
