-- Bateria de testes das regras do site, rodando dentro do banco.
-- Cria clientes de teste, agenda, conclui, recebe etc. e no fim DESFAZ TUDO (o bloco termina com erro de propósito,
-- então nada fica gravado). O resultado vem na mensagem do erro: "RELATORIO ... N falha(s)".
-- Rodar pelo SQL Editor do Supabase ou pela conexão do Claude.
do $$
declare
  res text[] := '{}';
  v_admin uuid; v_pablo uuid; v_magrao_b bigint := 3; v_pablo_b bigint := 4; v_guil_b bigint := 5;
  v_pai uuid := gen_random_uuid(); v_outro uuid := gen_random_uuid();
  v_day date; v_t1 text; v_t2 text; v_t3 text; v_dur int;
  j json; j2 json; sug json; v_kid bigint; v_kid2 bigint; v_b1 bigint; v_b2 bigint; v_b3 bigint; v_bk bigint;
  pc bigint; pa bigint; n int; s text; e text;
  as_user constant text := 'select set_config(''request.jwt.claims'', json_build_object(''sub'', $1, ''role'', ''authenticated'')::text, true)';
begin
  select id into v_admin from profiles where role = 'admin' order by created_at limit 1;
  select id into v_pablo from profiles where role = 'barber' and barber_id = v_pablo_b limit 1;
  select duration_min into v_dur from services where id = 1;

  -- clientes de teste (somem no fim)
  insert into auth.users (id, instance_id, aud, role, email, raw_user_meta_data, created_at, updated_at)
  values (v_pai, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'teste.pai@teste.invalid',
          '{"name":"Teste Pai","phone":"19900007777","privacy":"true"}', now(), now()),
         (v_outro, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'teste.outro@teste.invalid',
          '{"name":"Teste Outro","phone":"19900008888","privacy":"true"}', now(), now());
  res := res || case when (select phone from profiles where id = v_pai) = '5519900007777'
                     then 'OK    cadastro cria o perfil com WhatsApp normalizado' else 'FALHA cadastro cria o perfil' end;

  -- dia de teste: 2+ dias à frente, Pablo e Guilherme com horário livre
  select (d->>'date')::date into v_day from json_array_elements(available_days(1, v_pablo_b)) d
  where (d->>'free')::int > 8 and (d->>'date')::date >= local_now()::date + 2
    and exists (select 1 from _free_slots(v_guil_b, (d->>'date')::date, v_dur)) limit 1;
  select to_char(t, 'HH24:MI') into v_t1 from _free_slots(v_pablo_b, v_day, v_dur) t order by t offset 3 limit 1;
  res := res || ('INFO  dia de teste ' || v_day || ', horário do pai ' || v_t1);

  ------------------------------------------------------------------ agendamento
  execute as_user using v_pai;
  j := create_booking(1, v_day, v_t1, v_pablo_b, 'local', null); v_b1 := (j->>'id')::bigint;
  res := res || case when j->>'status' = 'confirmado' then 'OK    cliente agenda e fica confirmado' else 'FALHA agendar: ' || (j->>'status') end;

  execute as_user using v_outro;
  begin perform create_booking(1, v_day, v_t1, v_pablo_b, 'local', null); res := res || text 'FALHA outro cliente pegou o mesmo horário';
  exception when others then res := res || ('OK    mesmo horário/barbeiro recusado: ' || sqlerrm); end;

  execute as_user using v_pai;
  begin perform create_booking(1, v_day, v_t1, v_guil_b, 'local', null); res := res || text 'FALHA mesma pessoa em duas cadeiras ao mesmo tempo';
  exception when others then res := res || ('OK    mesma pessoa no mesmo período recusada: ' || sqlerrm); end;

  select to_char(t, 'HH24:MI') into v_t2 from _free_slots(v_guil_b, v_day, v_dur) t
  where t >= (v_day + v_t1::time) + make_interval(mins => v_dur * 2) order by t limit 1;
  begin j := create_booking(1, v_day, v_t2, v_guil_b, 'local', null); v_b2 := (j->>'id')::bigint;
    res := res || text 'OK    regra "um barbeiro só" desligada: agendou com outro barbeiro';
  exception when others then res := res || ('FALHA não deixou agendar com outro barbeiro: ' || sqlerrm); end;

  ------------------------------------------------------------------ filhos
  j := save_my_child(null, '  joão   pedro ');
  v_kid := (j->0->>'id')::bigint;
  res := res || case when j->0->>'name' = 'João Pedro' then 'OK    filho cadastrado com nome arrumado (João Pedro)' else 'FALHA nome do filho: ' || j::text end;

  sug := child_suggestions(v_b1, 1);
  res := res || case when json_array_length(sug) > 0 and (sug->0->>'dist')::numeric = 0
                     then 'OK    sugestão para o filho começa colada ao pai: ' || (sug->0->>'time') || ' com ' || (sug->0->>'barber_name')
                     else 'FALHA sugestões: ' || coalesce(sug::text, 'nenhuma') end;

  begin j := create_booking(1, v_day, v_t1, v_magrao_b, 'local', v_kid); v_b3 := (j->>'id')::bigint;
    res := res || case when j->>'child_name' = 'João Pedro' then 'OK    filho no MESMO horário do pai com outro barbeiro' else 'FALHA filho sem nome no agendamento' end;
  exception when others then res := res || ('FALHA filho no mesmo horário do pai: ' || sqlerrm); end;

  begin perform create_booking(1, v_day, v_t1, v_guil_b, 'local', v_kid); res := res || text 'FALHA filho em duas cadeiras ao mesmo tempo';
  exception when others then res := res || ('OK    filho no mesmo período recusado: ' || sqlerrm); end;

  select body into s from messages where kind = 'confirmacao' order by id desc limit 1;
  res := res || case when s like '%para João Pedro%' then 'OK    confirmação do filho vai para o pai com o nome do filho' else 'FALHA confirmação do filho: ' || coalesce(s, '-') end;

  execute as_user using v_outro;
  begin perform create_booking(1, v_day, v_t2, v_pablo_b, 'local', v_kid); res := res || text 'FALHA cliente usou o filho de outro';
  exception when others then res := res || ('OK    não dá para usar filho de outra conta: ' || sqlerrm); end;
  res := res || case when json_array_length(my_children()) = 0 then 'OK    cliente não vê filhos de outra conta' else 'FALHA vê filhos de outra conta' end;

  ------------------------------------------------------------------ mensagens por barbeiro
  res := res || case when (select barber_id from messages where kind = 'confirmacao' order by id desc limit 1) = v_magrao_b
                     then 'OK    mensagem guarda o barbeiro certo' else 'FALHA barbeiro da mensagem' end;
  execute as_user using v_pablo;
  select count(*) into n from json_array_elements(admin_messages()) x
  where (select barber_id from messages where id = (x->>'id')::bigint) is distinct from v_pablo_b;
  res := res || case when n = 0 then 'OK    barbeiro vê só as mensagens dos clientes dele' else 'FALHA barbeiro vê mensagens de outros: ' || n end;
  select id into v_bk from messages where barber_id = v_magrao_b and status = 'registrado' order by id desc limit 1;
  perform admin_message_sent(v_bk);
  res := res || case when (select status from messages where id = v_bk) = 'registrado'
                     then 'OK    barbeiro não marca como enviada a mensagem de outro' else 'FALHA marcou mensagem de outro barbeiro' end;
  execute as_user using v_admin;
  perform admin_message_sent(v_bk);
  res := res || case when (select status from messages where id = v_bk) = 'enviado_manual'
                     then 'OK    administrador marca "enviada à mão"' else 'FALHA admin não marcou' end;

  ------------------------------------------------------------------ lembrete 30 min
  update bookings set start_at = local_now() + interval '10 minutes', end_at = local_now() + interval '50 minutes',
         created_at = local_now() - interval '1 day', reminder_sent_at = null where id = v_b3;
  perform tick();
  select body into s from messages where kind = 'lembrete' order by id desc limit 1;
  res := res || case when s like '%(de João Pedro)%' then 'OK    lembrete sai com o nome do filho: ' || s else 'FALHA lembrete: ' || coalesce(s, '-') end;

  ------------------------------------------------------------------ concluir, consumo, pendente, caixa
  execute as_user using v_admin;
  perform admin_save_product('{"name":"Teste Refri","price_cents":600}');
  perform admin_save_product('{"name":"Teste Cerveja","price_cents":800}');
  select id into pc from products where name = 'Teste Refri'; select id into pa from products where name = 'Teste Cerveja';

  -- corte do pai: Pix + 2 refris
  perform admin_set_status(v_b1, 'concluido', true, null, 'pix', jsonb_build_array(jsonb_build_object('product_id', pc, 'qty', 2)));
  -- corte do filho: pendente + 1 cerveja
  perform admin_set_status(v_b3, 'concluido', true, null, 'pendente', jsonb_build_array(jsonb_build_object('product_id', pa, 'qty', 1)));
  j := _booking_json(v_b3, true);
  res := res || case when (j->>'pending_cents')::int = (select price_cents from bookings where id = v_b3) + 800
                     then 'OK    pendente = corte + cerveja (' || (j->>'pending_cents') || ' centavos) na conta do pai' else 'FALHA pendente: ' || (j->>'pending_cents') end;

  j := staff_cashbox(v_day, v_day);
  select coalesce(sum((x->>'total_cents')::int), 0) into n from json_array_elements(j->'entradas') x where x->>'method' = 'pix'
    and (x->>'id')::bigint = v_b1;
  res := res || case when n = (select price_cents from bookings where id = v_b1) + 1200
                     then 'OK    Caixa: Pix do pai = corte + 2 refris' else 'FALHA Caixa Pix: ' || n end;
  res := res || case when exists (select 1 from json_array_elements(j->'pendentes') x where (x->>'id')::bigint = v_b3)
                     then 'OK    Caixa lista o pendente do filho' else 'FALHA pendente fora do Caixa' end;
  res := res || case when not exists (select 1 from json_array_elements(j->'entradas') x where (x->>'id')::bigint = v_b3)
                     then 'OK    pendente não conta como dinheiro recebido' else 'FALHA pendente contou no Caixa' end;

  perform staff_settle(v_b3, 'dinheiro');
  j := staff_cashbox(local_now()::date, local_now()::date);
  select coalesce(sum((x->>'total_cents')::int), 0) into n from json_array_elements(j->'entradas') x
  where (x->>'id')::bigint = v_b3 and x->>'method' = 'dinheiro';
  res := res || case when n = (select price_cents from bookings where id = v_b3) + 800
                     then 'OK    Receber: entra no Caixa de hoje em dinheiro' else 'FALHA receber: ' || n end;

  perform staff_fix_pay_method(v_b1, 'debito');
  res := res || case when (select pay_method from bookings where id = v_b1) = 'debito'
                       and not exists (select 1 from booking_items where booking_id = v_b1 and pay_method <> 'debito')
                     then 'OK    corrigir forma muda o corte e o consumo' else 'FALHA corrigir forma' end;

  ------------------------------------------------------------------ permissões
  execute as_user using v_pablo;
  begin perform staff_cashbox(v_day, v_day); res := res || text 'FALHA barbeiro abriu o Caixa';
  exception when others then res := res || ('OK    barbeiro não abre o Caixa: ' || sqlerrm); end;
  begin perform admin_payment_summary(v_day, v_day); res := res || text 'FALHA barbeiro viu resumo por forma';
  exception when others then res := res || text 'OK    barbeiro não vê o resumo por forma de pagamento'; end;
  select count(*) into n from json_array_elements(admin_commissions(v_day, v_day)) x where (x->>'barber_id')::bigint <> v_pablo_b;
  res := res || case when n = 0 then 'OK    barbeiro vê só a própria comissão' else 'FALHA comissão de outros visível' end;
  begin perform staff_fix_pay_method(v_b3, 'pix'); res := res || text 'FALHA barbeiro corrigiu atendimento de outro';
  exception when others then res := res || text 'OK    barbeiro não corrige atendimento de outro barbeiro'; end;

  execute as_user using v_pai;
  begin perform admin_agenda(v_day, null); res := res || text 'FALHA cliente viu a agenda da equipe';
  exception when others then res := res || text 'OK    cliente não vê a agenda da equipe'; end;
  begin perform staff_settle(v_b3, 'pix'); res := res || text 'FALHA cliente deu baixa em pendente';
  exception when others then res := res || text 'OK    cliente não dá baixa em pendente'; end;
  begin perform admin_save_product('{"name":"Hack","price_cents":1}'); res := res || text 'FALHA cliente cadastrou produto';
  exception when others then res := res || text 'OK    cliente não cadastra consumível'; end;

  ------------------------------------------------------------------ balcão: corte do filho na conta do pai
  execute as_user using v_admin;
  select to_char(t, 'HH24:MI') into v_t3 from _free_slots(v_pablo_b, v_day, v_dur, null, false) t order by t desc limit 1;
  j := admin_create_booking(v_outro, 1, v_day, v_t3, v_pablo_b, false, false, ' lucas ');
  res := res || case when j->>'child_name' = 'Lucas' and exists (select 1 from children where user_id = v_outro and name = 'Lucas')
                     then 'OK    balcão: corte do filho fica na conta do pai e cadastra o filho' else 'FALHA balcão filho: ' || j::text end;

  ------------------------------------------------------------------ vários serviços no mesmo horário
  execute as_user using v_outro;
  select x->>'time' into v_t3 from json_array_elements((day_grid(4, v_day, v_magrao_b, array[11, 8]::bigint[])->0)->'slots') x
  where x->>'status' = 'livre' limit 1;
  j := create_booking(4, v_day, v_t3, v_magrao_b, 'local', null, array[11, 8]::bigint[]);
  res := res || case when j->>'service_name' = (select name from services where id = 4) || ' + ' || (select name from services where id = 11) || ' + ' || (select name from services where id = 8)
                       and (j->>'price_cents')::int = (select sum(price_cents) from services where id in (4, 11, 8))
                       and (j->>'end_at')::timestamp - (j->>'start_at')::timestamp = make_interval(mins => (select sum(duration_min)::int from services where id in (4, 11, 8)))
                     then 'OK    vários serviços: ' || (j->>'service_name') || ' · tempo e preço somados' else 'FALHA vários serviços: ' || j::text end;
  begin perform create_booking(4, v_day, v_t3, v_magrao_b, 'pacote', null, array[11]::bigint[]); res := res || text 'FALHA pacote com serviço a mais';
  exception when others then res := res || text 'OK    pacote não vale com serviço a mais'; end;

  ------------------------------------------------------------------ fim: relatório e desfaz tudo
  n := (select count(*) from unnest(res) r where r like 'FALHA%');
  raise exception E'RELATORIO\n%\n\n% teste(s), % falha(s)', array_to_string(res, E'\n'),
    (select count(*) from unnest(res) r where r not like 'INFO%'), n;
end $$;
