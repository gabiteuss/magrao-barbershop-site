-- Celular: o barbeiro seleciona vários horários (ou vários dias) e aplica de uma vez, sem janelas de confirmação.

-- Vários horários de um dia: bloquear ou liberar. Horário com cliente não é bloqueado (volta em "com_cliente").
create or replace function public.staff_set_slots(p_barber bigint, p_day date, p_times text[], p_block boolean) returns json
language plpgsql security definer set search_path = public as $$
declare
  t text;
  v_ok int := 0;
  v_cli int := 0;
begin
  perform _staff_can(p_barber);
  foreach t in array coalesce(p_times, '{}') loop
    begin
      perform staff_toggle_slot(p_barber, p_day, t, p_block);
      v_ok := v_ok + 1;
    exception
      when sqlstate 'PT409' then v_cli := v_cli + 1;
      when sqlstate 'PT400' then null;  -- horário que já passou: ignora
    end;
  end loop;
  return json_build_object('feitos', v_ok, 'com_cliente', v_cli);
end $$;

-- Vários dias: fechar (folga o dia inteiro) ou liberar (tira bloqueios e horário especial, volta ao expediente normal).
-- Quem já está marcado nesses dias continua marcado (volta a contagem em "clientes").
create or replace function public.staff_set_days(p_barber bigint, p_days date[], p_open boolean) returns json
language plpgsql security definer set search_path = public as $$
declare
  d date;
  k blocks;
  v_ini timestamp;
  v_fim timestamp;
begin
  perform _staff_can(p_barber);
  if coalesce(array_length(p_days, 1), 0) = 0 then raise exception 'Escolha pelo menos um dia.' using errcode = 'PT400'; end if;
  if array_length(p_days, 1) > 62 then raise exception 'No máximo 62 dias de uma vez.' using errcode = 'PT400'; end if;
  foreach d in array p_days loop
    if d < local_now()::date then continue; end if;
    v_ini := d::timestamp; v_fim := (d + 1)::timestamp;
    -- tira os bloqueios desse dia (corta os que passam para outros dias)
    for k in select * from blocks where barber_id = p_barber and start_at < v_fim and end_at > v_ini loop
      delete from blocks where id = k.id;
      if k.start_at < v_ini then
        insert into blocks (barber_id, start_at, end_at, reason) values (p_barber, k.start_at, v_ini, k.reason);
      end if;
      if k.end_at > v_fim then
        insert into blocks (barber_id, start_at, end_at, reason) values (p_barber, v_fim, k.end_at, k.reason);
      end if;
    end loop;
    if p_open then
      delete from day_hours where barber_id = p_barber and day = d;
    else
      insert into blocks (barber_id, start_at, end_at, reason) values (p_barber, v_ini, v_fim, 'folga');
    end if;
  end loop;
  return json_build_object('dias', array_length(p_days, 1),
    'clientes', (select count(*) from bookings where barber_id = p_barber and status = 'confirmado'
                 and start_at::date = any(p_days) and start_at > local_now()));
end $$;

-- Situação dos próximos 31 dias de um barbeiro: aberto, parcial (tem bloqueio), folga (fechado) ou sem expediente
create or replace function public.staff_days_status(p_barber bigint) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  v_step int := greatest(coalesce(setting('slot_step_min'), 40), 5);
begin
  perform _staff_can(p_barber);
  return (select json_agg(json_build_object('date', d, 'status',
            case when total = 0 then 'sem_expediente'
                 when bloq >= total then 'folga'
                 when bloq > 0 then 'parcial'
                 else 'aberto' end,
            'clientes', cli) order by d)
    from (select g::date d,
                 (select count(*) from _slot_grid(p_barber, g::date, v_step, null, false)) total,
                 (select count(*) from _slot_grid(p_barber, g::date, v_step, null, false) s
                   where exists (select 1 from blocks k where k.barber_id = p_barber and k.start_at < s.slot + make_interval(mins => v_step)
                                   and k.end_at > s.slot)) bloq,
                 (select count(*) from bookings b where b.barber_id = p_barber and b.status = 'confirmado' and b.start_at::date = g::date) cli
          from generate_series(local_now()::date, local_now()::date + 30, interval '1 day') g) x);
end $$;

revoke execute on function public.staff_set_slots(bigint, date, text[], boolean), public.staff_set_days(bigint, date[], boolean),
  public.staff_days_status(bigint) from public, anon;
grant execute on function public.staff_set_slots(bigint, date, text[], boolean), public.staff_set_days(bigint, date[], boolean),
  public.staff_days_status(bigint) to authenticated;
