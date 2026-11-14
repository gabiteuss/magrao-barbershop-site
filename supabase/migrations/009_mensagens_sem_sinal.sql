-- Agendamento sem sinal: mensagens sem falar de Pix/sinal
create or replace function public.msg_text(p_kind text, p jsonb) returns text
language sql immutable set search_path = public as $$
  select case p_kind
    when 'confirmacao'  then format('Olá, %s! Seu horário na Magrão Barber Shop está confirmado: %s com %s em %s. Até lá! 💈', p->>0, p->>1, p->>2, p->>3)
    when 'lembrete'     then format('Fala, %s! Passando pra lembrar: seu horário é hoje às %s com %s. Estamos te esperando! 💈', p->>0, p->>1, p->>2)
    when 'lista_espera' then format('Olá, %s! Abriu um horário em %s na Magrão Barber Shop. Corre pra garantir: %s', p->>0, p->>1, p->>2)
    when 'remarcado'    then format('Olá, %s! A Magrão Barber Shop precisou mudar seu horário de %s para %s com %s. Se não puder, cancele pelo site: %s', p->>0, p->>1, p->>2, p->>3, p->>4)
    when 'cancelamento' then format('Olá, %s! Seu horário de %s foi cancelado. %s', p->>0, p->>1, p->>2)
    else p::text end
$$;

-- Sinal desligado (o dono pode religar em Painel → Configurações)
update public.settings set value = '0' where key = 'deposit_percent';
