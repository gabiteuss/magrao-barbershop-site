-- Textos das mensagens iguais aos modelos que serão aprovados na Meta (docs/modelos-whatsapp.md).
-- Regra da Meta: o texto do modelo não pode terminar com uma variável (ex.: o link), então todos
-- terminam com uma frase fixa.
create or replace function public.msg_text(p_kind text, p jsonb) returns text
language sql immutable set search_path = public as $$
  select case p_kind
    when 'confirmacao'  then format('Olá, %s! Seu horário na Magrão Barber Shop está confirmado: %s com %s em %s. Até lá! 💈', p->>0, p->>1, p->>2, p->>3)
    when 'lembrete'     then format('Fala, %s! Passando pra lembrar: seu horário é hoje às %s com %s. Estamos te esperando! 💈', p->>0, p->>1, p->>2)
    when 'lista_espera' then format('Olá, %s! Abriu um horário em %s na Magrão Barber Shop. Corre pra garantir pelo link: %s. Quem agendar primeiro fica com a vaga.', p->>0, p->>1, p->>2)
    when 'remarcado'    then format('Olá, %s! A Magrão Barber Shop precisou mudar seu horário de %s para %s com %s. Se não puder, cancele pelo site: %s. Qualquer dúvida, é só responder aqui.', p->>0, p->>1, p->>2, p->>3, p->>4)
    when 'cancelamento' then format('Olá, %s! Seu horário de %s foi cancelado. Motivo: %s. Qualquer dúvida, é só responder aqui.', p->>0, p->>1, p->>2)
    when 'confirmar_presenca' then format('Olá, %s! Você vem hoje? %s com %s às %s. Confirme até as %s pelo link: %s. Sem confirmação, o horário é liberado para outro cliente.', p->>0, p->>1, p->>2, p->>3, p->>4, p->>5)
    when 'aniversario'  then format('Parabéns, %s! 🎉 A Magrão Barber Shop deseja um feliz aniversário. Seu presente: %s. Agende pelo link: %s. Te esperamos!', p->>0, p->>1, p->>2)
    else p::text end
$$;
