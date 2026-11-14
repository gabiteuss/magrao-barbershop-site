-- Ajustes pedidos pelo verificador de segurança do Supabase

-- search_path fixo nas funções utilitárias
alter function public.fmt_quando(timestamp) set search_path = public;
alter function public.fmt_dia(date) set search_path = public;
alter function public.first_name(text) set search_path = public;
alter function public.msg_text(text, jsonb) set search_path = public;
alter function public.local_now() set search_path = public;

-- Visitante sem login não precisa das funções de papel: políticas separadas por tipo de acesso
drop policy "catalogo publico" on public.services;
drop policy "barbeiros publicos" on public.barbers;
create policy "catalogo visitante" on public.services for select to anon using (active);
create policy "catalogo logado" on public.services for select to authenticated using (active or public.is_staff());
create policy "barbeiros visitante" on public.barbers for select to anon using (active);
create policy "barbeiros logado" on public.barbers for select to authenticated using (active or public.is_staff());
revoke execute on function public.is_admin(), public.is_staff(), public.my_barber_id() from anon;
