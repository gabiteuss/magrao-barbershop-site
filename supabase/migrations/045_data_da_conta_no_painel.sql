-- Painel mostra quando o cliente criou a conta no site e, se antes ele era do balcão/encaixe, desde quando.
-- conta_em: dia (horário de Brasília) em que o login foi criado.
-- balcao_desde: dia do cadastro no balcão, só para quem tinha cadastro do balcão antes de criar a conta
--               (a conta assume o cadastro e mantém a data antiga: ver 044_cadastro_assume_balcao).

create or replace function public._conta_em(u_created timestamptz) returns text
language sql immutable as $$
  select to_char(u_created at time zone 'America/Sao_Paulo', 'YYYY-MM-DD')
$$;

create or replace function public._balcao_desde(p_created timestamptz, u_created timestamptz) returns text
language sql immutable as $$
  select case when u_created - p_created > interval '1 minute'
              then to_char(p_created at time zone 'America/Sao_Paulo', 'YYYY-MM-DD') end
$$;

create or replace function public.admin_clients(p_q text default '') returns json
language plpgsql stable security definer set search_path = public as $$
begin
  perform _require_admin();
  return (select coalesce(json_agg(x order by x.created_at desc), '[]') from (
    select p.id, p.name, p.phone, u.email, p.role, p.barber_id, p.created_at, p.has_login, p.pref_pay,
           _conta_em(u.created_at) as conta_em, _balcao_desde(p.created_at, u.created_at) as balcao_desde,
           (select count(*) from bookings b where b.user_id = p.id and b.status = 'concluido') as cortes,
           (select count(*) from bookings b where b.user_id = p.id and b.status = 'faltou') as faltas,
           (select coalesce(sum(greatest(0, c.qty - _pkg_used(c.id))), 0) from client_packages c
             where c.user_id = p.id and c.status = 'ativo' and c.valid_until >= local_now()::date) as cortes_pacote
    from profiles p left join auth.users u on u.id = p.id
    where p_q = '' or p.name ilike '%' || p_q || '%'
       or (regexp_replace(p_q, '\D', '', 'g') <> '' and p.phone like '%' || regexp_replace(p_q, '\D', '', 'g') || '%')
    order by p.created_at desc limit 100) x);
end $$;

create or replace function public.barber_clients(p_barber bigint, p_q text default '') returns json
language plpgsql stable security definer set search_path = public as $$
declare
  v_digits text := regexp_replace(coalesce(p_q, ''), '\D', '', 'g');
begin
  perform _staff_can(p_barber);
  return (select coalesce(json_agg(x order by x.ultima_visita desc nulls last, x.name), '[]') from (
    select p.id, p.name, p.phone, p.has_login,
           _conta_em(u.created_at) as conta_em, _balcao_desde(p.created_at, u.created_at) as balcao_desde,
           count(*) filter (where b.status = 'concluido') as cortes,
           count(*) filter (where b.status = 'cancelado') as desmarques,
           count(*) filter (where b.status = 'faltou') as faltas,
           coalesce(sum(b.reschedule_count), 0)::int as reagendamentos,
           max(b.start_at) filter (where b.status = 'concluido') as ultima_visita,
           min(b.start_at) filter (where b.status = 'confirmado' and b.start_at > local_now()) as proximo
    from bookings b join profiles p on p.id = b.user_id left join auth.users u on u.id = p.id
    where b.barber_id = p_barber and b.status <> 'expirado'
      and (coalesce(p_q, '') = '' or p.name ilike '%' || trim(p_q) || '%' or (length(v_digits) >= 4 and p.phone like '%' || v_digits || '%'))
    group by p.id, u.created_at
    limit 300) x);
end $$;

revoke execute on function public._conta_em(timestamptz), public._balcao_desde(timestamptz, timestamptz) from public, anon;
