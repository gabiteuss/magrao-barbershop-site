-- Apaga tudo o que o teste de pico criou (clientes, agendamentos, mensagens, função e chave).
delete from public.messages where to_phone like '551990%' and to_phone in (select p.phone from public.profiles p join auth.users u on u.id = p.id
                                                                           where u.email like 'loadtest%@teste.invalid');
delete from public.waitlist where user_id in (select id from auth.users where email like 'loadtest%@teste.invalid');
delete from public.bookings where user_id in (select id from auth.users where email like 'loadtest%@teste.invalid');
delete from auth.users where email like 'loadtest%@teste.invalid';
drop function if exists public.loadtest_book(text, uuid, bigint, date, text, bigint);
drop function if exists public.loadtest_users(text);
delete from public.settings where key = 'loadtest_key';
select (select count(*) from auth.users where email like 'loadtest%') as clientes_teste_restantes,
       (select count(*) from public.messages where to_phone like '551990000%') as mensagens_teste_restantes;
