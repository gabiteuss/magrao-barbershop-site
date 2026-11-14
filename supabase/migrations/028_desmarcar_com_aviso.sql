-- Barbeiro desmarca o cliente com motivo e já tem o aviso pronto para mandar no WhatsApp.
-- A mensagem fica na aba Mensagens (com o barbeiro) e o painel abre o WhatsApp com o texto.
alter table public.bookings add column if not exists cancel_reason text;

create or replace function public.staff_cancel(p_id bigint, p_reason text, p_refund boolean default true) returns json
language plpgsql security definer set search_path = public as $$
declare
  b bookings;
  p profiles;
  v_reason text := nullif(left(trim(coalesce(p_reason, '')), 200), '');
  v_child text;
  v_msg bigint;
  r json;
begin
  select * into b from bookings where id = p_id;
  if b.id is null then raise exception 'Agendamento não encontrado.' using errcode = 'PT404'; end if;
  perform _staff_can(b.barber_id);
  select * into p from profiles where id = b.user_id;
  select name into v_child from children where id = b.child_id;

  r := _cancel(p_id, 'barbearia', p_refund);
  update bookings set cancel_reason = v_reason where id = p_id;

  perform enqueue_message(p.phone, 'cancelamento', jsonb_build_array(first_name(p.name),
          fmt_quando(b.start_at) || coalesce(' (de ' || v_child || ')', '') || ' com ' || (select name from barbers where id = b.barber_id),
          coalesce(v_reason, 'imprevisto na barbearia') || '. Para marcar outro horário: ' || setting_text('site_url') || '/agendar'));
  select id into v_msg from messages where to_phone = p.phone and kind = 'cancelamento' order by id desc limit 1;
  update messages set barber_id = b.barber_id where id = v_msg;

  return json_build_object('ok', true, 'refund', r->'refund', 'message_id', v_msg, 'phone', p.phone,
                           'text', (select body from messages where id = v_msg));
end $$;

revoke execute on function public.staff_cancel(bigint, text, boolean) from public, anon;
grant execute on function public.staff_cancel(bigint, text, boolean) to authenticated;

-- Motivo aparece no cartão da agenda
do $$
declare v_src text; v_new text;
begin
  select pg_get_functiondef(oid) into v_src from pg_proc where proname = '_booking_json' and pronamespace = 'public'::regnamespace;
  v_new := replace(v_src, '''cancelled_by'', b.cancelled_by,', '''cancelled_by'', b.cancelled_by, ''cancel_reason'', b.cancel_reason,');
  if v_new = v_src then raise exception '_booking_json mudou; ajuste a migração'; end if;
  execute v_new;
end $$;

-- Marcar "enviada à mão" logo depois de desmarcar (antes da rotina passar a mensagem para "registrado")
do $$
declare v_src text; v_new text;
begin
  select pg_get_functiondef(oid) into v_src from pg_proc where proname = 'admin_message_sent' and pronamespace = 'public'::regnamespace;
  v_new := replace(v_src, 'status in (''registrado'', ''erro'')', 'status in (''pendente'', ''registrado'', ''erro'')');
  if v_new = v_src then raise exception 'admin_message_sent mudou'; end if;
  execute v_new;
end $$;
