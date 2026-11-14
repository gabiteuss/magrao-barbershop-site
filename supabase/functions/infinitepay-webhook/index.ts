// Aviso da InfinitePay de pagamento aprovado. Sem assinatura no aviso, então o pagamento é
// sempre conferido de novo na própria InfinitePay antes de marcar como pago.
import { confirmPaid, str } from "../_shared/infinitepay.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("método não permitido", { status: 405 });
  let b: Record<string, unknown> = {};
  try { b = await req.json(); } catch { return new Response("json inválido", { status: 400 }); }

  const order_nsu = str(b.order_nsu, 60), transaction_nsu = str(b.transaction_nsu, 100), slug = str(b.invoice_slug ?? b.slug, 100);
  if (!/^(ag|pc)[0-9a-z-]+$/.test(order_nsu) || !transaction_nsu || !slug) return new Response("ignorado", { status: 200 });
  try {
    await confirmPaid({ order_nsu, transaction_nsu, slug, receipt_url: str(b.receipt_url, 500), capture_method: str(b.capture_method, 30) });
    return new Response("ok", { status: 200 });
  } catch (e) {
    console.error(e);
    return new Response("erro", { status: 400 }); // 400 = a InfinitePay tenta de novo
  }
});
