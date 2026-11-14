// InfinitePay: link de pagamento (crédito em até 12x ou Pix) e conferência do pagamento.
// Segredo: INFINITEPAY_HANDLE = InfiniteTag da barbearia (sem o $).
// Sem o segredo e com payment_provider = 'teste' no banco, roda em modo teste (nada é cobrado).
import { env, HttpError, rest, rpc } from "./util.ts";

const API = "https://api.checkout.infinitepay.io";
export const HANDLE = env("INFINITEPAY_HANDLE").replace(/^\$/, "").trim();

export type Order = { order_nsu: string; amount: number; description: string; name: string; phone: string };

async function setting(key: string): Promise<string> {
  const rows = await rest(`settings?key=eq.${key}&select=value`);
  return String(rows?.[0]?.value ?? "");
}

/** Modo teste: só quando não há InfiniteTag e o banco está marcado como teste. */
export async function testMode(): Promise<boolean> {
  if (HANDLE) return false;
  if ((await setting("payment_provider")) === "teste") return true;
  throw new HttpError(503, "Pagamento online ainda não configurado.");
}

/** Endereço do site para onde o cliente volta depois de pagar. */
export async function siteBase(req: Request): Promise<string> {
  const origin = req.headers.get("origin") ?? "";
  const allowed = (await setting("allowed_origins")).split(",").map((s) => s.trim());
  return allowed.includes(origin) ? origin : await setting("site_url");
}

export async function createLink(o: Order, redirectUrl: string): Promise<string> {
  if (await testMode()) {
    const q = new URLSearchParams({ order_nsu: o.order_nsu, transaction_nsu: "teste-" + crypto.randomUUID().slice(0, 8), slug: "teste", capture_method: "pix" });
    return `${redirectUrl}&${q}`;
  }
  const r = await fetch(`${API}/links`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      handle: HANDLE,
      order_nsu: o.order_nsu,
      redirect_url: redirectUrl,
      webhook_url: `${env("SUPABASE_URL")}/functions/v1/infinitepay-webhook`,
      items: [{ quantity: 1, price: o.amount, description: o.description.slice(0, 120) }],
      customer: { name: o.name.slice(0, 100), phone_number: "+" + o.phone },
    }),
  });
  const data = await r.json().catch(() => ({}));
  const url = data?.url ?? data?.payment_url ?? data?.link;
  if (!r.ok || typeof url !== "string" || !url.startsWith("https://")) {
    console.error("infinitepay links", r.status, JSON.stringify(data).slice(0, 500));
    throw new HttpError(502, "Não deu para abrir o pagamento agora. Tente de novo em instantes.");
  }
  return url;
}

/**
 * Confere direto na InfinitePay se o pedido foi pago e, se foi, marca no banco.
 * Nunca confia só no que chegou no navegador ou no webhook.
 */
export async function confirmPaid(p: { order_nsu: string; transaction_nsu: string; slug: string; receipt_url?: string; capture_method?: string }) {
  let paid = false, amount = 0, method = p.capture_method ?? "";
  if (await testMode()) {
    paid = p.slug === "teste" && p.transaction_nsu.startsWith("teste-");
    amount = 100_000_000;
  } else {
    const r = await fetch(`${API}/payment_check`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ handle: HANDLE, order_nsu: p.order_nsu, transaction_nsu: p.transaction_nsu, slug: p.slug }),
    });
    const data = await r.json().catch(() => ({}));
    if (!r.ok) {
      console.error("infinitepay payment_check", r.status, JSON.stringify(data).slice(0, 500));
      throw new HttpError(502, "Não deu para conferir o pagamento agora.");
    }
    paid = data?.paid === true;
    amount = Number(data?.paid_amount ?? data?.amount ?? 0);
    method = String(data?.capture_method ?? method);
  }
  if (!paid) return { paid: false };
  const res = await rpc("online_mark_paid", {
    p_order: p.order_nsu, p_paid: amount, p_method: method, p_tx: p.transaction_nsu, p_receipt: p.receipt_url ?? null,
  });
  return { paid: true, ...res };
}

export const str = (v: unknown, max = 200) => (typeof v === "string" ? v.slice(0, max) : "");
