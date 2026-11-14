-- Cada barbeiro também envia à mão as mensagens dos próprios clientes (lembrete, confirmação…).
-- A mensagem guarda de qual barbeiro é; o barbeiro vê só as dele e o administrador vê todas.
alter table public.messages add column if not exists barber_id bigint references public.barbers(id);

-- O nome do barbeiro já vai nos parâmetros da mensagem; a posição depende do tipo
create or replace function public._message_barber() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_pos integer := case new.kind when 'confirmacao' then 2 when 'lembrete' then 2
                                 when 'confirmar_presenca' then 2 when 'remarcado' then 3 end;
begin
  if new.barber_id is null and v_pos is not null then
    new.barber_id := (select id from barbers where name = new.params->>v_pos limit 1);
  end if;
  return new;
end $$;
revoke execute on function public._message_barber() from public, anon, authenticated;

drop trigger if exists messages_barber on public.messages;
create trigger messages_barber before insert on public.messages for each row execute function public._message_barber();

-- Mensagens que já existem
update public.messages m set barber_id = b.id
from public.barbers b
where m.barber_id is null
  and b.name = m.params->>(case m.kind when 'remarcado' then 3 else 2 end)
  and m.kind in ('confirmacao', 'lembrete', 'confirmar_presenca', 'remarcado');

create or replace function public.admin_messages() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  perform _require_staff();
  return (select coalesce(json_agg(row_to_json(m) order by m.id desc), '[]')
          from (select id, to_phone, kind, body, status, error, created_at from messages
                where is_admin() or barber_id = my_barber_id()
                order by id desc limit 100) m);
end $$;

create or replace function public.admin_message_sent(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require_staff();
  update messages set status = 'enviado_manual', sent_at = now()
  where id = p_id and status in ('registrado', 'erro') and (is_admin() or barber_id = my_barber_id());
end $$;
