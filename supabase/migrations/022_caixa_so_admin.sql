-- Caixa e resumo por forma de pagamento: só o administrador.
-- Barbeiro continua vendo os próprios cortes e a comissão (admin_commissions, Meu painel)
-- e pode corrigir a forma de pagamento dos próprios atendimentos na agenda.
do $$
declare v_src text;
begin
  for v_src in
    select replace(pg_get_functiondef(oid), 'perform _require_staff();', 'perform _require_admin();')
    from pg_proc where pronamespace = 'public'::regnamespace and proname in ('staff_cashbox', 'admin_payment_summary')
  loop
    execute v_src;
  end loop;
end $$;
