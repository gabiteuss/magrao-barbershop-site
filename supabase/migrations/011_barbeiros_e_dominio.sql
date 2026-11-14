-- =====================================================================
-- Ajustes feitos direto no banco em 19 e 20/10/2026, registrados aqui para o
-- repositório refletir o que está no ar. Pode rodar de novo sem duplicar nada.
-- =====================================================================

-- Equipe inicial da barbearia (a comissão de cada um se ajusta no painel).
-- O expediente começa igual ao do Willian (horário do Google Maps); cada um ajusta no painel.
insert into public.barbers (name, title, bio, commission_percent)
select v.name, v.title, v.bio, v.pct
from (values ('Magrão', 'Dono e barbeiro', 'Na cadeira desde 2015.', 100),
             ('Pablo', 'Barbeiro', '', 60),
             ('Gui', 'Barbeiro', '', 60)) v(name, title, bio, pct)
where not exists (select 1 from public.barbers b where b.name = v.name);

insert into public.working_hours (barber_id, weekday, start_time, end_time)
select b.id, w.weekday, w.start_time, w.end_time
from public.barbers b
cross join public.working_hours w
where b.name in ('Magrão', 'Pablo', 'Gui')
  and w.barber_id = (select id from public.barbers where name = 'Willian')
  and not exists (select 1 from public.working_hours x where x.barber_id = b.id);

-- Endereços que podem chamar as funções do servidor (CORS).
-- magrãobarbershop.com.br = xn--magrobarbershop-nkb.com.br (forma técnica do domínio com til).
update public.settings
set value = 'https://seu-site.workers.dev,https://xn--magrobarbershop-nkb.com.br,https://www.xn--magrobarbershop-nkb.com.br,https://magraobarbershop.com.br,https://www.magraobarbershop.com.br,http://localhost:8080'
where key = 'allowed_origins';

-- Endereço usado nos links das mensagens: continua o workers.dev até o domínio estar no ar.
-- Quando o domínio funcionar, trocar por https://xn--magrobarbershop-nkb.com.br
update public.settings set value = 'https://seu-site.workers.dev' where key = 'site_url';
