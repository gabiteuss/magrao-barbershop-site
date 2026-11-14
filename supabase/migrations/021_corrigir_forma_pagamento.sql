-- Corrigir a forma de pagamento de um atendimento já concluído (ex.: marcou Pix, mas foi débito).
-- Não vale para pago pelo site nem com pacote. Barbeiro só corrige os próprios atendimentos.
create or replace function public.staff_fix_pay_method(p_id bigint, p_method text) returns json
language plpgsql security definer set search_path = public as $$
declare
  b bookings;
begin
  select * into b from bookings where id = p_id;
  if b.id is null then raise exception 'Agendamento não encontrado.' using errcode = 'PT404'; end if;
  perform _staff_can(b.barber_id);
  if b.status <> 'concluido' then raise exception 'Só atendimentos concluídos.' using errcode = 'PT400'; end if;
  if b.online_paid_at is not null or b.pay_method = 'pacote' then
    raise exception 'Esse atendimento foi pago pelo site ou com pacote.' using errcode = 'PT400';
  end if;
  if coalesce(p_method, '') not in ('dinheiro', 'credito', 'debito', 'pix') then
    raise exception 'Forma de pagamento inválida.' using errcode = 'PT400';
  end if;
  update bookings set pay_method = p_method where id = p_id;
  return json_build_object('ok', true);
end $$;

revoke execute on function public.staff_fix_pay_method(bigint, text) from public, anon;
grant execute on function public.staff_fix_pay_method(bigint, text) to authenticated;

-- Caixa passa a devolver o id do atendimento (para o botão Corrigir)
create or replace function public.staff_cashbox(p_from date, p_to date, p_barber bigint default null) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  v_barber bigint := case when is_admin() then p_barber else my_barber_id() end;
begin
  perform _require_staff();
  if p_to < p_from or p_to - p_from > 370 then raise exception 'Período inválido.' using errcode = 'PT400'; end if;
  return json_build_object(
    'entradas', (select coalesce(json_agg(x order by x.quando desc), '[]') from (
        select 'atendimento' as tipo, b.id, b.start_at as quando, p.name as cliente, s.name as item, br.name as barbeiro,
               coalesce(b.pay_method, 'nao_informado') as method, b.online_paid_at is not null as online, _charged(b) as total_cents
        from bookings b join profiles p on p.id = b.user_id join services s on s.id = b.service_id join barbers br on br.id = b.barber_id
        where b.status = 'concluido' and b.pay_method is distinct from 'pacote'
          and b.start_at::date between p_from and p_to and (v_barber is null or b.barber_id = v_barber)
        union all
        select 'pacote', c.id, (c.paid_at at time zone 'America/Sao_Paulo'), p.name, c.name, null,
               c.pay_method, c.paid_online, c.price_cents
        from client_packages c join profiles p on p.id = c.user_id
        where v_barber is null and c.status in ('ativo', 'cancelado') and c.paid_at is not null
          and (c.paid_at at time zone 'America/Sao_Paulo')::date between p_from and p_to) x),
    'cortes_pacote', (select count(*) from bookings b
        where b.status = 'concluido' and b.pay_method = 'pacote'
          and b.start_at::date between p_from and p_to and (v_barber is null or b.barber_id = v_barber)));
end $$;
