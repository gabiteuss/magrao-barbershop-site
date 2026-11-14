-- Segurança antes de abrir o repositório (14/11/2026)

-- 1) WhatsApp e comissão dos barbeiros não podem ser lidos pela API pública.
--    O site usa public_info() e o painel usa admin_barbers(); nenhum lê a tabela direto.
revoke select on public.barbers from anon, authenticated;
grant select (id, name, title, bio, photo, active, open_until) on public.barbers to anon, authenticated;

-- 2) Permissões que sobraram para visitantes e clientes (não usadas pelo site)
revoke truncate, references, trigger on all tables in schema public from anon, authenticated;

-- 3) Função de gatilho não precisa ser chamada pela API
revoke execute on function public._freeze_commission() from public, anon, authenticated;

-- 4) Avisos do Supabase: search_path fixo
alter function public._conta_em(timestamptz) set search_path = public;
alter function public._balcao_desde(timestamptz, timestamptz) set search_path = public;
