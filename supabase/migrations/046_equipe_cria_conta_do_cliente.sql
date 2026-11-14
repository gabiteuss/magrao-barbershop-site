-- Barbeiro (ou administrador) ajuda o cliente do balcão/encaixe a ter conta no site:
-- cria a conta por ele (função "staff-criar-conta") ou manda o link de cadastro pelo WhatsApp.
-- Esta função diz se quem pede pode criar a conta desse cliente e devolve os dados do cadastro do balcão.
-- Barbeiro: só clientes que já foram atendidos/marcados com ele. Administrador: qualquer cliente do balcão.
create or replace function public.staff_client_for_account(p_user uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  p profiles;
begin
  perform _require_staff();
  select * into p from profiles where id = p_user;
  if not found or p.phone = '5500000000000' then
    raise exception 'Cliente não encontrado.' using errcode = 'PT404';
  end if;
  if p.has_login then
    raise exception 'Esse cliente já tem conta no site.' using errcode = 'PT400';
  end if;
  if not is_admin() and not exists (select 1 from bookings b where b.user_id = p.id and b.barber_id = my_barber_id()) then
    raise exception 'Você só pode criar a conta de clientes seus.' using errcode = 'PT403';
  end if;
  return json_build_object('name', p.name, 'phone', p.phone, 'birth_date', p.birth_date);
end $$;

revoke execute on function public.staff_client_for_account(uuid) from public, anon;
grant execute on function public.staff_client_for_account(uuid) to authenticated;
