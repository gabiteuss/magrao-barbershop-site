-- Rotina automática a cada minuto (pg_cron). O endereço é o do projeto Supabase da barbearia.
create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;

-- Segredo aleatório da rotina, gerado e guardado só no Vault
delete from vault.secrets where name = 'worker_secret';
select vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'worker_secret');

select cron.unschedule(jobname) from cron.job where jobname in ('magrao-tick', 'magrao-worker');

-- Expira Pix não pago, agenda lembretes e limpa lista de espera vencida
select cron.schedule('magrao-tick', '* * * * *', $$ select public.tick() $$);

-- Entrega mensagens e reembolsos (só chama a função quando tem trabalho)
select cron.schedule('magrao-worker', '* * * * *', $job$
  select net.http_post(
    url := 'https://xiefcjpkgcdvmhpisrge.supabase.co/functions/v1/worker',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-worker-secret',
               (select decrypted_secret from vault.decrypted_secrets where name = 'worker_secret')),
    body := '{}'::jsonb)
  where exists (select 1 from public.messages where status = 'pendente')
     or exists (select 1 from public.bookings where refund_status = 'pendente')
$job$);
