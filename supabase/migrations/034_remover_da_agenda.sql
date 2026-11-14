-- Agenda: "Desmarcar / remover" vale para qualquer atendimento do dia.
--   Marcado (confirmado/pendente): desmarca, avisa a lista de espera e prepara a mensagem para remarcar.
--   Já concluído (lançado por engano): sai do Caixa e das Comissões (o consumo e o pendente junto).
-- Some da lista da agenda (o painel esconde os desmarcados; dá para mostrar de novo).
create or replace function public.staff_remove(p_id bigint, p_reason text, p_notify boolean default true, p_refund boolean default true) returns json
language plpgsql security definer set search_path = public as $$
declare
  b bookings;
  r json;
begin
  select * into b from bookings where id = p_id;
  if b.id is null then raise exception 'Agendamento não encontrado.' using errcode = 'PT404'; end if;
  perform _staff_can(b.barber_id);

  if b.status in ('confirmado', 'pendente') then
    r := staff_cancel(p_id, p_reason, p_refund);
    if not coalesce(p_notify, true) then
      delete from messages where id = (r->>'message_id')::bigint;
      return json_build_object('ok', true, 'removed', 'desmarcado');
    end if;
    return r::jsonb || '{"removed":"desmarcado"}'::jsonb;
  elsif b.status in ('concluido', 'faltou') then
    update bookings set status = 'cancelado', cancelled_at = now(), cancelled_by = 'barbearia',
           cancel_reason = coalesce(nullif(left(trim(coalesce(p_reason, '')), 200), ''), 'removido da agenda')
    where id = p_id;
    return json_build_object('ok', true, 'removed', 'lancamento');
  end if;
  raise exception 'Esse horário já foi desmarcado.' using errcode = 'PT400';
end $$;

revoke execute on function public.staff_remove(bigint, text, boolean, boolean) from public, anon;
grant execute on function public.staff_remove(bigint, text, boolean, boolean) to authenticated;
