// Aviso de pagamento do Mercado Pago. Nunca confiamos no corpo: o status vem direto da API do Mercado Pago.
import { rest, rpc } from "../_shared/util.ts";
import { fetchStatus, validSignature } from "../_shared/pagamentos.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("ok");
  const url = new URL(req.url);
  let body: Record<string, any> = {};
  try { body = await req.json(); } catch { /* corpo vazio */ }
  const dataId = String(url.searchParams.get("data.id") ?? body?.data?.id ?? "");
  const type = url.searchParams.get("type") ?? body?.type;
  if (type !== "payment" || !/^\d+$/.test(dataId)) return new Response("ignorado");

  const ok = await validSignature(req.headers.get("x-signature") ?? "", req.headers.get("x-request-id") ?? "", dataId);
  if (!ok) return new Response("assinatura inválida", { status: 401 });

  try {
    const { status, ref } = await fetchStatus(dataId);
    if (status === "approved" && ref && /^\d+$/.test(ref)) {
      const [b] = await rest(`bookings?id=eq.${ref}&select=id,payment_id`);
      if (b && b.payment_id === dataId) await rpc("confirm_payment", { p_booking: b.id });
    }
  } catch (e) {
    console.error(e);
    return new Response("erro", { status: 500 }); // o Mercado Pago tenta de novo
  }
  return new Response("ok");
});
