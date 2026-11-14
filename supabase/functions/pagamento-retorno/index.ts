// O cliente voltou da página da InfinitePay: confere o pagamento e atualiza o horário/pacote
import { getUser, handler, HttpError, readJson, rest } from "../_shared/util.ts";
import { confirmPaid, str } from "../_shared/infinitepay.ts";

Deno.serve(handler(async (req) => {
  const user = await getUser(req);
  const b = await readJson(req);
  const order_nsu = str(b.order_nsu, 60), transaction_nsu = str(b.transaction_nsu, 100), slug = str(b.slug, 100);
  if (!/^(ag|pc)[0-9a-z-]+$/.test(order_nsu) || !transaction_nsu || !slug) throw new HttpError(400, "Pedido inválido.");

  const table = order_nsu.startsWith("ag") ? "bookings" : "client_packages";
  const [row] = await rest(`${table}?order_nsu=eq.${encodeURIComponent(order_nsu)}&select=user_id`);
  if (!row || row.user_id !== user.id) throw new HttpError(404, "Pedido não encontrado.");

  return confirmPaid({ order_nsu, transaction_nsu, slug, receipt_url: str(b.receipt_url, 500), capture_method: str(b.capture_method, 30) });
}));
