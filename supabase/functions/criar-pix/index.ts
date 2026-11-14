// Gera (ou devolve) o Pix do sinal de um agendamento do próprio cliente
import { getUser, handler, HttpError, positiveInt, readJson, rest, rpc } from "../_shared/util.ts";
import { createPix } from "../_shared/pagamentos.ts";

Deno.serve(handler(async (req) => {
  const user = await getUser(req);
  const id = positiveInt((await readJson(req)).booking_id, "Agendamento");

  // Lido com o token do cliente: o RLS garante que ele só enxerga o que é dele
  const [b] = await rest(`bookings?id=eq.${id}&select=id,user_id,status,payment_id,deposit_cents,hold_expires_at,services(name)`, { token: user.token });
  if (!b || b.user_id !== user.id) throw new HttpError(404, "Agendamento não encontrado.");
  if (b.status !== "pendente") throw new HttpError(400, "Esse agendamento não está esperando pagamento.");

  if (!b.payment_id) {
    const pix = await createPix(id, b.deposit_cents, `Sinal ${b.services?.name ?? "agendamento"} - Magrão Barber Shop`, user.email, b.hold_expires_at);
    await rest(`bookings?id=eq.${id}&status=eq.pendente&payment_id=is.null`, { method: "PATCH", body: pix });
  }
  return rpc("booking_status", { p_id: id }, user.token);
}));
