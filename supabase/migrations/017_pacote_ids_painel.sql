-- O painel precisa do cliente e do pacote de origem para "Renovar mês"
create or replace function public._pkg_json(c client_packages, p_staff boolean default false) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'id', c.id, 'kind', c.kind, 'name', c.name, 'service_id', c.service_id, 'package_id', c.package_id,
    'service_name', (select name from services where id = c.service_id),
    'qty', c.qty, 'used', _pkg_used(c.id), 'left', greatest(0, c.qty - _pkg_used(c.id)),
    'price_cents', c.price_cents,
    'status', case when c.status = 'ativo' and c.valid_until < local_now()::date then 'vencido' else c.status end,
    'valid_until', c.valid_until, 'valid_until_fmt', to_char(c.valid_until, 'DD/MM/YYYY'),
    'pay_method', c.pay_method, 'paid_online', c.paid_online, 'receipt_url', c.receipt_url,
    'checkout_url', case when c.status = 'pendente' then c.checkout_url end,
    'plan_link', case when c.status = 'pendente' then (select nullif(plan_link, '') from packages where id = c.package_id) end,
    'created_at', c.created_at, 'created_by', c.created_by,
    'user_id', case when p_staff then c.user_id end,
    'client_name', case when p_staff then (select name from profiles where id = c.user_id) end,
    'client_phone', case when p_staff then (select phone from profiles where id = c.user_id) end)
$$;
revoke execute on function public._pkg_json(client_packages, boolean) from public, anon, authenticated;
