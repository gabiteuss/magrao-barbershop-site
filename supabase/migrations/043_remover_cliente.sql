-- Administrador remove um cliente (aba Clientes). O telefone e o e-mail ficam livres para ele se cadastrar de novo.
-- O histórico do caixa e das comissões não some: os cortes e pacotes pagos passam para o cadastro "Cliente avulso",
-- com o nome do cliente guardado no atendimento. Filhos, lista de espera, notas e mensagens saem junto.
-- Cliente com login: esta função prepara tudo e a função "admin-remover-cliente" apaga o login
-- (o perfil sai pelo gatilho on_auth_user_deleted). Cliente de balcão: o perfil é apagado aqui mesmo.
create or replace function public.admin_remove_client(p_user uuid) returns json
language plpgsql security definer set search_path = public as $$
declare
  p profiles;
  v_avulso uuid;
begin
  perform _require_admin();
  select * into p from profiles where id = p_user for update;
  if not found then
    raise exception 'Cliente não encontrado.' using errcode = 'PT404';
  end if;
  if p.role <> 'client' then
    raise exception 'Essa conta é da equipe. Mude o acesso para "Cliente" antes de remover.' using errcode = 'PT400';
  end if;
  if p.phone = '5500000000000' then
    raise exception 'O cadastro "Cliente avulso" não pode ser removido.' using errcode = 'PT400';
  end if;
  if exists (select 1 from bookings where user_id = p_user and status in ('pendente', 'confirmado')) then
    raise exception 'Esse cliente tem horário marcado. Desmarque antes de remover.' using errcode = 'PT400';
  end if;

  select id into v_avulso from profiles where phone = '5500000000000';
  if v_avulso is null then
    v_avulso := gen_random_uuid();
    insert into profiles (id, name, phone, has_login) values (v_avulso, 'Cliente avulso', '5500000000000', false);
  end if;

  -- Histórico continua no caixa e nas comissões, com o nome de quem foi atendido
  update bookings b set
    walkin_name = coalesce(b.walkin_name,
                           (select c.name || ' (filho de ' || p.name || ')' from children c where c.id = b.child_id),
                           p.name),
    user_id = v_avulso
  where b.user_id = p_user;
  delete from client_packages where user_id = p_user and paid_at is null;
  update client_packages set user_id = v_avulso where user_id = p_user;
  delete from messages where to_phone = p.phone;

  if not p.has_login then
    delete from profiles where id = p_user;  -- filhos, lista de espera e notas saem em cascata
  end if;
  return json_build_object('ok', true, 'has_login', p.has_login);
end $$;

revoke execute on function public.admin_remove_client(uuid) from public, anon;
grant execute on function public.admin_remove_client(uuid) to authenticated;
