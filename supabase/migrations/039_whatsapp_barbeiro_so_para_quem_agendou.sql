-- O WhatsApp do barbeiro deixa de ser público (qualquer visitante lia em public_info) e passa a ir
-- só para o cliente que tem horário com ele (no agendamento: fim do agendar e Minha conta).
-- Barbeiro sem WhatsApp cadastrado: vem vazio e o site usa o WhatsApp da barbearia.
do $$
declare v_src text; v_new text;
begin
  select pg_get_functiondef(oid) into v_src from pg_proc where proname = 'public_info' and pronamespace = 'public'::regnamespace;
  v_new := replace(v_src, '''photo'', photo,
                   ''whatsapp'', whatsapp) order by id)', '''photo'', photo) order by id)');
  if v_new = v_src then raise exception 'public_info mudou'; end if;
  execute v_new;

  select pg_get_functiondef(oid) into v_src from pg_proc where proname = '_booking_json' and pronamespace = 'public'::regnamespace;
  v_new := replace(v_src, '''barber_id'', b.barber_id, ''barber_name'', br.name,',
                          '''barber_id'', b.barber_id, ''barber_name'', br.name, ''barber_whatsapp'', nullif(br.whatsapp, ''''),');
  if v_new = v_src then raise exception '_booking_json mudou'; end if;
  execute v_new;
end $$;
