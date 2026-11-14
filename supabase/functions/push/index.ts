// Chamada pelo banco a cada aviso de horário novo (staff_alerts): manda a notificação para o celular
// do barbeiro do horário e para os do administrador, mesmo com o painel fechado.
import { rest, rpc, safeEqual } from "../_shared/util.ts";
import { sendPush, type Vapid } from "../_shared/webpush.ts";

let vapid: Vapid | null = null;

Deno.serve(async (req) => {
  // mesmo segredo da rotina automática (Vault)
  const secret = String(await rpc("worker_secret") ?? "");
  if (!secret || !safeEqual(req.headers.get("x-worker-secret") ?? "", secret)) {
    return new Response("proibido", { status: 403 });
  }
  const { alert_id } = await req.json().catch(() => ({}));
  if (!Number.isInteger(alert_id)) return new Response("pedido inválido", { status: 400 });

  if (!vapid) {
    const k = await rpc("push_vapid_keys");
    vapid = { publicKey: k.public, privateKey: k.private, subject: "https://xn--magrobarbershop-nkb.com.br" };
  }
  const { alert: a, subs } = await rpc("push_targets", { p_alert: alert_id });
  if (!a || !subs.length) return Response.json({ sent: 0 });

  const payload = JSON.stringify({
    title: `📅 Novo horário · ${a.barber_name}`,
    body: `${a.client_name} · ${a.quando}\n${a.service}`,
    tag: `alerta-${a.id}`,
    url: `/painel.html?dia=${a.date}&barbeiro=${a.barber_id}`,
  });

  const ok: number[] = [], gone: number[] = [];
  await Promise.all(subs.map(async (s: { id: number; endpoint: string; p256dh: string; auth: string }) => {
    try {
      const status = await sendPush(s, payload, vapid!);
      if (status === 404 || status === 410) gone.push(s.id);
      else if (status < 300) ok.push(s.id);
    } catch (e) {
      console.error("push falhou", s.id, e);
    }
  }));
  if (gone.length) await rest(`push_subscriptions?id=in.(${gone.join(",")})`, { method: "DELETE" });
  if (ok.length) await rest(`push_subscriptions?id=in.(${ok.join(",")})`, { method: "PATCH", body: { last_ok_at: new Date().toISOString() } });
  return Response.json({ sent: ok.length, removed: gone.length, total: subs.length });
});
