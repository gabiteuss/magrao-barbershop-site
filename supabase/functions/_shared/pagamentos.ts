// Pix do sinal: Mercado Pago (produção) ou "teste" (simulado)
import { env, safeEqual } from "./util.ts";

const MP = "https://api.mercadopago.com";
export const PROVIDER = env("PAYMENT_PROVIDER", "teste");

function headers(idempotency?: string) {
  const token = env("MP_ACCESS_TOKEN");
  if (!token) throw new Error("MP_ACCESS_TOKEN não configurado");
  const h: Record<string, string> = { Authorization: `Bearer ${token}`, "Content-Type": "application/json" };
  if (idempotency) h["X-Idempotency-Key"] = idempotency;
  return h;
}

export type Pix = { payment_id: string; pix_code: string | null; pix_qr_base64: string | null };

/** expiresLocal: "2026-10-20T10:15:00" no horário de Brasília */
export async function createPix(bookingId: number, cents: number, description: string, email: string, expiresLocal: string): Promise<Pix> {
  if (PROVIDER === "teste") {
    return { payment_id: `teste-${bookingId}`, pix_code: `PIX-TESTE-AGENDAMENTO-${bookingId}-${crypto.randomUUID().slice(0, 8)}`, pix_qr_base64: null };
  }
  const body = {
    transaction_amount: Math.round(cents) / 100,
    description,
    payment_method_id: "pix",
    external_reference: String(bookingId),
    date_of_expiration: `${expiresLocal.slice(0, 19)}.000-03:00`,
    payer: { email },
    notification_url: `${env("SUPABASE_URL")}/functions/v1/mp-webhook`,
    statement_descriptor: "MAGRAO BARBER",
  };
  const r = await fetch(`${MP}/v1/payments`, { method: "POST", headers: headers(`booking-${bookingId}`), body: JSON.stringify(body) });
  if (!r.ok) throw new Error(`Mercado Pago ${r.status}: ${(await r.text()).slice(0, 300)}`);
  const d = await r.json();
  const tx = d.point_of_interaction?.transaction_data ?? {};
  return { payment_id: String(d.id), pix_code: tx.qr_code ?? null, pix_qr_base64: tx.qr_code_base64 ?? null };
}

export async function fetchStatus(paymentId: string): Promise<{ status: string; ref: string | null }> {
  if (PROVIDER === "teste") return { status: "pending", ref: null };
  const r = await fetch(`${MP}/v1/payments/${encodeURIComponent(paymentId)}`, { headers: headers() });
  if (!r.ok) throw new Error(`Consulta Mercado Pago ${r.status}`);
  const d = await r.json();
  return { status: d.status ?? "", ref: d.external_reference ?? null };
}

export async function refund(paymentId: string): Promise<void> {
  if (PROVIDER === "teste") return;
  const r = await fetch(`${MP}/v1/payments/${encodeURIComponent(paymentId)}/refunds`, {
    method: "POST", headers: headers(`refund-${paymentId}`), body: "{}",
  });
  if (!r.ok) throw new Error(`Reembolso ${r.status}: ${(await r.text()).slice(0, 300)}`);
}

/** Valida o cabeçalho x-signature do Mercado Pago (HMAC-SHA256 com a assinatura secreta do webhook). */
export async function validSignature(xSignature: string, xRequestId: string, dataId: string): Promise<boolean> {
  const secret = env("MP_WEBHOOK_SECRET");
  if (!secret) return false;
  const parts = Object.fromEntries(xSignature.split(",").map((p) => p.trim().split("=", 2) as [string, string]));
  if (!parts.ts || !parts.v1) return false;
  const manifest = `id:${dataId.toLowerCase()};request-id:${xRequestId};ts:${parts.ts};`;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(manifest)));
  const hex = [...sig].map((b) => b.toString(16).padStart(2, "0")).join("");
  return safeEqual(hex, parts.v1);
}
