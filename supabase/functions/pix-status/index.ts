// Consulta se o Pix do cliente já caiu (a tela do Pix chama a cada poucos segundos)
import { getUser, handler, HttpError, positiveInt, readJson, rest, rpc } from "../_shared/util.ts";
import { fetchStatus, PROVIDER } from "../_shared/pagamentos.ts";

Deno.serve(handler(async (req) => {
  const user = await getUser(req);
  const body = await readJson(req);
  const id = positiveInt(body.booking_id, "Agendamento");

  const [b] = await rest(`bookings?id=eq.${id}&select=id,user_id,status,payment_id`, { token: user.token });
  if (!b || b.user_id !== user.id) throw new HttpError(404, "Agendamento não encontrado.");

  if (b.status === "pendente" && b.payment_id) {
    if (PROVIDER === "teste") {
      if (body.simular === true) await rpc("confirm_payment", { p_booking: id });
    } else if ((await fetchStatus(b.payment_id)).status === "approved") {
      await rpc("confirm_payment", { p_booking: id });
    }
  }
  return rpc("booking_status", { p_id: id }, user.token);
}));
