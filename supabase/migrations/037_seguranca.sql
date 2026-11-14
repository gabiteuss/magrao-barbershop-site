-- Melhorias de segurança (27/10/2026)

-- 1) Sinal no Pix não pode ser ligado enquanto o pagamento estiver em modo "teste":
--    nesse modo o próprio cliente consegue se marcar como pago (botão "Simular pagamento").
do $$
declare v_src text; v_new text;
begin
  select pg_get_functiondef(oid) into v_src from pg_proc where proname = 'admin_set_config' and pronamespace = 'public'::regnamespace;
  v_new := replace(v_src, '    update settings set value = v::text where key = k;
  end loop;',
    '    if k = ''deposit_percent'' and v > 0 and coalesce(setting_text(''payment_provider''), ''teste'') = ''teste'' then
      raise exception ''O sinal no Pix só pode ser ligado com o pagamento de verdade configurado (hoje está em modo teste).'' using errcode = ''PT400'';
    end if;
    update settings set value = v::text where key = k;
  end loop;');
  if v_new = v_src then raise exception 'admin_set_config mudou'; end if;
  execute v_new;

  -- e por garantia: em modo teste o agendamento nunca cobra sinal, mesmo se alguém mudar o valor direto no banco
  select pg_get_functiondef(oid) into v_src from pg_proc where proname = 'create_booking' and pronamespace = 'public'::regnamespace;
  v_new := replace(v_src, 'v_dep := case when p_pay = ''local'' then',
                          'v_dep := case when p_pay = ''local'' and coalesce(setting_text(''payment_provider''), ''teste'') <> ''teste'' then');
  if v_new = v_src then raise exception 'create_booking mudou'; end if;
  execute v_new;
end $$;

-- 2) Endereços que podem chamar as funções do servidor: sai o localhost (só servia para testes no computador).
--    O endereço antigo workers.dev fica até o redirecionamento novo estar publicado no Cloudflare.
update public.settings
set value = array_to_string(array_remove(string_to_array(value, ','), 'http://localhost:8080'), ',')
where key = 'allowed_origins';

-- 3) Avisos do Supabase: funções sem search_path fixo
alter function public._charged(bookings) set search_path = public;
alter function public._is_birthday(date, date) set search_path = public;
