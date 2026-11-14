-- Dados iniciais. Tudo pode ser alterado depois pelo painel.

insert into public.settings (key, value) values
  ('deposit_percent', '0'),        -- sinal no Pix (%): 0 = sem sinal, paga na barbearia
  ('reminder_minutes', '15'),      -- lembrete X minutos antes
  ('hold_minutes', '15'),          -- tempo para pagar o Pix
  ('cancel_hours', '2'),           -- devolve o sinal se cancelar com X horas de antecedência
  ('slot_step_min', '30'),         -- intervalo entre horários oferecidos
  ('min_lead_min', '30'),          -- antecedência mínima para agendar
  ('days_ahead', '30'),            -- agenda aberta X dias à frente
  ('waitlist_notify_count', '3'),  -- quantos da lista de espera avisar quando abre vaga
  ('site_url', 'https://seu-site.workers.dev'),
  ('payment_provider', 'teste'),
  ('allowed_origins', 'https://magraobarbershop.com.br,https://www.magraobarbershop.com.br,https://seu-site.workers.dev,http://localhost:8080')
on conflict (key) do nothing;

-- Tabela de preços da barbearia (durações estimadas: confira no painel)
insert into public.services (name, description, price_cents, price_from, duration_min, sort) values
  ('Social e Sobrancelha',          'Corte social com sobrancelha na navalha', 3500, false, 40, 1),
  ('Degradê e Sobrancelha',         'Degradê com sobrancelha na navalha',      4000, false, 45, 2),
  ('Social e Barba',                'Corte social com barba completa',         5500, false, 60, 3),
  ('Degradê e Barba',               'Degradê com barba completa',              6000, false, 60, 4),
  ('Barba Premium com Vaporizador', 'Toalha quente, vapor e navalha',          4000, false, 40, 5),
  ('Barba',                         'Barba na navalha',                        2800, false, 30, 6),
  ('Pezinho ou Sobrancelha',        'Acabamento rápido',                       1500, false, 15, 7),
  ('Luzes',                         'Luzes no cabelo',                         5000, true,  90, 8),
  ('Platinado',                     'Valor final conforme o cabelo',          12000, true, 180, 9),
  ('Pigmentação',                   'Pigmentação de cabelo ou barba',          2500, true,  30, 10),
  ('Alisamento',                    'Valor final conforme o cabelo',           2500, true,  60, 11),
  ('Selagem',                       'Valor final conforme o cabelo',           8000, true,  90, 12),
  ('Hidratação',                    'Hidratação dos fios',                     1500, true,  20, 13),
  ('Limpeza de Pele',               'Limpeza facial',                          2500, false, 30, 14),
  ('Depilação Nasal',               'Com cera',                                1500, false, 10, 15);

-- Barbeiro e expediente (mesmo horário do Google Maps; domingo fechado). Ajuste no painel.
with b as (
  insert into public.barbers (name, title, bio, photo)
  values ('Willian', 'Barbeiro', 'Degradê, social e freestyle.', '')
  returning id
)
insert into public.working_hours (barber_id, weekday, start_time, end_time)
select b.id, h.d, h.s::time, h.e::time
from b, (values (1, '07:00', '20:00'), (2, '07:00', '20:00'), (3, '07:00', '20:00'),
                (4, '06:00', '20:00'), (5, '06:00', '21:00'), (6, '06:00', '17:00')) h(d, s, e);
