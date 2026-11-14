// Abre o pagamento online (InfinitePay) de um horário ou de um pacote do próprio cliente
import { getUser, handler, HttpError, positiveInt, readJson, rest, rpc } from "../_shared/util.ts";
import { createLink, siteBase } from "../_shared/infinitepay.ts";

Deno.serve(handler(async (req) => {
  const user = await getUser(req);
  const body = await readJson(req);
  const booking = body.booking_id != null ? positiveInt(body.booking_id, "Agendamento") : null;
  const pkg = body.package_id != null ? positiveInt(body.package_id, "Pacote") : null;
  if (!booking === !pkg) throw new HttpError(400, "Pedido inválido.");

  // Conferências (dono, status, valor) ficam no banco, rodando com o token do cliente
  const o = await rpc("start_online_payment", { p_booking: booking, p_package: pkg }, user.token);

  // Plano com assinatura criada no app da InfinitePay: o cliente assina por lá
  if (o.plan_link) return { url: o.plan_link, external: true };
  if (o.checkout_url) return { url: o.checkout_url };

  const url = await createLink(o, `${await siteBase(req)}/conta.html?pagamento=1`);
  const table = booking ? "bookings" : "client_packages";
  await rest(`${table}?order_nsu=eq.${encodeURIComponent(o.order_nsu)}`, { method: "PATCH", body: { checkout_url: url } });
  return { url };
}));
