// Rotina chamada pelo pg_cron: envia a fila de WhatsApp e processa reembolsos de sinal.
import { env, rest, rpc, safeEqual } from "../_shared/util.ts";
import { PROVIDER as WA, sendTemplate } from "../_shared/whatsapp.ts";
import { refund } from "../_shared/pagamentos.ts";

const MAX_ATTEMPTS = 3;

Deno.serve(async (req) => {
  // Segredo combinado com o pg_cron (guardado no Vault do banco)
  const secret = env("WORKER_SECRET") || String(await rpc("worker_secret") ?? "");
  if (!secret || !safeEqual(req.headers.get("x-worker-secret") ?? "", secret)) {
    return new Response("proibido", { status: 403 });
  }

  const msgs = await rest("messages?status=eq.pendente&order=id&limit=40&select=id,to_phone,kind,params,attempts");
  for (const m of msgs) {
    let patch: Record<string, unknown>;
    if (WA !== "meta" && WA !== "360dialog") {
      patch = { status: "registrado", sent_at: new Date().toISOString() };
    } else {
      try {
        await sendTemplate(m.to_phone, m.kind, m.params);
        patch = { status: "enviado", sent_at: new Date().toISOString(), attempts: m.attempts + 1 };
      } catch (e) {
        const attempts = m.attempts + 1;
        patch = { status: attempts >= MAX_ATTEMPTS ? "erro" : "pendente", error: String(e).slice(0, 500), attempts };
      }
    }
    await rest(`messages?id=eq.${m.id}`, { method: "PATCH", body: patch });
  }

  const refunds = await rest("bookings?refund_status=eq.pendente&payment_id=not.is.null&select=id,payment_id&limit=20");
  for (const b of refunds) {
    let status = "reembolsado";
    try { await refund(b.payment_id); } catch (e) { console.error(e); status = "erro"; }
    await rest(`bookings?id=eq.${b.id}`, { method: "PATCH", body: { refund_status: status } });
  }
  return new Response(JSON.stringify({ messages: msgs.length, refunds: refunds.length }), { headers: { "Content-Type": "application/json" } });
});
