-- =====================================================================
-- Magrão Barber Shop · esquema do banco (Supabase / Postgres)
-- Regra de ouro: nenhuma tabela aceita escrita direta do navegador.
-- Toda escrita passa por funções (002_regras.sql) que conferem quem está pedindo.
-- =====================================================================

create extension if not exists btree_gist with schema extensions;

-- Configurações editáveis pelo painel
create table public.settings (
  key   text primary key,
  value text not null
);

create table public.barbers (
  id     bigint generated always as identity primary key,
  name   text not null check (length(name) between 1 and 60),
  title  text not null default 'Barbeiro' check (length(title) <= 40),
  bio    text not null default '' check (length(bio) <= 200),
  photo  text not null default '' check (photo = '' or photo ~ '^(img/|https://)'),
  active boolean not null default true
);

-- Perfil do cliente/equipe (1 para 1 com auth.users)
create table public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  name        text not null check (length(name) between 2 and 80),
  phone       text not null unique check (phone ~ '^55[0-9]{10,11}$'),
  role        text not null default 'client' check (role in ('client', 'barber', 'admin')),
  barber_id   bigint references public.barbers(id) on delete set null,
  privacy_accepted_at timestamptz,
  created_at  timestamptz not null default now()
);

create table public.services (
  id           bigint generated always as identity primary key,
  name         text not null check (length(name) between 1 and 60),
  description  text not null default '' check (length(description) <= 200),
  price_cents  integer not null check (price_cents >= 0),
  price_from   boolean not null default false,          -- "a partir de"
  duration_min integer not null check (duration_min between 5 and 480),
  sort         integer not null default 0,
  active       boolean not null default true
);

-- Expediente. weekday: 0 = domingo ... 6 = sábado
create table public.working_hours (
  id         bigint generated always as identity primary key,
  barber_id  bigint not null references public.barbers(id) on delete cascade,
  weekday    smallint not null check (weekday between 0 and 6),
  start_time time not null,
  end_time   time not null,
  check (end_time > start_time)
);

-- Folgas, férias, almoço extra
create table public.blocks (
  id        bigint generated always as identity primary key,
  barber_id bigint not null references public.barbers(id) on delete cascade,
  start_at  timestamp not null,           -- horário local da barbearia
  end_at    timestamp not null,
  reason    text not null default '' check (length(reason) <= 100),
  check (end_at > start_at)
);

create table public.bookings (
  id               bigint generated always as identity primary key,
  user_id          uuid not null references public.profiles(id) on delete cascade,
  barber_id        bigint not null references public.barbers(id),
  service_id       bigint not null references public.services(id),
  start_at         timestamp not null,
  end_at           timestamp not null,
  status           text not null check (status in ('pendente', 'confirmado', 'concluido', 'faltou', 'cancelado', 'expirado')),
  price_cents      integer not null,
  deposit_cents    integer not null,
  hold_expires_at  timestamp,
  payment_id       text,
  pix_code         text,
  pix_qr_base64    text,
  paid_at          timestamptz,
  refund_status    text check (refund_status in ('pendente', 'reembolsado', 'erro')),
  reminder_sent_at timestamptz,
  moved_by_shop    boolean not null default false,
  moved_from       timestamp,
  cancelled_at     timestamptz,
  cancelled_by     text,
  created_at       timestamp not null,
  check (end_at > start_at),
  -- Rede de segurança: o banco nunca aceita dois horários confirmados sobrepostos no mesmo barbeiro
  constraint no_overlap exclude using gist (
    barber_id with =, tsrange(start_at, end_at) with &&
  ) where (status = 'confirmado')
);
create index bookings_barber_start on public.bookings (barber_id, start_at);
create index bookings_user on public.bookings (user_id, start_at desc);
create index bookings_status on public.bookings (status) where status in ('pendente', 'confirmado');

create table public.waitlist (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  service_id  bigint not null references public.services(id),
  barber_id   bigint references public.barbers(id),
  date        date not null,
  status      text not null default 'aguardando' check (status in ('aguardando', 'avisado', 'atendido', 'cancelado')),
  notified_at timestamptz,
  created_at  timestamptz not null default now()
);
create index waitlist_date on public.waitlist (date, status);

-- Fila de mensagens de WhatsApp (enviadas pela função "worker")
create table public.messages (
  id         bigint generated always as identity primary key,
  to_phone   text not null,
  kind       text not null,
  params     jsonb not null default '[]',
  body       text not null,
  status     text not null default 'pendente' check (status in ('pendente', 'enviado', 'registrado', 'erro')),
  error      text,
  attempts   integer not null default 0,
  created_at timestamptz not null default now(),
  sent_at    timestamptz
);
create index messages_pending on public.messages (id) where status = 'pendente';

-- ---------------------------------------------------------------------
-- Segurança: RLS ligado em tudo. Sem política = ninguém acessa.
-- ---------------------------------------------------------------------
alter table public.settings      enable row level security;
alter table public.barbers       enable row level security;
alter table public.profiles      enable row level security;
alter table public.services      enable row level security;
alter table public.working_hours enable row level security;
alter table public.blocks        enable row level security;
alter table public.bookings      enable row level security;
alter table public.waitlist      enable row level security;
alter table public.messages      enable row level security;

-- Permissões explícitas (o projeto não expõe tabelas novas automaticamente).
-- O navegador só LÊ; o RLS abaixo decide quais linhas. Nada de escrita direta.
revoke all on all tables in schema public from anon, authenticated;
grant select on public.services, public.barbers, public.working_hours to anon, authenticated;
grant select on public.profiles, public.bookings, public.waitlist, public.blocks, public.messages, public.settings to authenticated;
-- Funções do servidor (Edge Functions) usam a chave de serviço
grant all on all tables in schema public to service_role;
grant usage, select on all sequences in schema public to service_role;

-- Funções auxiliares de papel (usadas pelas políticas)
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'admin')
$$;

create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role in ('admin', 'barber'))
$$;

create or replace function public.my_barber_id() returns bigint
language sql stable security definer set search_path = public as $$
  select barber_id from profiles where id = auth.uid()
$$;

-- Leitura pública só do catálogo (sem dado pessoal)
create policy "catalogo publico" on public.services for select to anon, authenticated using (active or public.is_staff());
create policy "barbeiros publicos" on public.barbers for select to anon, authenticated using (active or public.is_staff());
create policy "expediente publico" on public.working_hours for select to anon, authenticated using (true);

-- Dados pessoais: cada um vê o seu; a equipe vê o necessário
create policy "meu perfil" on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_admin()
         or (public.is_staff() and exists (select 1 from bookings b where b.user_id = profiles.id and b.barber_id = public.my_barber_id())));
create policy "meus agendamentos" on public.bookings for select to authenticated
  using (user_id = auth.uid() or public.is_admin() or (public.is_staff() and barber_id = public.my_barber_id()));
create policy "minha lista de espera" on public.waitlist for select to authenticated
  using (user_id = auth.uid() or public.is_staff());
create policy "bloqueios equipe" on public.blocks for select to authenticated using (public.is_staff());
create policy "mensagens admin" on public.messages for select to authenticated using (public.is_admin());
create policy "config admin" on public.settings for select to authenticated using (public.is_admin());

-- ---------------------------------------------------------------------
-- Perfil criado junto com o cadastro (nome e WhatsApp vêm do formulário)
-- ---------------------------------------------------------------------
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_phone text := regexp_replace(coalesce(new.raw_user_meta_data ->> 'phone', ''), '\D', '', 'g');
begin
  if length(v_phone) in (10, 11) then
    v_phone := '55' || v_phone;
  end if;
  insert into public.profiles (id, name, phone, privacy_accepted_at)
  values (new.id,
          left(trim(coalesce(new.raw_user_meta_data ->> 'name', '')), 80),
          v_phone,
          case when new.raw_user_meta_data ->> 'privacy' = 'true' then now() end);
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
