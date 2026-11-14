-- Sem o WhatsApp oficial, as mensagens ficam "registrado". O painel ganha um botão que abre o
-- WhatsApp com o texto pronto; ao clicar, a mensagem é marcada como enviada à mão para ninguém mandar duas vezes.
alter table public.messages drop constraint messages_status_check;
alter table public.messages add constraint messages_status_check
  check (status in ('pendente', 'enviado', 'registrado', 'erro', 'enviado_manual'));

create or replace function public.admin_message_sent(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require_admin();
  update messages set status = 'enviado_manual', sent_at = now() where id = p_id and status in ('registrado', 'erro');
end $$;

revoke execute on function public.admin_message_sent(bigint) from public, anon;
grant execute on function public.admin_message_sent(bigint) to authenticated;
