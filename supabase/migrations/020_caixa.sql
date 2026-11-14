-- Caixa: cada entrada de dinheiro no período (atendimentos concluídos + pacotes vendidos) com a forma de pagamento.
-- O painel soma por crédito, débito, Pix e dinheiro. Corte pago com pacote não entra (o dinheiro entrou na venda do pacote).
-- Barbeiro vê só os próprios atendimentos; venda de pacote não tem barbeiro, então só o administrador vê.
create or replace function public.staff_cashbox(p_from date, p_to date, p_barber bigint default null) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  v_barber bigint := case when is_admin() then p_barber else my_barber_id() end;
begin
  perform _require_staff();
  if p_to < p_from or p_to - p_from > 370 then raise exception 'Período inválido.' using errcode = 'PT400'; end if;
  return json_build_object(
    'entradas', (select coalesce(json_agg(x order by x.quando desc), '[]') from (
        select 'atendimento' as tipo, b.start_at as quando, p.name as cliente, s.name as item, br.name as barbeiro,
               coalesce(b.pay_method, 'nao_informado') as method, b.online_paid_at is not null as online, _charged(b) as total_cents
        from bookings b join profiles p on p.id = b.user_id join services s on s.id = b.service_id join barbers br on br.id = b.barber_id
        where b.status = 'concluido' and b.pay_method is distinct from 'pacote'
          and b.start_at::date between p_from and p_to and (v_barber is null or b.barber_id = v_barber)
        union all
        select 'pacote', (c.paid_at at time zone 'America/Sao_Paulo'), p.name, c.name, null,
               c.pay_method, c.paid_online, c.price_cents
        from client_packages c join profiles p on p.id = c.user_id
        where v_barber is null and c.status in ('ativo', 'cancelado') and c.paid_at is not null
          and (c.paid_at at time zone 'America/Sao_Paulo')::date between p_from and p_to) x),
    'cortes_pacote', (select count(*) from bookings b
        where b.status = 'concluido' and b.pay_method = 'pacote'
          and b.start_at::date between p_from and p_to and (v_barber is null or b.barber_id = v_barber)));
end $$;

revoke execute on function public.staff_cashbox(date, date, bigint) from public, anon;
grant execute on function public.staff_cashbox(date, date, bigint) to authenticated;
