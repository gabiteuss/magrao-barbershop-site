-- 1) Agenda e Caixa mostram quando um pendente foi recebido (fica em cinza: "recebido no Pix").
-- 2) Correção: clientes sem cadastro dividem o cadastro "Cliente avulso"; a dívida de um não pode
--    aparecer nos outros ("cliente deve"), e o Caixa mostra o nome digitado no atendimento.
-- 3) Cliente avulso não pode ficar pendente também pelo "Corrigir pagamento" (não tem conta para cobrar).
do $$
declare v_src text; v_new text;
begin
  -- _booking_json: data do recebimento + dívida do cliente sem contar o cadastro avulso
  select pg_get_functiondef(oid) into v_src from pg_proc where proname = '_booking_json' and pronamespace = 'public'::regnamespace;
  v_new := replace(v_src,
    '''client_debt_cents'', case when p_staff then (select coalesce(sum(_pending_cents(x.id)), 0) from bookings x where x.user_id = b.user_id and x.status = ''concluido'') end,',
    '''client_debt_cents'', case when p_staff then (select coalesce(sum(_pending_cents(x.id)), 0) from bookings x where x.user_id = b.user_id and x.status = ''concluido''
                              and (p.phone <> ''5500000000000'' or x.id = b.id)) end,
    ''settled_at'', b.settled_at,');
  if v_new = v_src then raise exception '_booking_json mudou'; end if;
  execute v_new;

  -- Caixa: nome digitado no pendente avulso + recebidos do período (para mostrar em cinza)
  select pg_get_functiondef(oid) into v_src from pg_proc where proname = 'staff_cashbox' and pronamespace = 'public'::regnamespace;
  v_new := replace(v_src,
    'select b.id, b.start_at as quando, p.name as cliente, p.phone,',
    'select b.id, b.start_at as quando, coalesce(b.walkin_name, p.name) as cliente, case when p.phone = ''5500000000000'' then null else p.phone end as phone,');
  v_new := replace(v_new,
    'where b.status = ''concluido'' and _pending_cents(b.id) > 0 and (v_barber is null or b.barber_id = v_barber)) x));',
    'where b.status = ''concluido'' and _pending_cents(b.id) > 0 and (v_barber is null or b.barber_id = v_barber)) x),
    ''recebidos'', (select coalesce(json_agg(x order by x.recebido_em desc), ''[]'') from (
        select b.id, b.start_at as quando, coalesce(b.walkin_name, p.name) as cliente,
               (select name from children where id = b.child_id) as filho, _service_label(b) as servico, br.name as barbeiro,
               b.pay_method as method, b.settled_at as recebido_em,
               _charged(b) + coalesce((select sum(i.qty * i.unit_cents) from booking_items i where i.booking_id = b.id), 0)::int as total_cents
        from bookings b join profiles p on p.id = b.user_id join barbers br on br.id = b.barber_id
        where b.status = ''concluido'' and b.settled_at is not null
          and (b.settled_at at time zone ''America/Sao_Paulo'')::date between p_from and p_to
          and (v_barber is null or b.barber_id = v_barber)) x));');
  if position('''recebidos''' in v_new) = 0 or position('coalesce(b.walkin_name, p.name) as cliente, case when' in v_new) = 0 then
    raise exception 'staff_cashbox mudou';
  end if;
  execute v_new;

  -- Corrigir pagamento: pendente só para cliente com cadastro
  select pg_get_functiondef(oid) into v_src from pg_proc where proname = 'staff_fix_pay_method' and pronamespace = 'public'::regnamespace;
  v_new := replace(v_src, '  if b.online_paid_at is null and b.pay_method is distinct from ''pacote'' then',
    '  if p_method = ''pendente'' and (select phone from profiles where id = b.user_id) = ''5500000000000'' then
    raise exception ''Cliente sem cadastro não pode ficar pendente: cadastre o telefone dele no + Agendar cliente.'' using errcode = ''PT400'';
  end if;
  if b.online_paid_at is null and b.pay_method is distinct from ''pacote'' then');
  if v_new = v_src then raise exception 'staff_fix_pay_method mudou'; end if;
  execute v_new;
end $$;
