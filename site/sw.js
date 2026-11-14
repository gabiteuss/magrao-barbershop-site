// Service worker do painel: mostra a notificação de horário novo (push) mesmo com o painel fechado.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", e => e.waitUntil(self.clients.claim()));

self.addEventListener("push", e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch { d = { body: e.data?.text() }; }
  e.waitUntil(self.registration.showNotification(d.title || "📅 Novo horário marcado", {
    body: d.body || "Abra o painel para ver.",
    icon: "/img/icone-180.png",
    badge: "/img/icone-96.png",
    tag: d.tag || "novo-horario",
    renotify: true,
    requireInteraction: true,
    vibrate: [400, 150, 400, 150, 400, 150, 800],
    data: { url: d.url || "/painel.html" },
  }));
});

self.addEventListener("notificationclick", e => {
  e.notification.close();
  const url = new URL(e.notification.data?.url || "/painel.html", self.location.origin).href;
  e.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    const painel = wins.find(w => new URL(w.url).pathname === "/painel.html");
    if (painel) { await painel.focus(); return painel.navigate(url).catch(() => {}); }
    return self.clients.openWindow(url);
  })());
});
