// Painel da equipe: agenda, remanejar, serviços, barbeiros, clientes, mensagens, configurações
const $ = id => document.getElementById(id);
let ME, BARBERS = [], PRODUCTS = [];
const isAdmin = () => ME?.role === "admin";
// Nome de quem vai cortar: o filho aparece com o nome do pai (dono da conta)
const who = b => b.walkin_name ? b.walkin_name : b.child_name ? `${b.child_name} (filho de ${b.client_name})` : b.client_name;
const todayStr = () => new Date().toLocaleDateString("sv-SE");
const addDays = (iso, n) => { const d = new Date(iso + "T12:00"); d.setDate(d.getDate() + n); return d.toLocaleDateString("sv-SE"); };
const barberOptions = (withAll) => (withAll ? `<option value="">Todos os barbeiros</option>` : "")
  + BARBERS.filter(b => b.active).map(b => `<option value="${b.id}">${esc(b.name)}</option>`).join("");

// ---------------------------------------------------------------- login
async function boot() {
  ME = await currentUser();
  const staff = ME && ME.role !== "client";
  $("login").hidden = staff; $("app").hidden = !staff;
  $("no-access").hidden = !ME || staff;
  $("logout").hidden = !ME;
  if (!staff) return authForm($("auth"), boot);
  $("who").textContent = `${ME.name} · ${isAdmin() ? "administrador" : "barbeiro (moderador)"}`;
  $("tab-equipe").textContent = isAdmin() ? "Equipe" : "Meu painel";
  document.querySelectorAll("[data-admin]").forEach(b => b.hidden = !isAdmin());
  [BARBERS, PRODUCTS] = await Promise.all([rpc("admin_barbers"), rpc("admin_products").catch(() => [])]);
  $("barber-filter").innerHTML = barberOptions(isAdmin());
  $("rm-barber").innerHTML = barberOptions(isAdmin());
  $("bl-barber").innerHTML = barberOptions(false);
  $("cx-barber").innerHTML = barberOptions(true);
  if (!isAdmin()) {
    for (const id of ["barber-filter", "rm-barber", "bl-barber"]) { $(id).value = ME.barber_id; $(id).disabled = true; }
  }
  $("date").value = todayStr();
  // veio de uma notificação no celular: abre o dia (e o barbeiro) do horário novo
  const q = new URLSearchParams(location.search);
  if (/^\d{4}-\d{2}-\d{2}$/.test(q.get("dia") || "")) {
    $("date").value = q.get("dia");
    if (isAdmin() && BARBERS.some(b => String(b.id) === q.get("barbeiro"))) $("barber-filter").value = q.get("barbeiro");
    history.replaceState(null, "", location.pathname);
  }
  showTab("agenda");
  $("notes").hidden = false;
  loadNotes();
  startIdleLogout();
  startAlerts();
  setupPush();
}

// ---------------------------------------------------------------- avisos no celular (push)
// Cada barbeiro ativa no próprio celular. Depois disso o horário novo chega como notificação,
// mesmo com o painel fechado, a tela desligada ou em outro app. No iPhone precisa abrir o painel
// pelo ícone da Tela de Início (iOS 16.4 ou mais novo).
let pushOn = false;
const isIOS = () => /iphone|ipad|ipod/i.test(navigator.userAgent) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
const isStandalone = () => matchMedia("(display-mode: standalone)").matches || navigator.standalone === true;
const pushSupported = () => "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;
function b64uToBytes(s) {
  const b = atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4));
  return Uint8Array.from(b, c => c.charCodeAt(0));
}
function pushView(state, extra = "") {
  const box = $("push-box");
  box.hidden = false;
  box.classList.toggle("on", state === "on");
  $("push-on").hidden = state !== "off";
  $("push-off").hidden = state !== "on";
  $("push-msg").innerHTML = {
    on: "🔔 <b>Avisos no celular ligados</b> neste aparelho. Os horários novos chegam mesmo com o painel fechado.",
    off: "🔔 Receba os <b>horários novos no celular</b>, mesmo com o painel fechado ou a tela desligada.",
    ios: "🔔 Para receber os horários novos no iPhone: toque em <b>Compartilhar</b> (o quadrado com a seta) → <b>Adicionar à Tela de Início</b>. Depois abra o painel pelo ícone <b>Magrão Painel</b> e toque em <b>Receber avisos no celular</b>.",
    old: "🔔 Este navegador não recebe notificações. No iPhone, atualize para o iOS 16.4 ou mais novo.",
    denied: isIOS()
      ? "🔕 As notificações estão <b>bloqueadas</b> neste iPhone. Vá em <b>Ajustes → Notificações → Magrão Painel</b> e ligue <b>Permitir Notificações</b>. Se o Magrão Painel não aparecer lá: apague o ícone <b>Magrão Painel</b> da Tela de Início, adicione de novo pelo Safari (Compartilhar → Adicionar à Tela de Início), abra pelo ícone e toque em <b>Receber avisos no celular</b>."
      : "🔕 As notificações estão <b>bloqueadas</b> para este site. Libere nas configurações do navegador (Notificações) e recarregue o painel.",
  }[state] + extra;
}
async function pushSave(sub) {
  const j = sub.toJSON();
  await rpc("push_subscribe", { p_endpoint: j.endpoint, p_p256dh: j.keys.p256dh, p_auth: j.keys.auth, p_device: navigator.userAgent });
}
async function setupPush() {
  if (!pushSupported()) {
    if (isIOS() && !isStandalone()) pushView("ios");
    else if (isIOS()) pushView("old");
    return;
  }
  try {
    const reg = await navigator.serviceWorker.register("/sw.js");
    const sub = await reg.pushManager.getSubscription();
    if (sub && Notification.permission === "granted") {
      pushOn = true; pushView("on");
      await pushSave(sub);  // mantém a inscrição ligada a quem está logado neste aparelho
    } else if (Notification.permission === "denied") pushView("denied");
    else pushView("off");
  } catch { /* sem service worker (ex.: navegação privada) */ }
}
$("push-on").onclick = async () => {
  const btn = $("push-on"); btn.disabled = true;
  try {
    if (await Notification.requestPermission() !== "granted") return pushView("denied");
    const reg = await navigator.serviceWorker.ready;
    const key = await rpc("push_public_key");
    const sub = await reg.pushManager.getSubscription()
      || await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: b64uToBytes(key) });
    await pushSave(sub);
    pushOn = true; pushView("on");
    toast("Pronto! Os horários novos vão chegar neste celular.");
  } catch (e) {
    toast(e.message || "Não foi possível ligar os avisos neste aparelho.");
  } finally { btn.disabled = false; }
};
$("push-off").onclick = async () => {
  try {
    const sub = await (await navigator.serviceWorker.ready).pushManager.getSubscription();
    if (sub) { await rpc("push_unsubscribe", { p_endpoint: sub.endpoint }).catch(() => {}); await sub.unsubscribe(); }
    pushOn = false; pushView("off");
  } catch (e) { toast(e.message); }
};

// ---------------------------------------------------------------- aviso de horário novo
// Quando um cliente marca pelo site, o painel aberto mostra o aviso no canto superior direito, toca um
// som curto de três notas (no estilo do aviso do iPhone, feito aqui mesmo, sem arquivo) e "vibra".
// Barbeiro vê só os horários dele; o administrador vê de todos.
const ALERT_EVERY_MS = 15000, CHIME_TIMES = 5;
let alertLast = null, alertTimer = null, audioCtx = null;
function unlockAudio() {
  try {
    audioCtx ||= new (window.AudioContext || window.webkitAudioContext)();
    if (audioCtx.state === "suspended") audioCtx.resume();
  } catch { /* sem som neste navegador */ }
  // a permissão de notificação só é pedida pelo botão "Receber avisos no celular": no iPhone, pedir num
  // toque qualquer da tela faz o iOS bloquear sozinho, sem nem mostrar a pergunta
}
["pointerdown", "keydown"].forEach(ev => document.addEventListener(ev, unlockAudio, { once: true }));
function playChime() {
  if (!audioCtx || audioCtx.state !== "running") return;
  const t0 = audioCtx.currentTime + 0.02;
  const note = (freq, at) => {
    for (const [mult, vol, type] of [[1, 0.28, "sine"], [2, 0.06, "sine"], [1, 0.05, "triangle"]]) {
      const o = audioCtx.createOscillator(), g = audioCtx.createGain();
      o.type = type; o.frequency.value = freq * mult;
      g.gain.setValueAtTime(0, at);
      g.gain.linearRampToValueAtTime(vol, at + 0.01);
      g.gain.exponentialRampToValueAtTime(0.0001, at + 0.55);
      o.connect(g).connect(audioCtx.destination);
      o.start(at); o.stop(at + 0.6);
    }
  };
  // mi, dó, sol (agudo), tocado 5 vezes seguidas
  for (let k = 0; k < CHIME_TIMES; k++) [1318.5, 1046.5, 1568.0].forEach((f, i) => note(f, t0 + k * 0.9 + i * 0.13));
}
function showAlert(a) {
  let box = $("alerts");
  if (!box) { box = document.createElement("div"); box.id = "alerts"; box.className = "alerts"; box.setAttribute("aria-live", "assertive"); document.body.appendChild(box); }
  const el = document.createElement("div");
  el.className = "alert"; el.setAttribute("role", "alert");
  el.innerHTML = `<div class="alert-top"><b>📅 Novo horário marcado</b><small>agora</small>
      <button class="alert-x" aria-label="Fechar aviso">×</button></div>
    <p><span>Cliente:</span> <b>${esc(a.client_name)}</b></p>
    <p><span>Com:</span> ${esc(a.barber_name)} · <span>Quando:</span> <b>${esc(a.quando)}</b></p>
    <p><span>Serviço:</span> ${esc(a.service)}</p>`;
  el.querySelector(".alert-x").onclick = e => { e.stopPropagation(); el.remove(); };
  el.onclick = () => {
    el.remove();
    $("date").value = a.date;
    if (isAdmin()) $("barber-filter").value = a.barber_id;
    showTab("agenda");
  };
  box.prepend(el);
  while (box.children.length > 4) box.lastElementChild.remove();
}
function notifyAll(list) {
  list.forEach(showAlert);
  playChime();
  try { navigator.vibrate?.([250, 120, 250, 120, 400]); } catch { /* celular sem vibração */ }
  // com os avisos no celular ligados, a notificação já vem pelo push (não duplica)
  if (!pushOn && document.hidden && "Notification" in window && Notification.permission === "granted") {
    const a = list[list.length - 1];
    try { new Notification("Novo horário marcado", { body: `${a.client_name} com ${a.barber_name} · ${a.quando}`, icon: "img/icone-96.png", tag: `bk${a.id}` }); }
    catch { /* alguns celulares só mostram notificação pelo app */ }
  }
  // a agenda aberta já mostra o horário novo
  if (!document.querySelector('[data-tab="agenda"]').hidden) loadAgenda().catch(() => {});
}
async function pollAlerts() {
  try {
    const r = await rpc("staff_alerts", { p_after: alertLast });
    if (alertLast !== null && r.alerts.length) notifyAll(r.alerts);
    alertLast = r.last;
  } catch { /* sem internet: tenta de novo no próximo ciclo */ }
}
function startAlerts() {
  clearInterval(alertTimer);
  pollAlerts();
  alertTimer = setInterval(pollAlerts, ALERT_EVERY_MS);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) pollAlerts(); });
}

// ---------------------------------------------------------------- WhatsApp deste celular
// Os links do painel são wa.me. Com o WhatsApp Business (ou os dois apps no celular), o wa.me às vezes não abre nada.
// Cada barbeiro escolhe no próprio celular qual app abrir; a escolha fica salva só nesse aparelho.
const WA_KEY = "wa_app";
const waApp = () => { try { return localStorage.getItem(WA_KEY) || "auto"; } catch { return "auto"; } };
function waAppUrl(phone, text, web) {
  const q = [phone && `phone=${phone}`, text && `text=${encodeURIComponent(text)}`].filter(Boolean).join("&");
  if (/Android/i.test(navigator.userAgent)) {
    const pkg = waApp() === "business" ? "com.whatsapp.w4b" : "com.whatsapp";
    return `intent://send/?${q}#Intent;scheme=whatsapp;package=${pkg};S.browser_fallback_url=${encodeURIComponent(web)};end`;
  }
  return `whatsapp://send?${q}`;  // iPhone: abre o app direto, sem passar pelo navegador
}
document.addEventListener("click", e => {
  const a = e.target.closest?.('a[href^="https://wa.me/"]');
  if (!a || waApp() === "auto") return;
  e.preventDefault();  // o onclick do próprio link (ex.: marcar como enviada) continua rodando
  const u = new URL(a.href);
  location.href = waAppUrl(u.pathname.slice(1), u.searchParams.get("text") || "", a.href);
}, true);
document.querySelectorAll("[data-wa-app]").forEach(sel => {
  sel.value = waApp();
  sel.onchange = () => {
    try { localStorage.setItem(WA_KEY, sel.value); } catch { /* sem armazenamento: fica no automático */ }
    document.querySelectorAll("[data-wa-app]").forEach(o => o.value = sel.value);
    toast("Escolha salva neste celular");
  };
});

// ---------------------------------------------------------------- saída automática
// Depois de 60 minutos sem mexer no painel, sai da conta (ex.: painel esquecido aberto no celular de outra pessoa).
// Usa a hora do relógio, então funciona também com o celular bloqueado (quando o timer do navegador para).
const IDLE_MIN = 60;
let idleLast = Date.now(), idleTimer;
try {  // aviso na tela de login depois da saída automática
  if (sessionStorage.getItem("saiu_inativo")) { sessionStorage.removeItem("saiu_inativo"); toast(`Você saiu do painel por ficar ${IDLE_MIN} minutos sem usar. Entre de novo.`); }
} catch { /* sem sessionStorage: segue */ }
function startIdleLogout() {
  const mexeu = () => { idleLast = Date.now(); };
  ["pointerdown", "keydown", "scroll", "touchstart"].forEach(ev => addEventListener(ev, mexeu, { passive: true }));
  const check = async () => {
    if (Date.now() - idleLast < IDLE_MIN * 60 * 1000) return;
    clearInterval(idleTimer);
    try { clearTimeout(notesTimer); await saveNotes(); } catch { /* segue */ }
    try { sessionStorage.setItem("saiu_inativo", "1"); } catch { /* segue */ }
    await auth.signOut();
    location.reload();
  };
  idleTimer = setInterval(check, 60 * 1000);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) check(); });
}

// ---------------------------------------------------------------- notas (flutuante, canto inferior esquerdo)
let notesTimer, notesLoaded = false;
async function loadNotes() {
  try {
    const n = await rpc("my_note");
    $("notes-text").value = n.body || "";
    notesLoaded = true;
    $("notes-status").textContent = n.updated_at ? `Salvo em ${new Date(n.updated_at).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short" })}` : "";
  } catch { $("notes-status").textContent = "Não deu para abrir as notas."; }
}
async function saveNotes() {
  if (!notesLoaded) return;
  try { await rpc("save_my_note", { p_body: $("notes-text").value }); $("notes-status").textContent = `Salvo às ${new Date().toTimeString().slice(0, 5)}`; }
  catch (e) { $("notes-status").textContent = `Não salvou: ${e.message}`; }
}
$("notes-btn").onclick = () => { const open = $("notes-panel").hidden; $("notes-panel").hidden = !open; if (open) $("notes-text").focus(); };
$("notes-close").onclick = () => { clearTimeout(notesTimer); saveNotes(); $("notes-panel").hidden = true; };
$("notes-text").oninput = () => { $("notes-status").textContent = "Salvando…"; clearTimeout(notesTimer); notesTimer = setTimeout(saveNotes, 800); };
$("notes-text").onblur = () => { clearTimeout(notesTimer); saveNotes(); };
$("logout").onclick = async e => { e.preventDefault(); await auth.signOut(); location.reload(); };

function showTab(t) {
  if (t !== "comissoes") cmLock();
  document.querySelectorAll("#tabs button").forEach(b => b.setAttribute("aria-selected", b.dataset.t === t));
  document.querySelectorAll("[data-tab]").forEach(s => s.hidden = s.dataset.tab !== t);
  ({ agenda: loadAgenda, remanejar: loadRemanejar, comissoes: loadCommissions, equipe: loadEquipe, servicos: loadServices, barbeiros: loadBarbers,
     clientes: loadClients, mensagens: loadMsgs, config: loadConfig, pacotes: loadPacotes, caixa: loadCaixa })[t]().catch(e => toast(e.message));
}
document.querySelectorAll("#tabs button").forEach(b => b.onclick = () => showTab(b.dataset.t));

// ---------------------------------------------------------------- cartão de agendamento (agenda e remanejar)
function bookingCard(b) {
  const active = ["confirmado", "pendente"].includes(b.status);
  return `
    <div class="li${b.status === "cancelado" ? " is-faded" : ""}">
      <div class="hour">${b.start_at.slice(11, 16)}</div>
      <div class="grow">
        <div class="row u-gap-8"><h3>${esc(who(b))}</h3><span class="badge ${b.status}">${STATUS[b.status]}</span>
          ${b.moved_by_shop ? `<span class="badge">remanejado</span>` : ""}
          ${b.walk_in ? `<span class="badge confirmado">encaixe</span>` : b.created_by === "barbearia" ? `<span class="badge">pelo balcão</span>` : ""}
          ${b.pay_method === "pacote" && b.status !== "concluido" ? `<span class="badge confirmado">pacote</span>`
            : b.paid_online && b.status !== "concluido" ? `<span class="badge confirmado">pago online · ${PAY[b.pay_method] || ""}</span>` : ""}
          ${b.status === "cancelado" && b.paid_online ? `<span class="badge erro">pago online: devolver pelo app da InfinitePay</span>` : ""}
          ${b.status === "confirmado" && b.attendance_confirmed ? `<span class="badge confirmado">presença confirmada</span>` : ""}
          ${b.status === "confirmado" && !b.attendance_confirmed && b.confirm_asked ? `<span class="badge pendente">aguardando confirmação até ${esc(b.confirm_deadline)}</span>` : ""}
          ${b.pending_cents ? `<span class="badge erro">pendente ${brl(b.pending_cents)}</span>`
            : b.client_debt_cents && b.status !== "cancelado" ? `<span class="badge erro">cliente deve ${brl(b.client_debt_cents)}</span>` : ""}
          ${b.refund_status === "erro" ? `<span class="badge erro">erro no reembolso</span>` : b.refund_status === "reembolsado" ? `<span class="badge">sinal devolvido</span>` : b.refund_status === "pendente" ? `<span class="badge pendente">devolvendo sinal</span>` : ""}</div>
        <div class="muted small">${esc(b.service_name)} · ${esc(b.barber_name)} · até ${b.end_at.slice(11, 16)}${b.deposit_cents ? ` · sinal ${brl(b.deposit_cents)}` : ""} · ${b.pay_method === "pacote" ? `pelo pacote ${esc(b.package_name || "")} · vale ${brl(b.final_price_cents ?? 0)} na comissão` : b.final_price_cents != null ? `cobrado ${brl(b.final_price_cents)}` : `${b.pay_method === "pacote" || b.paid_online ? "já pago" : `cobrar ${b.price_from ? "a partir de " : ""}${brl(b.remaining_cents)}${b.client_pref_pay ? ` · costuma pagar no ${PAY[b.client_pref_pay]}` : ""}`}`}
          ${b.items?.length ? ` · consumo: ${b.items.map(i => `${i.qty}x ${esc(i.name)}`).join(", ")} (${brl(b.items_cents)})` : ""}
          ${b.moved_from ? ` · era ${esc(b.moved_from)}` : ""}${b.cancelled_by ? ` · ${b.cancelled_by === "sistema" ? "liberado: sem confirmação" : `cancelado por ${esc(b.cancelled_by)}${b.cancel_reason ? ` (${esc(b.cancel_reason)})` : ""}`}` : ""}</div>
      </div>
      <div class="row">
        <a class="btn btn-ghost btn-sm" target="_blank" rel="noopener noreferrer" href="https://wa.me/${esc(b.client_phone)}">WhatsApp</a>
        ${active ? `<button class="btn btn-ghost btn-sm" data-move="${b.id}">Mover</button>` : ""}
        ${b.status === "confirmado" ? `
          ${!b.attendance_confirmed ? `<button class="btn btn-ghost btn-sm" data-presence="${b.id}">Confirmar presença</button>` : ""}
          <button class="btn btn-main btn-sm" data-act="concluido" data-id="${b.id}">Confirmar pagamento</button>
          <button class="btn btn-ghost btn-sm" data-act="faltou" data-id="${b.id}">Faltou</button>` : ""}
        ${payChip(b)}
        ${b.pending_cents ? `<button class="btn btn-main btn-sm" data-settle="${b.id}">Receber ${brl(b.pending_cents)}</button>` : ""}
        ${b.status === "concluido" && !b.paid_online && b.pay_method !== "pacote" ? `<button class="btn btn-ghost btn-sm" data-fixpay="${b.id}">Corrigir pagamento</button>` : ""}
        ${active ? `<button class="btn btn-bad btn-sm" data-remove="${b.id}">Desmarcar com o cliente</button>`
          : ["concluido", "faltou"].includes(b.status) ? `<button class="btn btn-bad btn-sm" data-remove="${b.id}">Remover da agenda</button>` : ""}
        ${b.refund_status === "erro" && isAdmin() ? `<button class="btn btn-ghost btn-sm" data-refund="${b.id}">Tentar reembolso de novo</button>` : ""}
      </div>
    </div>`;
}

// Situação do pagamento de um atendimento concluído:
//   pagou na hora → verde "✓ Pagou Pix" · pendente → botão Receber · pendente já recebido → cinza
function payChip(b) {
  if (b.status !== "concluido" || b.pending_cents) return "";
  const total = (b.final_price_cents ?? b.price_cents) + (b.items_cents || 0);
  if (b.settled_at) return `<span class="pay-chip late" title="Recebido em ${new Date(b.settled_at).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short" })}">Pendente ${brl(total)} · recebido no ${PAY[b.pay_method] || ""}</span>`;
  if (b.pay_method === "pacote") return `<span class="pay-chip ok">✓ Pago com pacote</span>`;
  if (b.paid_online) return `<span class="pay-chip ok">✓ Pago online · ${PAY[b.pay_method] || ""}</span>`;
  if (b.pay_method) return `<span class="pay-chip ok">✓ Pagou ${PAY[b.pay_method]}</span>`;
  return "";
}

function bindBookingActions(root, list, reload) {
  root.querySelectorAll("[data-act]").forEach(btn => btn.onclick = async () => {
    const act = btn.dataset.act;
    let refund = true, finalCents = null;
    const bk = list.find(b => b.id === +btn.dataset.id);
    let payMethod = null, items = null;
    if (act === "concluido") {
      const prepaid = !!bk?.pay_method || !!bk?.paid_online;
      if (!prepaid || PRODUCTS.some(p => p.active)) {
        const r = await askPay(`${who(bk)} · ${bk.service_name}${prepaid || bk.price_from ? "" : ` · ${brl(bk.remaining_cents)}`}`, prepaid ? null : bk.client_pref_pay,
          { base: bk.remaining_cents, items: true, prepaid, pending: !prepaid, priceFrom: !prepaid && bk.price_from ? bk.price_cents : null });
        if (!r) return;
        payMethod = r.method; items = r.items; finalCents = r.price ?? null;
      }
    }
    try {
      await rpc("admin_set_status", { p_id: +btn.dataset.id, p_status: act, p_refund: refund, p_final_cents: finalCents, p_pay_method: payMethod, p_items: items });
      toast(act === "concluido" ? (payMethod === "pendente" ? "Ficou pendente na conta do cliente" : "Pagamento confirmado: já está no Caixa e em Comissões")
        : "Atualizado");
      reload();
    } catch (e) { toast(e.message); }
  });
  root.querySelectorAll("[data-remove]").forEach(btn => btn.onclick = async () => {
    const bk = list.find(b => b.id === +btn.dataset.remove);
    const r = await askRemove(bk);
    if (!r) return;
    try {
      const res = await rpc("staff_remove", { p_id: bk.id, p_reason: r.reason, p_notify: r.notify, p_refund: r.refund });
      reload();
      if (res.removed === "lancamento") return toast(`${who(bk)} saiu da agenda, do Caixa e das Comissões`);
      if (r.notify && res.text) return showWaNotice(res, `${who(bk)} foi desmarcado e saiu da agenda. A lista de espera do dia é avisada.`);
      toast(`${who(bk)} foi desmarcado e saiu da agenda`);
    } catch (e) { toast(e.message); }
  });
  root.querySelectorAll("[data-fixpay]").forEach(btn => btn.onclick = () => {
    const bk = list.find(b => b.id === +btn.dataset.fixpay);
    fixPay(bk.id, `${who(bk)} · ${bk.service_name} · ${brl(bk.final_price_cents ?? bk.price_cents)}`, bk.pay_method, reload);
  });
  root.querySelectorAll("[data-settle]").forEach(btn => btn.onclick = () => {
    const bk = list.find(b => b.id === +btn.dataset.settle);
    settle(bk.id, `${who(bk)} · ${bk.service_name}`, bk.pending_cents, reload);
  });
  root.querySelectorAll("[data-presence]").forEach(btn => btn.onclick = async () => {
    try { await rpc("admin_confirm_attendance", { p_id: +btn.dataset.presence }); toast("Presença confirmada"); reload(); }
    catch (e) { toast(e.message); }
  });
  root.querySelectorAll("[data-refund]").forEach(btn => btn.onclick = async () => {
    await rpc("admin_retry_refund", { p_id: +btn.dataset.refund });
    toast("Reembolso colocado na fila de novo"); reload();
  });
  root.querySelectorAll("[data-move]").forEach(btn => btn.onclick = () =>
    openMove(list.find(b => b.id === +btn.dataset.move), reload));
}

// Pergunta sim/não dentro da página. Devolve true/false
function ask(text, okLabel = "Confirmar", bad = false) {
  return new Promise(resolve => {
    $("ask-text").textContent = text;
    $("ask-ok").textContent = okLabel;
    $("ask-ok").className = `btn ${bad ? "btn-bad" : "btn-main"}`;
    const dlg = $("askdlg");
    dlg.returnValue = "";
    dlg.onclose = () => resolve(dlg.returnValue === "ok");
    dlg.showModal();
  });
}

// Janela "Desmarcar com o cliente" / "Remover da agenda". Devolve { reason, notify, refund } ou null
function askRemove(bk) {
  return new Promise(resolve => {
    const marcado = ["confirmado", "pendente"].includes(bk.status);
    $("rm-title").textContent = marcado ? "Desmarcar com o cliente" : "Remover da agenda";
    $("rm-info").textContent = `${who(bk)} · ${bk.service_name} · ${bk.start_at.slice(8, 10)}/${bk.start_at.slice(5, 7)} às ${bk.start_at.slice(11, 16)}`;
    $("rm-help").textContent = marcado
      ? "O horário é liberado e some da agenda. A lista de espera do dia é avisada."
      : "Use se foi lançado por engano: sai da agenda, do Caixa e das Comissões (com o consumo e o pendente).";
    $("rm-reason").value = marcado ? "imprevisto na barbearia" : "lançado por engano";
    $("rm-reason-label").firstChild.textContent = marcado ? "Motivo (vai na mensagem para o cliente)" : "Motivo (fica no registro)";
    $("rm-notify-wrap").hidden = !marcado; $("rm-notify").checked = true;
    $("rm-refund-wrap").hidden = !(marcado && bk.paid); $("rm-refund").checked = true;
    $("rm-online").hidden = !bk.paid_online;
    $("rm-go").textContent = marcado ? "Desmarcar" : "Remover";
    const dlg = $("rmdlg");
    dlg.returnValue = "";
    dlg.onclose = () => resolve(dlg.returnValue === "ok"
      ? { reason: $("rm-reason").value.trim(), notify: marcado && $("rm-notify").checked, refund: $("rm-refund").checked } : null);
    dlg.showModal();
  });
}

// Depois de desmarcar: aviso pronto para mandar no WhatsApp do cliente
function showWaNotice(r, title) {
  $("wa-title").textContent = title;
  $("wa-text").textContent = r.text;
  const a = $("wa-send");
  a.href = `https://wa.me/${r.phone}?text=${encodeURIComponent(r.text)}`;
  a.onclick = () => { rpc("admin_message_sent", { p_id: r.message_id }).catch(() => {}); setTimeout(() => $("wadlg").close(), 300); };
  $("wadlg").showModal();
}

// Corrige a forma de pagamento de um atendimento já concluído
async function fixPay(id, info, current, reload) {
  const r = await askPay(`Corrigir: ${info}${current ? ` · marcado como ${PAY[current]}` : ""}`, null, { pending: true });
  if (!r || r.method === current) return;
  try { await rpc("staff_fix_pay_method", { p_id: id, p_method: r.method }); toast(`Pagamento corrigido para ${PAY[r.method]}`); reload(); }
  catch (e) { toast(e.message); }
}

// Recebe um pendente (ex.: o pai pagando o corte que o filho fez)
async function settle(id, info, cents, reload) {
  const r = await askPay(`Receber: ${info} · ${brl(cents)}`, null);
  if (!r) return;
  try { await rpc("staff_settle", { p_id: id, p_method: r.method }); toast(`Recebido no ${PAY[r.method]}`); reload(); }
  catch (e) { toast(e.message); }
}

// Janela "Como o cliente pagou?"
//   opts.base    valor do serviço a cobrar (mostra o total com o consumo)
//   opts.items   mostra os consumíveis para lançar junto
//   opts.prepaid serviço já pago (pacote/site): a forma vale só para o consumo
//   opts.pending mostra "Pendente · paga depois"
// Devolve { method, items } ou null se fechar
function askPay(info, pref, opts = {}) {
  return new Promise(resolve => {
    const dlg = $("paydlg"), qty = {};
    const prods = opts.items ? PRODUCTS.filter(p => p.active) : [];
    $("pay-info").textContent = info + (pref ? ` · costuma pagar no ${PAY[pref]}` : "");
    $("pay-items").hidden = !prods.length;
    const svc = () => { const v = Math.round(parseFloat(String($("pay-price").value).replace(",", ".")) * 100); return opts.priceFrom && Number.isFinite(v) ? v : opts.base || 0; };
    const total = () => (opts.prepaid ? 0 : svc()) + prods.reduce((s, p) => s + (qty[p.id] || 0) * p.price_cents, 0);
    const paint = () => {
      $("pay-items").innerHTML = `<div class="eyebrow">Consumo</div>` + prods.map(p => `<div class="spread u-gap-8">
        <span>${esc(p.name)} <span class="muted small">${brl(p.price_cents)}</span></span>
        <span class="row u-gap-6 u-fwrap-nowrap"><button type="button" class="btn btn-ghost btn-sm" data-q="${p.id}" data-d="-1" aria-label="Menos">−</button>
          <b class="u-minw-20 u-ta-center">${qty[p.id] || 0}</b>
          <button type="button" class="btn btn-ghost btn-sm" data-q="${p.id}" data-d="1" aria-label="Mais">+</button></span></div>`).join("");
      $("pay-items").querySelectorAll("[data-q]").forEach(b => b.onclick = () => {
        qty[b.dataset.q] = Math.max(0, Math.min(50, (qty[b.dataset.q] || 0) + +b.dataset.d)); paint();
      });
      const hasItems = Object.values(qty).some(Boolean);
      $("pay-total").hidden = !opts.base && !hasItems;
      $("pay-total").innerHTML = opts.prepaid ? `Consumo: <b>${brl(total())}</b> <span class="muted small">(serviço já pago)</span>` : `Total: <b>${brl(total())}</b>`;
      $("pay-none").hidden = !opts.prepaid || hasItems;
    };
    $("pay-price").oninput = () => paint();
    paint();
    $("pay-pend").hidden = !opts.pending;
    $("pay-price-wrap").hidden = !opts.priceFrom;
    if (opts.priceFrom) $("pay-price").value = (opts.priceFrom / 100).toFixed(2);
    dlg.querySelectorAll(".grid2 button[value]").forEach(b => {
      b.classList.toggle("btn-main", !pref || b.value === pref);
      b.classList.toggle("btn-ghost", !!pref && b.value !== pref);
    });
    dlg.returnValue = "";
    dlg.onclose = () => {
      const m = dlg.returnValue;
      if (!m) return resolve(null);
      const items = Object.entries(qty).filter(([, q]) => q > 0).map(([id, q]) => ({ product_id: +id, qty: q }));
      const v = Math.round(parseFloat(String($("pay-price").value).replace(",", ".")) * 100);
      resolve({ method: m === "nada" ? null : m, items, price: opts.priceFrom && Number.isFinite(v) && v >= 0 ? v : null });
    };
    dlg.showModal();
  });
}

// ---------------------------------------------------------------- agenda
$("prev").onclick = () => { $("date").value = addDays($("date").value, -1); loadAgenda(); };
$("next").onclick = () => { $("date").value = addDays($("date").value, 1); loadAgenda(); };
$("today").onclick = () => { $("date").value = todayStr(); loadAgenda(); };
$("date").onchange = $("barber-filter").onchange = () => loadAgenda();

let SHOW_CANCELLED = false;
// Números do topo da agenda: cadastros no site e clientes marcados (hoje e próximos dias).
// Atualiza a cada minuto e depois de qualquer ação na agenda (desmarcar já diminui).
async function loadCounts() {
  const c = await rpc("staff_client_counts");
  const tile = (label, value, sub = "") => `<div class="stat"><span class="eyebrow u-m-0">${label}</span><b>${value}</b>${sub ? `<small>${sub}</small>` : ""}</div>`;
  $("ag-counts").innerHTML = (c.cadastrados != null ? tile("Clientes com cadastro no site", c.cadastrados, `+ ${c.balcao} cadastrados no balcão`) : "")
    + tile("Marcados hoje", c.hoje_total, c.hoje_falta ? `${c.hoje_falta} ainda para atender` : "todos atendidos")
    + tile("Marcados nos próximos dias", c.futuros, c.futuros ? `em ${c.futuros_dias} dia(s)` : "nenhum ainda")
    + `<p class="muted small u-full u-m-0">Atualizado às ${esc(c.agora)}</p>`;
}
setInterval(() => { if (ME && !$("app").hidden && !document.hidden) loadCounts().catch(() => {}); }, 60 * 1000);
document.addEventListener("visibilitychange", () => { if (ME && !$("app").hidden && !document.hidden) loadCounts().catch(() => {}); });

async function loadAgenda() {
  loadCounts().catch(e => toast(e.message));
  const { bookings, blocks, waitlist } = await rpc("admin_agenda", { p_date: $("date").value, p_barber: +$("barber-filter").value || null });
  // Resumo do dia: o que já foi feito (horários marcados + encaixes) e o que ainda falta atender
  const val = b => (b.final_price_cents ?? b.price_cents) + (b.items_cents || 0);
  const done = bookings.filter(b => b.status === "concluido"), todo = bookings.filter(b => b.status === "confirmado");
  const sum = list => brl(list.reduce((s, b) => s + val(b), 0));
  const enc = done.filter(b => b.walk_in).length;
  const feitoPor = [...new Set(done.map(b => b.barber_name))].map(n => `${esc(n)} ${sum(done.filter(b => b.barber_name === n))}`);
  $("day-stats").innerHTML = `<b>Feito: ${sum(done)}</b> em ${done.length} atendimento(s)${enc ? ` (${enc} encaixe${enc > 1 ? "s" : ""})` : ""}`
    + (todo.length ? ` · falta atender ${todo.length} (${sum(todo)})` : "")
    + (feitoPor.length > 1 ? `<br>${feitoPor.join(" · ")}` : "");
  const shown = SHOW_CANCELLED ? bookings : bookings.filter(b => b.status !== "cancelado");
  const nCanc = bookings.length - bookings.filter(b => b.status !== "cancelado").length;
  $("agenda").innerHTML = (shown.length ? shown.map(bookingCard).join("") : `<p class="empty">Nenhum agendamento nesse dia.</p>`)
    + (nCanc ? `<p class="small muted u-ta-center"><a href="#" id="toggle-canc">${SHOW_CANCELLED ? "Esconder" : "Mostrar"} desmarcados (${nCanc})</a></p>` : "");
  if (nCanc) $("toggle-canc").onclick = e => { e.preventDefault(); SHOW_CANCELLED = !SHOW_CANCELLED; loadAgenda(); };
  bindBookingActions($("agenda"), shown, loadAgenda);

  // resumo do dia por barbeiro, para mandar no WhatsApp (escolhe o contato ou grupo no app)
  const d = $("date").value, porBarbeiro = {};
  bookings.filter(b => b.status === "confirmado").forEach(b => (porBarbeiro[b.barber_name] ??= []).push(`${b.start_at.slice(11, 16)} ${who(b)} · ${b.service_name}`));
  const resumo = `Agenda ${d.slice(8, 10)}/${d.slice(5, 7)} · Magrão Barber Shop\n` + (Object.keys(porBarbeiro).length
    ? Object.entries(porBarbeiro).map(([n, l]) => `\n*${n}*\n${l.join("\n")}`).join("\n")
    : "\nNenhum horário marcado.");
  $("wa-agenda").href = `https://wa.me/?text=${encodeURIComponent(resumo)}`;

  const hm = t => `${t.slice(8, 10)}/${t.slice(5, 7)} ${t.slice(11, 16)}`;
  $("blocks").innerHTML = blocks.map(b => `<div class="spread small"><span>${esc(b.barber_name)}: ${hm(b.start_at)} – ${hm(b.end_at)} ${b.reason ? "· " + esc(b.reason) : ""}</span>
    <button class="btn btn-ghost btn-sm" data-unblock="${b.id}">Remover</button></div>`).join("");
  $("blocks").querySelectorAll("[data-unblock]").forEach(btn => btn.onclick = async () => {
    await rpc("admin_delete_block", { p_id: +btn.dataset.unblock }); loadAgenda();
  });
  $("waitlist").innerHTML = waitlist.length ? waitlist.map((w, i) => `<div class="spread small">
    <span>${i + 1}. ${esc(w.name)} · ${esc(w.service_name)}${w.barber_name ? " · " + esc(w.barber_name) : ""} ${w.status === "avisado" ? `<span class="badge">avisado</span>` : ""}</span>
    <a class="btn btn-ghost btn-sm" target="_blank" rel="noopener noreferrer" href="https://wa.me/${esc(w.phone)}">WhatsApp</a></div>`).join("")
    : `<p class="muted small">Ninguém esperando.</p>`;
}

$("bl-allday").onchange = e => { $("bl-start").disabled = $("bl-end").disabled = e.target.checked; };
$("bl-add").onclick = async () => {
  const d = $("date").value, all = $("bl-allday").checked;
  try {
    await rpc("admin_add_block", { p_barber: +$("bl-barber").value, p_reason: $("bl-reason").value,
      p_start: `${d}T${all ? "00:00" : $("bl-start").value}`, p_end: `${d}T${all ? "23:59" : $("bl-end").value}` });
    toast("Horário bloqueado"); $("bl-reason").value = ""; loadAgenda();
  } catch (e) { toast(e.message); }
};

// ---------------------------------------------------------------- remanejar
let rmDay = null;
$("rm-barber").onchange = () => loadRemanejar();

function loadBar(d) {
  const pct = d.percent;
  const level = pct == null ? "off" : pct >= 75 ? "high" : pct >= 40 ? "mid" : "low";
  return { pct, level, label: pct == null ? "fechado" : `${pct}%` };
}

async function loadRemanejar() {
  const barber = +$("rm-barber").value || null;
  const days = await rpc("admin_day_load", { p_from: todayStr(), p_days: 14, p_barber: barber });
  if (!rmDay || !days.some(d => d.date === rmDay)) {
    rmDay = (days.filter(d => d.percent != null).sort((a, b) => b.percent - a.percent)[0] || days[0]).date;
  }
  $("rm-load").innerHTML = days.map(d => {
    const l = loadBar(d);
    return `<button class="load-day ${l.level}" data-d="${d.date}" aria-pressed="${d.date === rmDay}" ${l.pct == null ? "disabled" : ""}>
      <small>${dateLabel(d.date)}</small>
      <span class="bar"><span data-pct="${Math.min(100, l.pct ?? 0)}"></span></span>
      <b>${l.label}</b><i>${d.bookings} cliente(s)</i></button>`;
  }).join("");
  // altura pelo CSSOM (a CSP não deixa style="" no HTML)
  $("rm-load").querySelectorAll("[data-pct]").forEach(s => { s.style.height = s.dataset.pct + "%"; });
  $("rm-load").querySelectorAll(".load-day").forEach(b => b.onclick = () => { rmDay = b.dataset.d; loadRemanejar(); });

  const { bookings } = await rpc("admin_agenda", { p_date: rmDay, p_barber: barber });
  const movable = bookings.filter(b => ["confirmado", "pendente"].includes(b.status));
  $("rm-title").textContent = `Clientes de ${dateLabel(rmDay)}`;
  $("rm-list").innerHTML = movable.length ? movable.map(bookingCard).join("") : `<p class="empty">Nenhum cliente para mover nesse dia.</p>`;
  bindBookingActions($("rm-list"), movable, loadRemanejar);
}

// ---------------------------------------------------------------- janela "mover"
const MV = { booking: null, date: null, time: null, done: null };

async function openMove(b, done) {
  Object.assign(MV, { booking: b, date: null, time: null, done });
  $("mv-info").textContent = `${who(b)} · ${b.service_name} · hoje marcado para ${b.quando} com ${b.barber_name}`;
  $("mv-barber").innerHTML = barberOptions(false);
  $("mv-barber").value = b.barber_id;
  $("mv-barber").disabled = !isAdmin();
  $("mv-force").checked = false; $("mv-free-wrap").hidden = true;
  $("mv-notify").checked = b.status === "confirmado";
  $("mv-err").textContent = "";
  $("move").showModal();
  await moveDays();
}

async function moveDays() {
  const days = await rpc("admin_day_load", { p_from: todayStr(), p_days: 21, p_barber: +$("mv-barber").value });
  const open = days.filter(d => d.percent != null);
  // Sugere o dia mais vazio
  MV.date ||= ([...open].sort((a, b) => a.percent - b.percent)[0] || days[0]).date;
  $("mv-days").innerHTML = days.map(d => {
    const l = loadBar(d), dt = new Date(d.date + "T12:00");
    return `<button type="button" class="day ${l.pct == null ? "closed" : ""}" data-d="${d.date}" aria-pressed="${d.date === MV.date}">
      <small>${DIAS[dt.getDay()]}</small><b>${dt.getDate()}</b><i class="lvl-${l.level}">${l.label}</i></button>`;
  }).join("");
  $("mv-days").querySelectorAll(".day").forEach(b => b.onclick = () => { MV.date = b.dataset.d; MV.time = null; moveDays(); });
  $("mv-days").querySelector("[aria-pressed=true]")?.scrollIntoView({ inline: "center", block: "nearest" });
  await moveTimes();
}

async function moveTimes() {
  MV.time = null; $("mv-save").disabled = true;
  if ($("mv-force").checked) { $("mv-times").innerHTML = ""; $("mv-save").disabled = !$("mv-free").value; return; }
  const times = await rpc("admin_move_slots", { p_id: MV.booking.id, p_date: MV.date, p_barber: +$("mv-barber").value });
  $("mv-times").innerHTML = times.length ? times.map(t => `<button type="button" class="time" data-t="${t}">${t}</button>`).join("")
    : `<p class="muted small u-full">Sem horário livre nesse dia. Use o encaixe se quiser.</p>`;
  $("mv-times").querySelectorAll(".time").forEach(b => b.onclick = () => {
    MV.time = b.dataset.t;
    $("mv-times").querySelectorAll(".time").forEach(x => x.setAttribute("aria-pressed", x === b));
    $("mv-save").disabled = false;
  });
}

$("mv-barber").onchange = () => { MV.time = null; moveDays(); };
$("mv-force").onchange = e => { $("mv-free-wrap").hidden = !e.target.checked; moveTimes(); };
$("mv-free").oninput = () => { $("mv-save").disabled = !$("mv-free").value; };
$("mv-save").onclick = async () => {
  const force = $("mv-force").checked;
  const time = force ? $("mv-free").value : MV.time;
  try {
    await rpc("admin_move_booking", { p_id: MV.booking.id, p_date: MV.date, p_time: time, p_barber: +$("mv-barber").value,
      p_force: force, p_notify: $("mv-notify").checked });
    $("move").close();
    toast($("mv-notify").checked ? "Horário movido. O cliente vai receber o aviso." : "Horário movido.");
    MV.done?.();
  } catch (e) { $("mv-err").textContent = e.message; }
};

// ---------------------------------------------------------------- equipe (admin: uma aba por barbeiro) / meu painel (barbeiro)
let eqBarber = null, eqTimer, eqDaysAhead = 30;
const fmtDate = iso => iso ? new Date(iso.slice(0, 10) + "T12:00").toLocaleDateString("pt-BR") : "—";
// Quando o cliente criou a conta no site (e se antes era do balcão/encaixe)
const contaInfo = c => !c.has_login ? "balcão (sem conta no site)"
  : c.balcao_desde ? `<b>criou conta no site em ${fmtDate(c.conta_em)}</b> · era do balcão desde ${fmtDate(c.balcao_desde)}`
  : c.conta_em ? `conta no site desde ${fmtDate(c.conta_em)}` : "";

// Cliente do balcão/encaixe sem conta: a equipe manda o link de cadastro no WhatsApp ou cria a conta por ele
const primeiroNome = c => c.name.split(" ")[0];
const linkCadastro = c => `${location.origin}/conta.html?cadastro=1&nome=${encodeURIComponent(c.name)}&tel=${c.phone.slice(2)}`;
const textoCadastro = c => `Olá, ${primeiroNome(c)}! Aqui é da Magrão Barber Shop 💈 Termine seu cadastro no nosso site para marcar seus horários e ver seu histórico e seus pacotes: ${linkCadastro(c)}\nUse este mesmo WhatsApp: tudo o que você já fez com a gente aparece na sua conta.`;
const semConta = c => !c.has_login && c.phone !== "5500000000000";
const contaBtns = c => semConta(c) ? `<div class="row u-gap-8 u-mt-4">
  <a class="btn btn-ghost btn-sm" target="_blank" rel="noopener noreferrer" href="https://wa.me/${esc(c.phone)}?text=${encodeURIComponent(textoCadastro(c))}">Mandar link de cadastro</a>
  <button class="btn btn-ghost btn-sm" data-criar="${esc(c.id)}">Criar conta</button></div>` : "";
function bindCriarConta(root, rows) {
  root.querySelectorAll("[data-criar]").forEach(btn => btn.onclick = async () => {
    const c = rows.find(r => r.id === btn.dataset.criar);
    const email = prompt(`E-mail de ${c.name} para entrar no site:`);
    if (!email?.trim()) return;
    btn.disabled = true;
    try {
      const r = await callFn("staff-criar-conta", { user_id: c.id, email: email.trim() });
      const msg = `Olá, ${primeiroNome(c)}! Criamos sua conta no site da Magrão Barber Shop 💈\nEntre em ${location.origin}/conta.html\nE-mail: ${r.email}\nSenha provisória: ${r.temp_password}\nDepois troque a senha em "Minha conta". Lá você marca seus horários e vê seu histórico e seus pacotes.`;
      btn.parentElement.innerHTML = `<a class="btn btn-main btn-sm" target="_blank" rel="noopener noreferrer" href="https://wa.me/${esc(c.phone)}?text=${encodeURIComponent(msg)}">Enviar acesso no WhatsApp</a>
        <span class="muted small">senha provisória: <b>${esc(r.temp_password)}</b></span>`;
      toast("Conta criada. Envie o acesso para o cliente.");
    } catch (e) { toast(e.message); btn.disabled = false; }
  });
}

function eqPeriod(kind) {
  const now = new Date(), iso = d => d.toLocaleDateString("sv-SE");
  if (kind === "month") { $("eq-from").value = iso(new Date(now.getFullYear(), now.getMonth(), 1)); $("eq-to").value = iso(now); }
  if (kind === "last") { $("eq-from").value = iso(new Date(now.getFullYear(), now.getMonth() - 1, 1)); $("eq-to").value = iso(new Date(now.getFullYear(), now.getMonth(), 0)); }
  if (kind === "week") { $("eq-from").value = addDays(iso(now), -6); $("eq-to").value = iso(now); }
}
document.querySelectorAll("[data-eqp]").forEach(b => b.onclick = () => { eqPeriod(b.dataset.eqp); loadEquipeStats(); });
$("eq-from").onchange = $("eq-to").onchange = () => loadEquipeStats();
$("eq-q").oninput = () => { clearTimeout(eqTimer); eqTimer = setTimeout(loadEquipeClients, 300); };

async function loadEquipe() {
  BARBERS = await rpc("admin_barbers");
  if (!$("eq-from").value) eqPeriod("month");
  if (!isAdmin()) eqBarber = ME.barber_id;
  if (!eqBarber || !BARBERS.some(b => b.id === eqBarber)) eqBarber = (BARBERS.find(b => b.active) || BARBERS[0])?.id;
  $("eq-barbers").hidden = !isAdmin();
  $("eq-barbers").innerHTML = BARBERS.map(b => `<button data-b="${b.id}" aria-selected="${b.id === eqBarber}">${esc(b.name)}${b.active ? "" : " (inativo)"}</button>`).join("");
  $("eq-barbers").querySelectorAll("[data-b]").forEach(btn => btn.onclick = () => { eqBarber = +btn.dataset.b; loadEquipe(); });
  if (!eqBarber) { $("eq-name").textContent = "Nenhum barbeiro cadastrado"; return; }

  const b = BARBERS.find(x => x.id === eqBarber);
  $("eq-name").textContent = b.name;
  $("eq-role").textContent = b.accounts.length ? `Acesso: ${b.accounts.join(", ")}` : (isAdmin() ? "Sem conta ligada · ligue em Clientes" : "Barbeiro");
  try { eqDaysAhead = (await rpc("public_info")).settings.days_ahead; } catch { /* mantém 30 */ }
  $("eq-days").textContent = eqDaysAhead;
  $("eq-rolling").checked = !b.open_until;
  $("eq-until").value = b.open_until || addDays(todayStr(), 7);
  $("eq-until-wrap").hidden = !b.open_until;
  const byDay = d => b.hours.filter(h => h.weekday === d).map(h => `${h.start}-${h.end}`).join(", ");
  $("eq-hours").innerHTML = [1, 2, 3, 4, 5, 6, 0].map(d =>
    `<label class="u-fd-row u-ai-center u-gap-10"><span class="u-w-70">${WEEK[d]}</span><input data-wd="${d}" value="${byDay(d)}" placeholder="folga"></label>`).join("");
  // Fechar / reabrir: "fechada" = aberta só até um dia que já passou
  const closed = !!b.open_until && b.open_until < todayStr();
  $("ag-status").innerHTML = closed ? `<span class="badge erro">Agenda FECHADA</span> <span class="muted small">não entra agendamento novo</span>`
    : `<span class="badge confirmado">Agenda ABERTA</span> <span class="muted small">${b.open_until ? `até ${fmtDate(b.open_until)}` : `sempre os próximos ${eqDaysAhead} dias`}</span>`;
  $("ag-toggle").textContent = closed ? "Reabrir agenda" : "Fechar agenda";
  $("ag-toggle").className = `btn btn-sm ${closed ? "btn-main" : "btn-bad"}`;
  $("ag-note").textContent = closed ? "Reabrir volta a aceitar agendamentos para os próximos dias." : "Fechar não desmarca ninguém: só para de aceitar agendamentos novos pelo site.";
  $("ag-toggle").onclick = async () => {
    if (!closed && !await ask(`Fechar a agenda de ${b.name}? Ninguém consegue marcar com ele pelo site até reabrir. Quem já está marcado continua.`, "Fechar agenda", true)) return;
    try {
      const r = await rpc("staff_set_agenda_open", { p_barber: eqBarber, p_open: closed });
      toast(closed ? "Agenda reaberta" : `Agenda fechada · ${r.futuros} cliente(s) já marcado(s) continuam`); loadEquipe();
    } catch (e) { toast(e.message); }
  };
  if (!$("dh-from").value) $("dh-from").value = todayStr();
  await Promise.all([loadEquipeStats(), loadEquipeClients(), loadDayHours(), loadEqSlots(), loadEqDays()]);
}

// Horário especial por dia/período
async function loadDayHours() {
  const rows = await rpc("staff_day_hours", { p_barber: eqBarber });
  $("dh-list").innerHTML = rows.length ? `<div class="eyebrow">Dias com horário especial</div>` + rows.map(r => `<div class="li"><div class="grow">
      <b>${dateLabel(r.day)}</b> <span class="muted small">${r.hours ? r.hours.map(h => `${h.start}-${h.end}`).join(", ") : "folga"}</span></div>
      <button class="btn btn-ghost btn-sm" data-dh-reset="${r.day}">Voltar ao normal</button></div>`).join("")
    : `<p class="muted small">Nenhum dia com horário especial.</p>`;
  $("dh-list").querySelectorAll("[data-dh-reset]").forEach(btn => btn.onclick = () => saveDayHours(btn.dataset.dhReset, btn.dataset.dhReset, null));
}
async function saveDayHours(from, to, hours) {
  try {
    const r = await rpc("staff_set_day_hours", { p_barber: eqBarber, p_from: from, p_to: to || from, p_hours: hours });
    toast(hours === null ? "Voltou ao expediente normal" : hours.length ? "Horário salvo" : "Folga salva");
    if (r.fora_do_horario) alert(`Atenção: ${r.fora_do_horario} cliente(s) já marcado(s) ficaram fora desse horário. Eles continuam marcados: remaneje ou avise pelo WhatsApp.`);
    loadDayHours();
  } catch (e) { toast(e.message); }
}
$("dh-off").onchange = e => { $("dh-hours").disabled = e.target.checked; };
$("dh-save").onclick = async () => {
  const from = $("dh-from").value, to = $("dh-to").value || from;
  if (!from) return toast("Escolha o dia.");
  if ($("dh-off").checked) {
    if (!await ask(`Marcar folga de ${fmtDate(from)}${to !== from ? ` até ${fmtDate(to)}` : ""}?`, "Marcar folga", true)) return;
    return saveDayHours(from, to, []);
  }
  const hours = [];
  for (const part of $("dh-hours").value.split(",").map(s => s.trim()).filter(Boolean)) {
    const m = part.match(/^(\d{1,2}):?(\d{2})?\s*-\s*(\d{1,2}):?(\d{2})?$/);
    if (!m) return toast(`Horário inválido: "${part}". Use 07:00-22:00`);
    const p = (h, mi) => `${h.padStart(2, "0")}:${mi || "00"}`;
    hours.push({ start: p(m[1], m[2]), end: p(m[3], m[4]) });
  }
  if (!hours.length) return toast("Digite o horário (ex.: 07:00-22:00) ou marque folga.");
  saveDayHours(from, to, hours);
};
$("dh-reset").onclick = () => {
  const from = $("dh-from").value, to = $("dh-to").value || from;
  if (!from) return toast("Escolha o dia.");
  saveDayHours(from, to, null);
};

$("eq-rolling").onchange = e => { $("eq-until-wrap").hidden = e.target.checked; };

async function loadEquipeStats() {
  if (!eqBarber) return;
  const s = await rpc("barber_stats", { p_barber: eqBarber, p_from: $("eq-from").value, p_to: $("eq-to").value });
  const tile = (label, value, sub = "") => `<div class="stat"><span class="eyebrow u-m-0">${label}</span><b>${value}</b>${sub ? `<small>${sub}</small>` : ""}</div>`;
  $("eq-stats").innerHTML = [
    tile("Cortes feitos", s.cortes, `${s.clientes} cliente(s)`),
    tile("Faturamento", brl(s.faturamento_cents)),
    ...(isAdmin() ? [] : [tile(`Comissão (${s.commission_percent}%)`, brl(s.comissao_cents), `casa ${brl(s.faturamento_cents - s.comissao_cents)}`)]),
    tile("Desmarques", s.desmarques_cliente + s.desmarques_barbearia, `${s.desmarques_cliente} cliente · ${s.desmarques_barbearia} barbearia`),
    tile("Faltas", s.faltas),
    tile("Liberados sem confirmação", s.sem_confirmacao),
    tile("Reagendamentos", s.reagendamentos),
    tile("Próximos horários", s.proximos, "confirmados"),
  ].join("");
}

async function loadEquipeClients() {
  if (!eqBarber) return;
  const rows = await rpc("barber_clients", { p_barber: eqBarber, p_q: $("eq-q").value.trim() });
  $("eq-clients").innerHTML = rows.map(c => `<tr>
    <td><b>${esc(c.name)}</b><div class="small"><a href="https://wa.me/${esc(c.phone)}" target="_blank" rel="noopener noreferrer">${fmtPhone(c.phone)}</a></div><div class="muted small">${contaInfo(c)}</div>${contaBtns(c)}</td>
    <td>${c.cortes}</td><td>${c.desmarques}</td><td>${c.faltas ? `<span class="badge faltou">${c.faltas}</span>` : 0}</td><td>${c.reagendamentos}</td>
    <td>${fmtDate(c.ultima_visita)}</td><td>${c.proximo ? `${fmtDate(c.proximo)} ${c.proximo.slice(11, 16)}` : "—"}</td></tr>`).join("")
    || `<tr><td colspan="7" class="muted">Nenhum cliente ainda.</td></tr>`;
  bindCriarConta($("eq-clients"), rows);
}

$("eq-save").onclick = async () => {
  const hours = [];
  try {
    for (const input of $("eq-hours").querySelectorAll("[data-wd]")) {
      const d = +input.dataset.wd;
      for (const part of input.value.split(",").map(s => s.trim()).filter(Boolean)) {
        const m = part.match(/^(\d{1,2}):?(\d{2})?\s*-\s*(\d{1,2}):?(\d{2})?$/);
        if (!m) throw new Error(`Horário inválido em ${WEEK[d]}: "${part}"`);
        const p = (h, mi) => `${h.padStart(2, "0")}:${mi || "00"}`;
        const start = p(m[1], m[2]), end = p(m[3], m[4]);
        if (end <= start) throw new Error(`Em ${WEEK[d]}, o fim precisa ser depois do início.`);
        hours.push({ weekday: d, start, end });
      }
    }
    const until = $("eq-rolling").checked ? null : $("eq-until").value || null;
    await rpc("staff_save_schedule", { p_barber: eqBarber, p_hours: hours, p_open_until: until });
    toast(until ? `Agenda aberta até ${fmtDate(until)}` : "Agenda salva");
    loadEquipe();
  } catch (e) { toast(e.message); }
};

// ---------------------------------------------------------------- comissões
function setPeriod(kind) {
  const now = new Date(), iso = d => d.toLocaleDateString("sv-SE");
  if (kind === "month") { $("cm-from").value = iso(new Date(now.getFullYear(), now.getMonth(), 1)); $("cm-to").value = iso(now); }
  if (kind === "last") { $("cm-from").value = iso(new Date(now.getFullYear(), now.getMonth() - 1, 1)); $("cm-to").value = iso(new Date(now.getFullYear(), now.getMonth(), 0)); }
  if (kind === "week") { $("cm-from").value = addDays(iso(now), -6); $("cm-to").value = iso(now); }
}
document.querySelectorAll("[data-period]").forEach(b => b.onclick = () => { setPeriod(b.dataset.period); loadCommissions(); });
$("cm-from").onchange = $("cm-to").onchange = () => loadCommissions();

// O admin digita a senha toda vez que entra na aba. Barbeiro vê só o dele, sem senha.
const CM_IDLE_MIN = 5;
let cmToken = null, cmRows = [], cmIdle;
function cmLock() {
  cmToken = null; cmRows = []; clearTimeout(cmIdle);
  $("cmdlg").close();
  ["cm-body", "cm-foot", "ps-body"].forEach(id => $(id).innerHTML = "");
  $("cm-content").hidden = true;
  $("cm-pass").value = $("cm-err").textContent = "";
  $("sc-body").innerHTML = ""; $("sc-content").hidden = true; $("sc-gate").hidden = false;
  $("sc-pass").value = $("sc-err").textContent = "";
}
function cmTouch() {
  if (!cmToken) return;
  clearTimeout(cmIdle);
  cmIdle = setTimeout(() => { cmLock(); if (!$("cm-content").closest("[data-tab]").hidden) $("cm-gate").hidden = false; }, CM_IDLE_MIN * 60000);
}
["pointerdown", "keydown"].forEach(ev => document.addEventListener(ev, cmTouch));
async function cmUnlock() {
  $("cm-open").disabled = true;
  try {
    const r = await rpc("admin_commission_unlock", { p_pass: $("cm-pass").value });
    if (!r.ok) { $("cm-err").textContent = r.error; $("cm-pass").value = ""; $("cm-pass").focus(); return; }
    cmToken = r.token; $("cm-pass").value = $("cm-err").textContent = "";
    await loadCommissions();
  } catch (e) { $("cm-err").textContent = e.message; }
  finally { $("cm-open").disabled = false; }
}
$("cm-open").onclick = cmUnlock;
$("cm-pass").onkeydown = e => { if (e.key === "Enter") cmUnlock(); };
$("cm-lock").onclick = () => { cmLock(); $("cm-gate").hidden = false; $("cm-pass").focus(); };

async function loadCommissions() {
  if (!$("cm-from").value) setPeriod("month");
  if (isAdmin() && !cmToken) { cmLock(); $("cm-gate").hidden = false; $("cm-pass").focus(); return; }
  let rows;
  try { rows = await rpc("admin_commissions", { p_from: $("cm-from").value, p_to: $("cm-to").value, p_token: cmToken }); }
  catch (e) {
    if (e.message.includes("senha das comissões")) { cmLock(); $("cm-gate").hidden = false; return; }
    throw e;
  }
  cmRows = rows; cmTouch();
  $("cm-gate").hidden = true; $("cm-content").hidden = false;
  $("cm-body").innerHTML = rows.map(r => `<tr>
    <td><b>${esc(r.barber_name)}</b><div class="muted small">${r.tem_combinado ? "valor combinado" : `${r.commission_percent}%${r.tem_pct_servico ? " (fora os serviços com % própria)" : ""}`}</div></td>
    <td>${r.atendimentos}${r.encaixes ? `<div class="muted small">${r.encaixes} encaixe(s)</div>` : ""}</td><td>${brl(r.total_cents)}</td><td><b>${brl(r.barbeiro_cents)}</b></td>
    ${isAdmin() ? `<td><button class="btn btn-ghost btn-sm" data-cm-edit="${r.barber_id}">Editar</button></td>` : ""}</tr>`).join("")
    || `<tr><td colspan="4" class="muted">Nenhum barbeiro.</td></tr>`;
  $("cm-body").querySelectorAll("[data-cm-edit]").forEach(b => b.onclick = () => openCmEdit(+b.dataset.cmEdit));
  const sum = k => rows.reduce((s, r) => s + r[k], 0);
  if (isAdmin()) loadPaySummary().catch(e => toast(e.message));
  $("cm-foot").innerHTML = rows.length > 1 ? `<tr><th>Total</th><th>${sum("atendimentos")}</th><th>${brl(sum("total_cents"))}</th>
    <th>${brl(sum("barbeiro_cents"))}</th>${isAdmin() ? "<th></th>" : ""}</tr>` : "";
}

let cmEdit = null;
const cmValCents = () => { const v = String($("cmd-val").value).trim(); return v === "" ? null : Math.round(parseFloat(v.replace(",", ".")) * 100); };
function cmHouse() { $("cmd-house").textContent = ""; }
function openCmEdit(id) {
  cmEdit = cmRows.find(r => r.barber_id === id);
  if (!cmEdit) return;
  const period = `${fmtDate($("cm-from").value)} a ${fmtDate($("cm-to").value)}`;
  $("cmd-title").textContent = `Editar ${cmEdit.barber_name}`;
  $("cmd-info").textContent = `${period} · total cobrado ${brl(cmEdit.total_cents)}`;
  $("cmd-val").value = (cmEdit.barbeiro_cents / 100).toFixed(2);
  $("cmd-pct").value = cmEdit.commission_percent;
  $("cmd-err").textContent = "";
  $("cmd-reset").hidden = cmEdit.combinado_cents === null;
  cmHouse();
  $("cmdlg").showModal();
}
$("cmd-val").oninput = cmHouse;
$("cmd-close").onclick = () => $("cmdlg").close();
async function cmSaveValue(cents) {
  await rpc("admin_commission_value", { p_token: cmToken, p_barber: cmEdit.barber_id, p_from: $("cm-from").value, p_to: $("cm-to").value, p_cents: cents });
}
$("cmd-save").onclick = async () => {
  const cents = cmValCents(), pct = parseInt($("cmd-pct").value, 10);
  if (!Number.isFinite(cents) || cents < 0) return $("cmd-err").textContent = "Digite o valor do barbeiro.";
  if (!Number.isInteger(pct) || pct < 0 || pct > 100) return $("cmd-err").textContent = "A porcentagem precisa ser de 0 a 100.";
  try {
    if (pct !== cmEdit.commission_percent) await rpc("admin_commission_percent", { p_token: cmToken, p_barber: cmEdit.barber_id, p_percent: pct });
    if (cents !== cmEdit.barbeiro_cents) await cmSaveValue(cents);
    $("cmdlg").close(); toast("Salvo"); loadCommissions().catch(e => toast(e.message));
  } catch (e) { $("cmd-err").textContent = e.message; }
};
$("cmd-reset").onclick = async () => {
  try { await cmSaveValue(null); $("cmdlg").close(); toast("Voltou para a porcentagem"); loadCommissions().catch(e => toast(e.message)); }
  catch (e) { $("cmd-err").textContent = e.message; }
};

async function loadPaySummary() {
  const r = await rpc("admin_payment_summary", { p_from: $("cm-from").value, p_to: $("cm-to").value, p_token: cmToken });
  const line = what => x => `<tr><td>${what}</td><td>${PAY[x.method] || esc(x.method)}${x.online ? " · pelo site" : ""}</td><td>${x.qtd}</td><td>${brl(x.total_cents)}</td></tr>`;
  $("ps-body").innerHTML = r.atendimentos.map(line("Atendimentos")).join("") + r.pacotes.map(line("Pacotes vendidos")).join("")
    || `<tr><td colspan="4" class="muted">Nada no período.</td></tr>`;
}

// ---------------------------------------------------------------- caixa
function setCxPeriod(kind) {
  const t = todayStr();
  const [from, to] = { today: [t, t], yesterday: [addDays(t, -1), addDays(t, -1)], week: [addDays(t, -6), t], month: [t.slice(0, 8) + "01", t] }[kind];
  $("cx-from").value = from; $("cx-to").value = to;
}
document.querySelectorAll("[data-cx]").forEach(b => b.onclick = () => { setCxPeriod(b.dataset.cx); loadCaixa(); });
$("cx-from").onchange = $("cx-to").onchange = $("cx-barber").onchange = () => loadCaixa();

async function loadCaixa() {
  if (!$("cx-from").value) setCxPeriod("today");
  const r = await rpc("staff_cashbox", { p_from: $("cx-from").value, p_to: $("cx-to").value, p_barber: $("cx-barber").value ? +$("cx-barber").value : null });
  const by = {};
  for (const e of r.entradas) { const s = by[e.method] ||= { qtd: 0, cents: 0 }; s.qtd++; s.cents += e.total_cents; }
  const total = r.entradas.reduce((s, e) => s + e.total_cents, 0);
  const tile = (label, m) => `<div class="stat"><span class="eyebrow u-m-0">${label}</span><b>${brl(by[m]?.cents || 0)}</b><small>${by[m]?.qtd || 0} lançamento(s)</small></div>`;
  $("cx-stats").innerHTML = tile("Cartão de crédito", "credito") + tile("Cartão de débito", "debito") + tile("Pix", "pix") + tile("Dinheiro", "dinheiro")
    + `<div class="stat"><span class="eyebrow u-m-0">Total</span><b>${brl(total)}</b><small>${r.entradas.length} lançamento(s)${r.cortes_pacote ? ` · ${r.cortes_pacote} corte(s) por pacote` : ""}</small></div>`
    + `<div class="stat"><span class="eyebrow u-m-0">A receber (pendente)</span><b>${brl(r.pendentes.reduce((s, p) => s + p.total_cents, 0))}</b><small>${r.pendentes.length} em aberto · qualquer data</small></div>`;
  $("cx-pend").innerHTML = r.pendentes.map(p => `<tr><td>${new Date(p.quando).toLocaleString("pt-BR", { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" })}</td>
    <td>${esc(p.cliente)}${p.phone ? `<div class="small"><a href="https://wa.me/${esc(p.phone)}" target="_blank" rel="noopener noreferrer">${fmtPhone(p.phone)}</a></div>` : `<div class="muted small">sem cadastro</div>`}</td>
    <td>${esc(p.servico)}${p.filho ? ` para ${esc(p.filho)}` : ""}<div class="muted small">${esc(p.barbeiro)}${p.consumo ? ` · ${esc(p.consumo)}` : ""}</div></td>
    <td><b>${brl(p.total_cents)}</b></td><td><button class="btn btn-main btn-sm" data-cxsettle="${p.id}">Receber</button></td></tr>`).join("")
    + (r.recebidos || []).map(p => `<tr class="row-done"><td>${new Date(p.quando).toLocaleString("pt-BR", { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" })}</td>
    <td>${esc(p.cliente)}</td>
    <td>${esc(p.servico)}${p.filho ? ` para ${esc(p.filho)}` : ""}<div class="small">${esc(p.barbeiro)}</div></td>
    <td>${brl(p.total_cents)}</td><td><span class="pay-chip late">Recebido · ${PAY[p.method] || ""}</span></td></tr>`).join("")
    || `<tr><td colspan="5" class="muted">Nada pendente.</td></tr>`;
  $("cx-pend").querySelectorAll("[data-cxsettle]").forEach(b => b.onclick = () => {
    const p = r.pendentes.find(x => x.id === +b.dataset.cxsettle);
    settle(p.id, `${p.filho ? `${p.filho} (filho de ${p.cliente})` : p.cliente} · ${p.servico}`, p.total_cents, loadCaixa);
  });
  const semForma = by.nao_informado;
  $("cx-warn").hidden = !semForma;
  if (semForma) $("cx-warn").textContent = `${semForma.qtd} atendimento(s) concluído(s) sem forma de pagamento (${brl(semForma.cents)}): entram no total, mas não em nenhuma forma.`;
  const when = iso => new Date(iso).toLocaleString("pt-BR", { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" });
  $("cx-body").innerHTML = r.entradas.map(e => `<tr><td>${when(e.quando)}</td><td>${esc(e.cliente)}</td>
    <td>${esc(e.item)}<div class="muted small">${e.tipo === "pacote" ? "venda de pacote" : e.tipo === "consumo" ? `consumo · ${esc(e.barbeiro)}` : esc(e.barbeiro)}</div></td>
    <td>${PAY[e.method] || esc(e.method)}${e.online ? " · pelo site" : ""}
      ${e.tipo === "atendimento" && !e.online ? `<div><a href="#" class="small" data-cxfix="${e.id}">corrigir</a></div>` : ""}</td>
    <td><b>${brl(e.total_cents)}</b></td></tr>`).join("")
    || `<tr><td colspan="5" class="muted">Nenhuma entrada no período.</td></tr>`;
  $("cx-body").querySelectorAll("[data-cxfix]").forEach(a => a.onclick = ev => {
    ev.preventDefault();
    const e = r.entradas.find(x => x.tipo === "atendimento" && x.id === +a.dataset.cxfix);
    fixPay(e.id, `${e.cliente} · ${e.item} · ${brl(e.total_cents)}`, e.method === "nao_informado" ? null : e.method, loadCaixa);
  });
}

// ---------------------------------------------------------------- pacotes
const PK ={ client: null, catalog: [] };
let pkTimer, psTimer;
async function loadPacotes() {
  PK.catalog = await rpc("admin_packages");
  $("ps-pkg").innerHTML = PK.catalog.filter(k => k.active).map(k =>
    `<option value="${k.id}">${esc(k.name)} · ${k.qty}x ${esc(k.service_name)} · ${brl(k.price_cents)}${k.kind === "plano" ? " / mês" : ""}</option>`).join("")
    || `<option value="">Cadastre um pacote primeiro</option>`;
  if (isAdmin()) await loadCatalog();
  await loadClientPkgs();
}

const METHOD_SEL = `<select class="u-w-auto" data-m><option value="pix">Pix</option><option value="credito">Crédito</option><option value="debito">Débito</option><option value="dinheiro">Dinheiro</option></select>`;
async function loadClientPkgs() {
  const rows = await rpc("admin_client_packages", { p_q: $("pk-q").value.trim() });
  $("pk-list").innerHTML = rows.length ? rows.map(p => `<div class="li" data-id="${p.id}"><div class="grow">
      <div class="row u-gap-8"><h3>${esc(p.client_name)}</h3>
        <span class="badge ${p.status === "ativo" ? "confirmado" : p.status === "pendente" ? "pendente" : "cancelado"}">${{ ativo: "ativo", pendente: "esperando pagamento", vencido: "vencido" }[p.status] || esc(p.status)}</span>
        ${p.kind === "plano" ? `<span class="badge">mensal</span>` : ""}</div>
      <div class="muted small">${esc(p.name)} · ${p.status === "pendente" ? `${p.qty}x ${esc(p.service_name)} · ${brl(p.price_cents)} · pedido pelo site`
        : `${p.left} de ${p.qty} restantes · vale até ${esc(p.valid_until_fmt)} · ${p.paid_online ? "pago pelo site" : "pago"} no ${PAY[p.pay_method] || "—"}`}</div></div>
      <div class="row">
        <a class="btn btn-ghost btn-sm" target="_blank" rel="noopener noreferrer" href="https://wa.me/${esc(p.client_phone)}">WhatsApp</a>
        ${p.status === "pendente" ? `${METHOD_SEL}<button class="btn btn-main btn-sm" data-activate>Ativar (pago)</button>` : ""}
        ${p.kind === "plano" && p.status !== "pendente" && p.package_id ? `${METHOD_SEL}<button class="btn btn-main btn-sm" data-renew>Renovar mês</button>` : ""}
        ${isAdmin() ? `<button class="btn btn-bad btn-sm" data-cancel-pkg>Cancelar</button>` : ""}
      </div></div>`).join("") : `<p class="empty">Nenhum pacote ativo.</p>`;
  $("pk-list").querySelectorAll(".li[data-id]").forEach(li => {
    const p = rows.find(x => x.id === +li.dataset.id), m = () => li.querySelector("[data-m]").value;
    const run = async (fn, args, msg) => { try { await rpc(fn, args); toast(msg); loadClientPkgs(); } catch (e) { toast(e.message); } };
    li.querySelector("[data-activate]")?.addEventListener("click", () => run("admin_activate_package", { p_id: p.id, p_method: m() }, "Pacote ativado"));
    li.querySelector("[data-renew]")?.addEventListener("click", async () => {
      if (await ask(`Renovar ${p.name} de ${p.client_name} por mais um mês?`, "Renovar"))
        run("admin_sell_package", { p_user: p.user_id, p_package: p.package_id, p_method: m() }, "Mês renovado");
    });
    li.querySelector("[data-cancel-pkg]")?.addEventListener("click", async () => {
      if (await ask(`Cancelar o pacote de ${p.client_name}? Os cortes que sobraram deixam de valer.`, "Cancelar pacote", true)) run("admin_cancel_package", { p_id: p.id }, "Pacote cancelado");
    });
  });
}
$("pk-q").oninput = () => { clearTimeout(pkTimer); pkTimer = setTimeout(loadClientPkgs, 300); };

$("ps-q").oninput = () => {
  clearTimeout(psTimer);
  psTimer = setTimeout(async () => {
    const rows = await rpc("admin_find_clients", { p_q: $("ps-q").value });
    $("ps-results").innerHTML = rows.map(c => `<button type="button" class="opt u-pad-opt" data-id="${c.id}">
      <div class="grow"><b>${esc(c.name)}</b><div class="muted small">${fmtPhone(c.phone)}</div></div></button>`).join("")
      || ($("ps-q").value.trim().length >= 2 ? `<p class="muted small">Ninguém encontrado. Cadastre pelo "+ Agendar cliente" na Agenda.</p>` : "");
    $("ps-results").querySelectorAll("[data-id]").forEach(b => b.onclick = () => {
      PK.client = rows.find(c => c.id === b.dataset.id);
      $("ps-client").textContent = `${PK.client.name} · ${fmtPhone(PK.client.phone)}`;
      $("ps-form").hidden = false; $("ps-results").innerHTML = ""; $("ps-q").value = "";
    });
  }, 250);
};
$("ps-change").onclick = e => { e.preventDefault(); PK.client = null; $("ps-form").hidden = true; $("ps-q").focus(); };
$("ps-sell").onclick = async () => {
  const k = PK.catalog.find(x => x.id === +$("ps-pkg").value);
  if (!PK.client || !k) return toast("Escolha o cliente e o pacote.");
  if (!await ask(`Vender ${k.name} (${brl(k.price_cents)}, ${PAY[$("ps-method").value]}) para ${PK.client.name}?`, "Vender")) return;
  try {
    await rpc("admin_sell_package", { p_user: PK.client.id, p_package: k.id, p_method: $("ps-method").value });
    toast("Pacote vendido e ativo"); PK.client = null; $("ps-form").hidden = true; loadClientPkgs();
  } catch (e) { toast(e.message); }
};

let SVC_CACHE = [];
async function loadCatalog() {
  if (!SVC_CACHE.length) SVC_CACHE = await rpc("admin_services");
  $("pkc-body").innerHTML = PK.catalog.map(pkcRow).join("");
  bindPkc();
}
const pkcRow = k => `<tr data-id="${k.id ?? ""}">
  <td><input class="u-w-60" type="number" name="sort" value="${k.sort ?? 0}"></td>
  <td><select class="u-w-auto" name="kind"><option value="pacote" ${k.kind !== "plano" ? "selected" : ""}>Pacote</option><option value="plano" ${k.kind === "plano" ? "selected" : ""}>Plano mensal</option></select></td>
  <td><input name="name" value="${esc(k.name ?? "")}" placeholder="Ex.: Pacote 3 cortes" maxlength="60"></td>
  <td><select class="u-w-auto" name="service_id">${SVC_CACHE.map(s => `<option value="${s.id}" ${s.id === k.service_id ? "selected" : ""}>${esc(s.name)}</option>`).join("")}</select></td>
  <td><input class="u-w-64" name="qty" type="number" min="1" max="30" value="${k.qty ?? 3}"></td>
  <td><input class="u-w-100" name="price" type="number" step="0.01" min="1" value="${((k.price_cents ?? 0) / 100).toFixed(2)}"></td>
  <td><input class="u-w-72" name="valid_days" type="number" min="7" max="366" value="${k.valid_days ?? 60}"></td>
  <td><input class="u-minw-160" name="plan_link" value="${esc(k.plan_link ?? "")}" placeholder="https://"></td>
  <td><input name="active" type="checkbox" ${k.active ?? true ? "checked" : ""}></td>
  <td><button class="btn btn-main btn-sm" data-save>Salvar</button></td></tr>`;
function bindPkc() {
  $("pkc-body").querySelectorAll("[data-save]").forEach(btn => btn.onclick = async () => {
    const tr = btn.closest("tr"), v = n => tr.querySelector(`[name=${n}]`);
    const p = { sort: +v("sort").value, kind: v("kind").value, name: v("name").value, service_id: +v("service_id").value, qty: +v("qty").value,
      price_cents: Math.round(parseFloat(v("price").value.replace(",", ".")) * 100), valid_days: +v("valid_days").value,
      plan_link: v("plan_link").value.trim(), active: v("active").checked };
    if (tr.dataset.id) p.id = +tr.dataset.id;
    try { await rpc("admin_save_package", { p }); toast("Pacote salvo"); loadPacotes(); } catch (e) { toast(e.message); }
  });
}
$("pkc-add").onclick = async () => {
  if (!SVC_CACHE.length) SVC_CACHE = await rpc("admin_services");
  $("pkc-body").insertAdjacentHTML("beforeend", pkcRow({})); bindPkc();
};

// ---------------------------------------------------------------- agendar cliente pelo balcão
const NB = { client: null, time: null, services: [] };
let nbTimer;
$("new-booking").onclick = async () => {
  NB.client = null; NB.time = null;
  if (!NB.services.length) NB.services = (await rpc("admin_services")).filter(s => s.active);
  $("nb-service").innerHTML = NB.services.map(s => `<option value="${s.id}">${esc(s.name)} · ${s.price_from ? "a partir de " : ""}${brl(s.price_cents)}</option>`).join("");
  $("nb-barber").innerHTML = barberOptions(false);
  if (!isAdmin()) { $("nb-barber").value = ME.barber_id; $("nb-barber").disabled = true; }
  $("nb-date").value = $("date").value || todayStr();
  for (const id of ["nb-q", "nb-name", "nb-phone", "nb-birth"]) $(id).value = "";
  $("nb-results").innerHTML = ""; $("nb-err").textContent = ""; $("nb-new").open = false;
  $("nb-force").checked = false; $("nb-free-wrap").hidden = true; $("nb-use-pkg").checked = false;
  nbStep("client");
  wkReset();
  nbMode("marcar");
  $("nb").showModal();
  $("nb-q").focus();
};

// Abas da janela: marcar um horário ou registrar um encaixe já atendido
function nbMode(mode) {
  $("nb-mode").querySelectorAll("[data-mode]").forEach(b => b.setAttribute("aria-selected", b.dataset.mode === mode));
  $("wk").hidden = mode !== "encaixe";
  $("nb-step-client").hidden = mode !== "marcar" || !!NB.client;
  $("nb-step-slot").hidden = mode !== "marcar" || !NB.client;
  $("nb-save").hidden = mode !== "marcar" || !NB.client;
  $("nb-err").textContent = "";
}
$("nb-mode").querySelectorAll("[data-mode]").forEach(b => b.onclick = () => nbMode(b.dataset.mode));

// ---------------------------------------------------------------- encaixe (atendimento já feito)
const WK = { client: null, picked: [] };
let wkTimer;
function wkReset() {
  WK.client = null;
  WK.picked = NB.services[0] ? [NB.services[0].id] : [];
  wkServices();
  $("wk-barber").innerHTML = barberOptions(false);
  if (!isAdmin()) { $("wk-barber").value = ME.barber_id; $("wk-barber").disabled = true; }
  const day = $("date").value;
  $("wk-date").max = todayStr(); $("wk-date").min = addDays(todayStr(), -7);
  $("wk-date").value = day && day <= todayStr() && day >= addDays(todayStr(), -7) ? day : todayStr();
  $("wk-time").value = new Date().toTimeString().slice(0, 5);
  for (const id of ["wk-q", "wk-name", "wk-phone"]) $(id).value = "";
  $("wk-pay").value = "pix"; $("wk-results").innerHTML = "";
  wkShowClient();
}
function wkShowClient() {
  $("wk-client-pick").hidden = !!WK.client;
  $("wk-client-chosen").hidden = !WK.client;
  if (WK.client) $("wk-client").textContent = `${WK.client.name} · ${fmtPhone(WK.client.phone)}`;
}
$("wk-change").onclick = e => { e.preventDefault(); WK.client = null; wkShowClient(); };
// Serviços do encaixe: toca para marcar (pode marcar vários); o valor sugerido é a soma
function wkServices() {
  $("wk-services").innerHTML = NB.services.map(s => {
    const n = WK.picked.indexOf(s.id);
    return `<button type="button" class="svc-pick" data-id="${s.id}" aria-pressed="${n >= 0}">
      <b>${esc(s.name)}</b><small>${s.price_from ? "a partir de " : ""}${brl(s.price_cents)}</small></button>`;
  }).join("");
  $("wk-services").querySelectorAll("[data-id]").forEach(b => b.onclick = () => {
    const id = +b.dataset.id, i = WK.picked.indexOf(id);
    if (i >= 0) WK.picked.splice(i, 1); else if (WK.picked.length < 6) WK.picked.push(id);
    wkServices();
  });
  const list = WK.picked.map(id => NB.services.find(s => s.id === id)).filter(Boolean);
  const sum = list.reduce((t, s) => t + s.price_cents, 0);
  $("wk-sum").textContent = list.length ? `${list.map(s => s.name).join(" + ")} · ${list.some(s => s.price_from) ? "a partir de " : ""}${brl(sum)}` : "Marque pelo menos um serviço.";
  $("wk-price").value = (sum / 100).toFixed(2);
}
$("wk-q").oninput = () => {
  clearTimeout(wkTimer);
  wkTimer = setTimeout(async () => {
    const q = $("wk-q").value.trim();
    if (q.length < 2) { $("wk-results").innerHTML = ""; return; }
    const rows = await rpc("admin_find_clients", { p_q: q });
    $("wk-results").innerHTML = rows.map(c => `<button type="button" class="opt u-pad-opt" data-id="${c.id}">
      <div class="grow"><b>${esc(c.name)}</b><div class="muted small">${fmtPhone(c.phone)}</div></div></button>`).join("")
      || `<p class="muted small">Ninguém com esse nome. Digite o nome abaixo (e o telefone, se quiser cadastrar).</p>`;
    $("wk-results").querySelectorAll("[data-id]").forEach(b => b.onclick = () => { WK.client = rows.find(c => c.id === b.dataset.id); wkShowClient(); });
  }, 250);
};
$("wk-save").onclick = async () => {
  $("nb-err").textContent = "";
  const price = Math.round(parseFloat(String($("wk-price").value).replace(",", ".")) * 100);
  if (!Number.isFinite(price) || price < 0) return ($("nb-err").textContent = "Digite o valor cobrado.");
  if (!$("wk-time").value) return ($("nb-err").textContent = "Digite que horas o cliente chegou.");
  if (!WK.picked.length) return ($("nb-err").textContent = "Marque pelo menos um serviço.");
  $("wk-save").disabled = true;
  try {
    const b = await rpc("staff_walkin", { p_barber: +$("wk-barber").value, p_service: WK.picked[0], p_extras: WK.picked.length > 1 ? WK.picked.slice(1) : null, p_date: $("wk-date").value,
      p_time: $("wk-time").value, p_price_cents: price, p_pay_method: $("wk-pay").value, p_user: WK.client?.id ?? null,
      p_name: WK.client ? null : $("wk-name").value, p_phone: WK.client ? null : $("wk-phone").value, p_items: null });
    $("nb").close();
    toast(`Encaixe registrado: ${who(b)} · ${b.service_name} · ${brl(b.final_price_cents)}`);
    $("date").value = $("wk-date").value;
    loadAgenda();
  } catch (e) { $("nb-err").textContent = e.message; }
  finally { $("wk-save").disabled = false; }
};

function nbStep(step) {
  $("nb-step-client").hidden = step !== "client";
  $("nb-step-slot").hidden = step !== "slot";
  $("nb-save").hidden = step !== "slot";
  if (step === "slot") {
    $("nb-client").textContent = `${NB.client.name} · ${fmtPhone(NB.client.phone)}`;
    $("nb-child").value = ""; $("nb-kids").innerHTML = "";
    rpc("admin_children", { p_user: NB.client.id })
      .then(kids => { $("nb-kids").innerHTML = kids.map(k => `<option value="${esc(k.name)}">`).join(""); }).catch(() => {});
    nbTimes();
  }
}

$("nb-q").oninput = () => {
  clearTimeout(nbTimer);
  nbTimer = setTimeout(async () => {
    const rows = await rpc("admin_find_clients", { p_q: $("nb-q").value });
    $("nb-results").innerHTML = rows.map(c => `<button type="button" class="opt u-pad-opt" data-id="${c.id}">
      <div class="grow"><b>${esc(c.name)}</b><div class="muted small">${fmtPhone(c.phone)}${c.has_login ? "" : " · balcão"}</div></div></button>`).join("")
      || ($("nb-q").value.trim().length >= 2 ? `<p class="muted small">Ninguém encontrado. Cadastre como cliente novo abaixo.</p>` : "");
    $("nb-results").querySelectorAll("[data-id]").forEach(b => b.onclick = () => {
      NB.client = rows.find(c => c.id === b.dataset.id);
      nbStep("slot");
    });
  }, 250);
};

$("nb-create").onclick = async () => {
  $("nb-err").textContent = "";
  try {
    NB.client = await rpc("admin_create_client", { p_name: $("nb-name").value, p_phone: $("nb-phone").value, p_birth_date: $("nb-birth").value || null });
    if (NB.client.existing) toast("Esse telefone já estava cadastrado. Usando o cliente existente.");
    nbStep("slot");
  } catch (e) { $("nb-err").textContent = e.message; }
};
$("nb-change").onclick = e => { e.preventDefault(); nbStep("client"); };

async function nbTimes() {
  NB.time = null; $("nb-save").disabled = true; $("nb-err").textContent = "";
  if ($("nb-force").checked) { $("nb-times").innerHTML = ""; $("nb-save").disabled = !$("nb-free").value; return; }
  try {
    const times = await rpc("admin_free_slots", { p_service: +$("nb-service").value, p_date: $("nb-date").value, p_barber: +$("nb-barber").value });
    $("nb-times").innerHTML = times.length ? times.map(t => `<button type="button" class="time" data-t="${t}">${t}</button>`).join("")
      : `<p class="muted small u-full">Sem horário livre nesse dia. Use o encaixe se quiser.</p>`;
    $("nb-times").querySelectorAll(".time").forEach(b => b.onclick = () => {
      NB.time = b.dataset.t;
      $("nb-times").querySelectorAll(".time").forEach(x => x.setAttribute("aria-pressed", x === b));
      $("nb-save").disabled = false;
    });
  } catch (e) { $("nb-err").textContent = e.message; }
}
$("nb-service").onchange = $("nb-barber").onchange = $("nb-date").onchange = () => nbTimes();
$("nb-force").onchange = e => { $("nb-free-wrap").hidden = !e.target.checked; nbTimes(); };
$("nb-free").oninput = () => { $("nb-save").disabled = !$("nb-free").value; };

$("nb-save").onclick = async () => {
  const force = $("nb-force").checked;
  try {
    await rpc("admin_create_booking", { p_user: NB.client.id, p_service: +$("nb-service").value, p_date: $("nb-date").value,
      p_time: force ? $("nb-free").value : NB.time, p_barber: +$("nb-barber").value, p_force: force,
      p_use_package: $("nb-use-pkg").checked, p_child_name: $("nb-child").value.trim() || null });
    $("nb").close();
    toast(`Agendado: ${NB.client.name}`);
    $("date").value = $("nb-date").value;
    loadAgenda();
  } catch (e) { $("nb-err").textContent = e.message; }
};

// ---------------------------------------------------------------- serviços
async function loadServices() {
  const [rows, prods, promos] = await Promise.all([rpc("admin_services"), rpc("admin_products"), rpc("admin_promotions")]);
  PROMO_SVCS = rows;
  $("promo-list").innerHTML = promos.length ? promos.map(promoCard).join("") : `<p class="muted small">Nenhuma promoção cadastrada.</p>`;
  bindPromos();
  $("svc-body").innerHTML = rows.map(svcRow).join("");
  bindSvc();
  PRODUCTS = prods;
  $("prod-body").innerHTML = prods.map(prodRow).join("");
  bindProd();
  if (cmToken) loadSvcCommission().catch(e => toast(e.message));
}

// Promoções da página inicial: o dono escolhe o serviço (ou escreve livre), o preço,
// e se está disponível (verde para o cliente) ou indisponível (vermelho)
let PROMO_SVCS = [];
const cents = v => v === "" ? null : Math.round(parseFloat(String(v).replace(",", ".")) * 100);
const money = c => c == null ? "" : (c / 100).toFixed(2);
const promoBadges = (active, visible) =>
  `<span class="badge ${active ? "confirmado" : "cancelado"}">${active ? "Disponível" : "Indisponível"}</span>` +
  (visible ? "" : ` <span class="badge">Oculta no site</span>`);
const promoCard = p => {
  const active = p.active ?? true, visible = p.visible ?? true;
  const svcOpts = PROMO_SVCS.map(s => `<option value="${s.id}" ${s.id === p.service_id ? "selected" : ""}>${esc(s.name)} (${brl(s.price_cents)})${s.active ? "" : " · inativo"}</option>`).join("");
  return `<div class="card stack" data-id="${p.id ?? ""}">
  <div class="spread"><b>${esc(p.title || "Nova promoção")}</b><span data-badges>${promoBadges(active, visible)}</span></div>
  <div class="grid2">
    <label>Serviço<select name="service"><option value="">Nenhum (promoção livre)</option>${svcOpts}</select></label>
    <label>Título<input name="title" value="${esc(p.title ?? "")}" maxlength="60" placeholder="Ex.: Degradê e Barba"></label>
    <label>Etiqueta (pequena, em cima)<input name="tag" value="${esc(p.tag ?? "")}" maxlength="30" placeholder="Ex.: Seg a Qua"></label>
    <label>Texto<textarea name="body" maxlength="240" rows="2" placeholder="O que o cliente ganha e quando vale">${esc(p.body ?? "")}</textarea></label>
    <div class="grid2">
      <label>De (R$, riscado)<input name="from" type="number" step="0.01" min="0" value="${money(p.from_cents)}" placeholder="opcional"></label>
      <label>Por (R$)<input name="price" type="number" step="0.01" min="0" value="${money(p.price_cents)}" placeholder="sem preço"></label>
    </div>
    <label>Ordem no site<input name="sort" type="number" value="${p.sort ?? 0}"></label>
  </div>
  <div class="spread"><div class="row">
      <label class="check"><input type="checkbox" name="active" ${active ? "checked" : ""}> Disponível <span class="muted small">(verde; desmarcado = vermelho "Indisponível")</span></label>
      <label class="check"><input type="checkbox" name="visible" ${visible ? "checked" : ""}> Mostrar no site</label></div>
    <div class="row">${p.id ? `<button class="btn btn-bad btn-sm" data-del>Excluir</button>` : ""}<button class="btn btn-main btn-sm" data-save>Salvar</button></div></div>
</div>`;
};
function bindPromos() {
  $("promo-list").querySelectorAll(".card").forEach(card => {
    const v = n => card.querySelector(`[name=${n}]`);
    // Ao escolher o serviço: preenche o título (se vazio) e o preço normal como "De"
    v("service").onchange = () => {
      const svc = PROMO_SVCS.find(s => s.id === +v("service").value);
      if (!svc) return;
      if (!v("title").value.trim()) v("title").value = svc.name;
      v("from").value = money(svc.price_cents);
    };
    const badges = () => card.querySelector("[data-badges]").innerHTML = promoBadges(v("active").checked, v("visible").checked);
    v("active").onchange = badges; v("visible").onchange = badges;
  });
  $("promo-list").querySelectorAll("[data-save]").forEach(btn => btn.onclick = async () => {
    const card = btn.closest(".card"), v = n => card.querySelector(`[name=${n}]`);
    const p = { title: v("title").value, tag: v("tag").value, body: v("body").value, sort: +v("sort").value || 0,
      from_cents: cents(v("from").value), price_cents: cents(v("price").value), active: v("active").checked,
      visible: v("visible").checked, service_id: v("service").value ? +v("service").value : null };
    if (card.dataset.id) p.id = +card.dataset.id;
    try { await rpc("admin_save_promotion", { p }); toast(!p.visible ? "Promoção salva (oculta no site)" : p.active ? "Promoção salva: aparece como Disponível" : "Promoção salva: aparece como Indisponível"); loadServices(); }
    catch (e) { toast(e.message); }
  });
  $("promo-list").querySelectorAll("[data-del]").forEach(btn => btn.onclick = async () => {
    const card = btn.closest(".card");
    if (!confirm("Excluir esta promoção? Para só tirar do site, desmarque \"Mostrar no site\" e salve.")) return;
    try { await rpc("admin_delete_promotion", { p_id: +card.dataset.id }); toast("Promoção excluída"); loadServices(); }
    catch (e) { toast(e.message); }
  });
}
$("promo-add").onclick = () => {
  if ($("promo-list").querySelector("p.muted")) $("promo-list").innerHTML = "";
  $("promo-list").insertAdjacentHTML("beforeend", promoCard({})); bindPromos();
};

// Consumíveis: bebidas e outros vendidos no balcão
const prodRow = p => `<tr data-id="${p.id ?? ""}">
  <td><input class="u-w-64" type="number" name="sort" value="${p.sort ?? 0}"></td>
  <td><input name="name" value="${esc(p.name ?? "")}" placeholder="Ex.: Coca-Cola lata" maxlength="60"></td>
  <td><input class="u-w-100" name="price" type="number" step="0.01" min="0" value="${((p.price_cents ?? 0) / 100).toFixed(2)}"></td>
  <td><input name="active" type="checkbox" ${p.active ?? true ? "checked" : ""}></td>
  <td><button class="btn btn-main btn-sm" data-save>Salvar</button></td></tr>`;
function bindProd() {
  $("prod-body").querySelectorAll("[data-save]").forEach(btn => btn.onclick = async () => {
    const tr = btn.closest("tr"), v = n => tr.querySelector(`[name=${n}]`);
    const p = { name: v("name").value, sort: +v("sort").value, active: v("active").checked,
      price_cents: Math.round(parseFloat(v("price").value.replace(",", ".")) * 100) };
    if (tr.dataset.id) p.id = +tr.dataset.id;
    try { await rpc("admin_save_product", { p }); toast("Consumível salvo"); loadServices(); } catch (e) { toast(e.message); }
  });
}
$("prod-add").onclick = () => { $("prod-body").insertAdjacentHTML("beforeend", prodRow({})); bindProd(); };
const svcRow = s => `<tr data-id="${s.id ?? ""}">
  <td><input class="u-w-64" type="number" name="sort" value="${s.sort ?? 0}"></td>
  <td><input name="name" value="${esc(s.name ?? "")}" placeholder="Nome" maxlength="60"></td>
  <td><input name="description" value="${esc(s.description ?? "")}" maxlength="200"></td>
  <td><input class="u-w-100" name="price" type="number" step="0.01" min="0" value="${((s.price_cents ?? 0) / 100).toFixed(2)}"></td>
  <td><input name="price_from" type="checkbox" ${s.price_from ? "checked" : ""}></td>
  <td><input class="u-w-80" name="duration_min" type="number" min="5" step="5" value="${s.duration_min ?? 30}"></td>
  <td><input name="active" type="checkbox" ${s.active ?? true ? "checked" : ""}></td>
  <td><button class="btn btn-main btn-sm" data-save>Salvar</button></td></tr>`;
function bindSvc() {
  $("svc-body").querySelectorAll("[data-save]").forEach(btn => btn.onclick = async () => {
    const tr = btn.closest("tr"), v = n => tr.querySelector(`[name=${n}]`);
    const p = { name: v("name").value, description: v("description").value, sort: +v("sort").value,
      price_cents: Math.round(parseFloat(v("price").value.replace(",", ".")) * 100), price_from: v("price_from").checked,
      duration_min: +v("duration_min").value, active: v("active").checked };
    if (tr.dataset.id) p.id = +tr.dataset.id;
    try { await rpc("admin_save_service", { p }); toast("Serviço salvo"); loadServices(); } catch (e) { toast(e.message); }
  });
}
$("svc-add").onclick = () => { $("svc-body").insertAdjacentHTML("beforeend", svcRow({})); bindSvc(); };

// Comissão por serviço: quanto vai para o barbeiro e quanto fica para a casa em cada serviço.
// Vazio = cada barbeiro segue a própria % (aba Comissões). Mesma senha da aba Comissões.
async function scUnlock() {
  $("sc-open").disabled = true;
  try {
    const r = await rpc("admin_commission_unlock", { p_pass: $("sc-pass").value });
    if (!r.ok) { $("sc-err").textContent = r.error; $("sc-pass").value = ""; $("sc-pass").focus(); return; }
    cmToken = r.token; $("sc-pass").value = $("sc-err").textContent = ""; cmTouch();
    await loadSvcCommission();
  } catch (e) { $("sc-err").textContent = e.message; }
  finally { $("sc-open").disabled = false; }
}
$("sc-open").onclick = scUnlock;
$("sc-pass").onkeydown = e => { if (e.key === "Enter") scUnlock(); };

let scBarber = null;
const scSplit = (pct, price) => `${brl(Math.round(price * pct / 100))} barbeiro · ${brl(price - Math.round(price * pct / 100))} casa`;
const scCells = (pct, base, price) => {
  const eff = pct === "" ? base : pct, tag = pct === "" ? ` <span class="muted small">(geral)</span>` : "";
  return [`${100 - eff}%${tag}`, scSplit(eff, price)];
};
const scRow = (s, base) => {
  const [house, split] = scCells(s.percent ?? "", base, s.price_cents);
  return `<tr data-id="${s.id}" data-price="${s.price_cents}">
  <td><b>${esc(s.name)}</b>${s.active ? "" : ` <span class="muted small">(inativo)</span>`}</td>
  <td>${s.price_from ? "a partir de " : ""}${brl(s.price_cents)}</td>
  <td><input class="u-w-80" name="pct" type="number" min="0" max="100" step="1" value="${s.percent ?? ""}" placeholder="${base}"></td>
  <td data-house>${house}</td>
  <td class="small" data-split>${split}</td>
  <td><button class="btn btn-main btn-sm" data-save>Salvar</button></td></tr>`;
};
async function loadSvcCommission() {
  if (!cmToken) { $("sc-gate").hidden = false; $("sc-content").hidden = true; return; }
  if (!scBarber || !BARBERS.some(b => b.id === scBarber)) scBarber = (BARBERS.find(b => b.active) || BARBERS[0])?.id;
  $("sc-barbers").innerHTML = BARBERS.map(b => `<button data-b="${b.id}" aria-selected="${b.id === scBarber}">${esc(b.name)}${b.active ? "" : " (inativo)"}</button>`).join("");
  $("sc-barbers").querySelectorAll("[data-b]").forEach(btn => btn.onclick = () => { scBarber = +btn.dataset.b; loadSvcCommission().catch(e => toast(e.message)); });
  let r;
  try { r = await rpc("admin_service_commissions", { p_token: cmToken, p_barber: scBarber }); }
  catch (e) { if (e.message.includes("senha das comissões")) cmLock(); throw e; }
  cmTouch();
  const base = r.barber.commission_percent, name = esc(r.barber.name);
  $("sc-help").innerHTML = `Quanto o <b>${name}</b> recebe em cada serviço; o resto fica para a <b>casa</b>. Vale para os próximos atendimentos concluídos dele (o que já foi concluído não muda).
    Campo vazio = a % geral dele (<b>${base}%</b>, aba Comissões).`;
  $("sc-body").innerHTML = r.services.map(x => scRow(x, base)).join("");
  $("sc-gate").hidden = true; $("sc-content").hidden = false;
  $("sc-body").querySelectorAll("tr").forEach(tr => {
    const inp = tr.querySelector("[name=pct]");
    inp.oninput = () => {
      const v = inp.value.trim(), pct = v === "" ? "" : Math.min(100, Math.max(0, parseInt(v, 10) || 0));
      const [house, split] = scCells(pct, base, +tr.dataset.price);
      tr.querySelector("[data-house]").innerHTML = house; tr.querySelector("[data-split]").innerHTML = split;
    };
    tr.querySelector("[data-save]").onclick = async () => {
      const v = inp.value.trim(), pct = v === "" ? null : parseInt(v, 10);
      if (pct !== null && (!Number.isInteger(pct) || pct < 0 || pct > 100)) return toast("A porcentagem precisa ser de 0 a 100.");
      try { await scSave(+tr.dataset.id, pct); toast(pct === null ? `${r.barber.name}: volta para a % geral (${base}%)` : `${r.barber.name}: ${pct}% barbeiro · ${100 - pct}% casa`); }
      catch (e) { toast(e.message); }
    };
  });
}
async function scSave(service, pct) {
  try { await rpc("admin_service_commission", { p_token: cmToken, p_barber: scBarber, p_service: service, p_percent: pct }); cmTouch(); }
  catch (e) { if (e.message.includes("senha das comissões")) cmLock(); throw e; }
}
async function scSaveAll(pct) {
  const name = BARBERS.find(b => b.id === scBarber)?.name ?? "";
  try {
    await scSave(null, pct);
    toast(pct === null ? `${name}: todos os serviços voltaram para a % geral` : `${name}: ${pct}% em todos os serviços`);
    loadSvcCommission().catch(e => toast(e.message));
  } catch (e) { toast(e.message); }
}
$("sc-all-btn").onclick = () => {
  const pct = parseInt($("sc-all").value, 10);
  if (!Number.isInteger(pct) || pct < 0 || pct > 100) return toast("Digite de 0 a 100.");
  const name = BARBERS.find(b => b.id === scBarber)?.name ?? "";
  if (confirm(`${name}: colocar ${pct}% para ele e ${100 - pct}% para a casa em TODOS os serviços?`)) scSaveAll(pct);
};
$("sc-clear-btn").onclick = () => {
  const name = BARBERS.find(b => b.id === scBarber)?.name ?? "";
  if (confirm(`${name}: todos os serviços voltam para a % geral dele (aba Comissões)?`)) scSaveAll(null);
};

// ---------------------------------------------------------------- barbeiros
const WEEK = ["Domingo", "Segunda", "Terça", "Quarta", "Quinta", "Sexta", "Sábado"];
async function loadBarbers() {
  BARBERS = await rpc("admin_barbers");
  $("barbers").innerHTML = BARBERS.map(barberCard).join("");
  bindBarbers();
  loadDaySlots().catch(e => toast(e.message));
}

// Grade de um dia, barbeiro por barbeiro: livre, ocupado (com quem), bloqueado, já passou.
// Feita para o celular: tocar só MARCA o horário; a barra embaixo aplica (bloquear / liberar), sem janelas.
const dayOptions = () => Array.from({ length: 31 }, (_, i) => addDays(todayStr(), i))
  .map((d, i) => `<option value="${d}">${i === 0 ? "Hoje · " : i === 1 ? "Amanhã · " : ""}${dateLabel(d)}</option>`).join("");

async function renderDayGrid(grid, sum, day, barber, reload) {
  const rows = await rpc("staff_day_slots", { p_day: day, p_barber: barber });
  const all = rows.flatMap(r => r.slots);
  const n = st => all.filter(s => s.status === st).length;
  sum.textContent = ` · ${n("livre")} livre(s), ${n("ocupado")} ocupado(s), ${n("bloqueado")} bloqueado(s)`;
  grid.innerHTML = rows.map(r => `<div class="barber-day">
      <div class="barber-day-head"><b>${esc(r.barber_name)}</b>
        <span class="muted small">${r.hours.length ? `expediente ${r.hours.join(", ")}` : "não trabalha nesse dia"}${r.special ? " · horário especial" : ""}</span>
        ${r.closed ? `<span class="badge erro">agenda fechada</span>` : ""}</div>
      ${r.slots.some(s => s.status !== "passou") ? `<div class="row day-actions">
        <button type="button" class="btn btn-main btn-sm" data-day-open="${r.barber_id}">Liberar o dia todo</button>
        <button type="button" class="btn btn-bad btn-sm" data-day-close="${r.barber_id}">Bloquear o dia todo</button></div>` : ""}
      ${r.slots.length ? `<div class="times">${r.slots.map(s => `<button type="button" class="slot-chip ${s.status}" data-b="${r.barber_id}" data-t="${s.time}"
        data-st="${s.status}" ${s.status === "passou" ? "disabled" : ""} aria-pressed="false">
        <b>${s.time}</b><small>${s.status === "ocupado" ? esc(s.cliente.split(" (")[0].split(" ")[0])
          : s.status === "bloqueado" ? "bloqueado" : s.status === "livre" ? "livre" : "passou"}</small></button>`).join("")}</div>` : ""}
    </div>`).join("") + `<div class="slot-bar" hidden>
      <span class="small"><b class="slot-count">0</b> selecionado(s)</span>
      <button type="button" class="btn btn-main btn-sm" data-apply="liberar">Liberar</button>
      <button type="button" class="btn btn-bad btn-sm" data-apply="bloquear">Bloquear</button>
      <button type="button" class="btn btn-ghost btn-sm" data-apply="limpar">Limpar</button></div>`;
  if (!rows.length) { grid.innerHTML = `<p class="empty">Nenhum barbeiro ativo.</p>`; return; }

  const bar = grid.querySelector(".slot-bar");
  const picked = () => [...grid.querySelectorAll('.slot-chip[aria-pressed="true"]')];
  const refreshBar = () => { const k = picked().length; bar.hidden = !k; bar.querySelector(".slot-count").textContent = k; };
  grid.querySelectorAll(".slot-chip[data-st]").forEach(btn => btn.onclick = () => {
    if (btn.dataset.st === "ocupado") {
      const s = rows.find(r => r.barber_id === +btn.dataset.b).slots.find(x => x.time === btn.dataset.t);
      return toast(`${btn.dataset.t} · ${s.cliente} · ${s.servico}. Para liberar, desmarque ou mova o cliente na Agenda.`);
    }
    btn.setAttribute("aria-pressed", btn.getAttribute("aria-pressed") === "true" ? "false" : "true");
    refreshBar();
  });
  const run = async (fn, ok) => {
    grid.querySelectorAll("button").forEach(b => b.disabled = true);
    try { toast(ok(await fn())); } catch (e) { toast(e.message); }
    reload();
  };
  bar.querySelectorAll("[data-apply]").forEach(btn => btn.onclick = () => {
    const act = btn.dataset.apply;
    if (act === "limpar") { picked().forEach(b => b.setAttribute("aria-pressed", "false")); return refreshBar(); }
    const byBarber = {};
    picked().forEach(b => (byBarber[b.dataset.b] ??= []).push(b.dataset.t));
    run(async () => {
      let feitos = 0, cli = 0;
      for (const [b, times] of Object.entries(byBarber)) {
        const r = await rpc("staff_set_slots", { p_barber: +b, p_day: day, p_times: times, p_block: act === "bloquear" });
        feitos += r.feitos; cli += r.com_cliente;
      }
      return { feitos, cli };
    }, r => `${r.feitos} horário(s) ${act === "bloquear" ? "bloqueado(s)" : "liberado(s) para agendar"}${r.cli ? ` · ${r.cli} com cliente ficaram como estavam` : ""}`);
  });
  grid.querySelectorAll("[data-day-open],[data-day-close]").forEach(btn => btn.onclick = () => {
    const open = !!btn.dataset.dayOpen, b = +(btn.dataset.dayOpen || btn.dataset.dayClose);
    run(() => rpc("staff_set_days", { p_barber: b, p_days: [day], p_open: open }),
      r => open ? `${dateLabel(day)} liberado: expediente normal, sem bloqueios`
        : `${dateLabel(day)} bloqueado${r.clientes ? ` · ${r.clientes} cliente(s) já marcado(s) continuam` : ""}`);
  });
}

async function loadDaySlots() {
  if (!$("ds-day").options.length) $("ds-day").innerHTML = dayOptions();
  const cur = $("ds-barber").value;
  $("ds-barber").innerHTML = barberOptions(true);
  $("ds-barber").value = cur;
  await renderDayGrid($("ds-grid"), $("ds-sum"), $("ds-day").value, $("ds-barber").value ? +$("ds-barber").value : null, loadDaySlots);
}
$("ds-day").onchange = $("ds-barber").onchange = () => loadDaySlots().catch(e => toast(e.message));

// Mesma grade no Meu painel / Equipe, para o barbeiro escolhido
async function loadEqSlots() {
  if (!$("eqs-day").options.length) $("eqs-day").innerHTML = dayOptions();
  await renderDayGrid($("eqs-grid"), $("eqs-sum"), $("eqs-day").value, eqBarber, () => { loadEqSlots(); loadEqDays(); });
}
$("eqs-day").onchange = () => loadEqSlots().catch(e => toast(e.message));

// Vários dias de uma vez: toca nos dias e fecha (folga) ou libera (volta ao expediente normal)
const DAY_ST = { aberto: "aberto", parcial: "tem bloqueio", folga: "fechado", sem_expediente: "não trabalha" };
async function loadEqDays() {
  const days = await rpc("staff_days_status", { p_barber: eqBarber });
  $("eqd-grid").innerHTML = days.map(d => {
    const dt = new Date(d.date + "T12:00");
    return `<button type="button" class="day-chip ${d.status}" data-d="${d.date}" aria-pressed="false">
      <small>${DIAS[dt.getDay()]}</small><b>${dt.getDate()}/${dt.getMonth() + 1}</b><i>${DAY_ST[d.status]}${d.clientes ? ` · ${d.clientes} cli.` : ""}</i></button>`;
  }).join("");
  $("eqd-grid").querySelectorAll(".day-chip").forEach(b => b.onclick = () => {
    b.setAttribute("aria-pressed", b.getAttribute("aria-pressed") === "true" ? "false" : "true"); eqdRefresh();
  });
  eqdRefresh();
}
const eqdPicked = () => [...$("eqd-grid").querySelectorAll('.day-chip[aria-pressed="true"]')].map(b => b.dataset.d);
function eqdRefresh() { const k = eqdPicked().length; $("eqd-bar").hidden = !k; $("eqd-count").textContent = k; }
document.querySelectorAll("[data-eqd]").forEach(btn => btn.onclick = async () => {
  const act = btn.dataset.eqd, days = eqdPicked();
  if (act === "limpar" || !days.length) {
    $("eqd-grid").querySelectorAll(".day-chip").forEach(b => b.setAttribute("aria-pressed", "false")); return eqdRefresh();
  }
  $("eqd-bar").querySelectorAll("button").forEach(b => b.disabled = true);
  try {
    const r = await rpc("staff_set_days", { p_barber: eqBarber, p_days: days, p_open: act === "liberar" });
    toast(act === "liberar" ? `${days.length} dia(s) liberado(s) para agendar`
      : `${days.length} dia(s) fechado(s)${r.clientes ? ` · ${r.clientes} cliente(s) já marcado(s) continuam: avise ou remaneje` : ""}`);
  } catch (e) { toast(e.message); }
  $("eqd-bar").querySelectorAll("button").forEach(b => b.disabled = false);
  loadEqDays().catch(e => toast(e.message)); loadEqSlots().catch(e => toast(e.message));
});
function barberCard(b) {
  const byDay = d => (b.hours || []).filter(h => h.weekday === d).map(h => `${h.start}-${h.end}`).join(", ");
  return `<div class="card stack" data-id="${b.id ?? ""}">
    <div class="grid2">
      <label>Nome<input name="name" value="${esc(b.name ?? "")}" maxlength="60"></label>
      <label>Cargo<input name="title" value="${esc(b.title ?? "Barbeiro")}" maxlength="40"></label>
      <label>Especialidade<input name="bio" value="${esc(b.bio ?? "")}" maxlength="200"></label>
      <input type="hidden" name="commission" value="${b.commission_percent ?? 60}">
      <label>Agenda aberta até (vazio = sempre os próximos dias)<input name="open_until" type="date" value="${b.open_until ?? ""}"></label>
      <p class="muted small u-as-end">${(b.accounts || []).length ? `Acesso ao painel: ${b.accounts.map(esc).join(", ")}` : "Nenhuma conta ligada. Em Clientes, mude o acesso da conta do barbeiro para \"Barbeiro\"."}</p>
      <label>Foto (ex.: img/barbeiros/nome.jpg)<input name="photo" value="${esc(b.photo ?? "")}"></label>
      <label>WhatsApp do barbeiro (o cliente que agendar com ele fala direto · vazio = WhatsApp da barbearia)<input name="whatsapp" type="tel" inputmode="tel" maxlength="20" placeholder="(19) 99999-9999" value="${b.whatsapp ? esc(fmtPhone(b.whatsapp)) : ""}"></label>
    </div>
    <div class="eyebrow u-mt-6">Expediente · use vírgula para pausas, ex.: 09:00-12:00, 13:00-19:00 · vazio = folga</div>
    <div class="grid2">${WEEK.map((w, d) => `<label>${w}<input name="d${d}" value="${byDay(d)}" placeholder="folga"></label>`).join("")}</div>
    <div class="spread"><label class="check"><input type="checkbox" name="active" ${b.active ?? true ? "checked" : ""}> Aparece no site e na agenda</label>
      <button class="btn btn-main btn-sm" data-save>Salvar</button></div>
  </div>`;
}
function bindBarbers() {
  $("barbers").querySelectorAll("[data-save]").forEach(btn => btn.onclick = async () => {
    const card = btn.closest(".card"), v = n => card.querySelector(`[name=${n}]`);
    const hours = [];
    try {
      for (let d = 0; d < 7; d++) {
        for (const part of v("d" + d).value.split(",").map(s => s.trim()).filter(Boolean)) {
          const m = part.match(/^(\d{1,2}):?(\d{2})?\s*-\s*(\d{1,2}):?(\d{2})?$/);
          if (!m) throw new Error(`Horário inválido em ${WEEK[d]}: "${part}"`);
          const p = (h, mi) => `${h.padStart(2, "0")}:${mi || "00"}`;
          const start = p(m[1], m[2]), end = p(m[3], m[4]);
          if (end <= start) throw new Error(`Em ${WEEK[d]}, o fim precisa ser depois do início.`);
          hours.push({ weekday: d, start, end });
        }
      }
      const p = { name: v("name").value, title: v("title").value, bio: v("bio").value, photo: v("photo").value, active: v("active").checked,
        whatsapp: v("whatsapp").value,
        commission_percent: +v("commission").value, open_until: v("open_until").value || null, hours };
      if (card.dataset.id) p.id = +card.dataset.id;
      await rpc("admin_save_barber", { p });
      toast("Barbeiro salvo"); loadBarbers();
    } catch (e) { toast(e.message); }
  });
}
$("barber-add").onclick = () => { $("barbers").insertAdjacentHTML("beforeend", barberCard({})); bindBarbers(); };

// ---------------------------------------------------------------- clientes
let cliTimer;
$("cli-q").oninput = () => { clearTimeout(cliTimer); cliTimer = setTimeout(loadClients, 300); };
const MESES = ["janeiro", "fevereiro", "março", "abril", "maio", "junho", "julho", "agosto", "setembro", "outubro", "novembro", "dezembro"];
async function loadBirthdays() {
  if (!$("bd-month").options.length) {
    $("bd-month").innerHTML = MESES.map((m, i) => `<option value="${i + 1}">${m}</option>`).join("");
    $("bd-month").value = new Date().getMonth() + 1;
    $("bd-month").onchange = loadBirthdays;
  }
  const [rows, cfg] = await Promise.all([rpc("admin_birthdays", { p_month: +$("bd-month").value }), rpc("admin_get_config")]);
  const gift = cfg.birthday_gift || "um presente no seu próximo corte";
  $("bd-list").innerHTML = rows.length ? rows.map(r => {
    const msg = `Parabéns, ${r.name.split(" ")[0]}! 🎉 A Magrão Barber Shop deseja um feliz aniversário. Seu presente: ${gift}.`;
    return `<div class="spread small"><span>${r.hoje ? "🎉 <b>Hoje</b> · " : `dia ${r.dia} · `}${esc(r.name)} · ${r.idade} anos
      ${r.parabens_enviado ? `<span class="badge confirmado">parabéns enviado</span>` : ""}</span>
      <a class="btn btn-ghost btn-sm" target="_blank" rel="noopener noreferrer" href="https://wa.me/${esc(r.phone)}?text=${encodeURIComponent(msg)}">Mandar parabéns</a></div>`;
  }).join("") : `<p class="muted small">Ninguém faz aniversário nesse mês (ou ainda não cadastrou a data).</p>`;
}

async function loadClients() {
  loadBirthdays().catch(e => toast(e.message));
  const rows = await rpc("admin_clients", { p_q: $("cli-q").value.trim() });
  const bOpts = sel => BARBERS.map(b => `<option value="${b.id}" ${sel === b.id ? "selected" : ""}>${esc(b.name)}</option>`).join("");
  $("cli-body").innerHTML = rows.map(u => `<tr data-id="${u.id}">
    <td>${esc(u.name)}<div class="muted small">${u.has_login ? esc(u.email) : "cliente de balcão (sem login)"}</div>${u.has_login ? `<div class="muted small">${contaInfo(u)}</div>` : ""}${contaBtns(u)}</td>
    <td><a href="https://wa.me/${esc(u.phone)}" target="_blank" rel="noopener noreferrer">${fmtPhone(u.phone)}</a></td>
    <td>${u.cortes}</td><td>${u.faltas ? `<span class="badge faltou">${u.faltas}</span>` : 0}</td>
    <td>${u.cortes_pacote ? `<span class="badge confirmado">${u.cortes_pacote} corte(s)</span>` : "—"}${u.pref_pay ? `<div class="muted small">paga no ${PAY[u.pref_pay]}</div>` : ""}</td>
    <td><div class="row u-fwrap-nowrap">
      <select class="u-w-auto" name="role" ${u.has_login ? "" : "disabled"}><option value="client">Cliente</option><option value="barber">Barbeiro</option><option value="admin">Administrador</option></select>
      <select class="u-w-auto" name="barber" ${u.role === "barber" ? "" : "hidden"}>${bOpts(u.barber_id)}</select></div></td>
    <td class="row u-fwrap-nowrap">${u.has_login ? `<button class="btn btn-ghost btn-sm" data-role>Salvar acesso</button><button class="btn btn-ghost btn-sm" data-pass>Senha provisória</button>` : ""}${u.role === "client" && u.phone !== "5500000000000" ? `<button class="btn btn-ghost btn-sm" data-del>Remover</button>` : ""}</td>
  </tr>`).join("") || `<tr><td colspan="7" class="muted">Nenhum cliente encontrado.</td></tr>`;
  bindCriarConta($("cli-body"), rows);
  $("cli-body").querySelectorAll("tr[data-id]").forEach(tr => {
    const u = rows.find(r => r.id === tr.dataset.id);
    const role = tr.querySelector("[name=role]"), barber = tr.querySelector("[name=barber]");
    role.value = u.role;
    role.onchange = () => barber.hidden = role.value !== "barber";
    const del = tr.querySelector("[data-del]");
    if (del) del.onclick = async () => {
      if (!confirm(`Remover ${u.name}? O cadastro${u.has_login ? " e o login" : ""} são apagados e o WhatsApp fica livre para ele se cadastrar de novo.
Os cortes já feitos continuam no Caixa e nas Comissões.`)) return;
      del.disabled = true;
      try { await callFn("admin-remover-cliente", { user_id: u.id }); toast(`${u.name} removido`); loadClients(); }
      catch (e) { toast(e.message); del.disabled = false; }
    };
    if (!u.has_login) return;
    tr.querySelector("[data-role]").onclick = async () => {
      if (role.value === "admin" && !confirm(`Dar acesso TOTAL de administrador para ${u.name}?`)) return;
      try { await rpc("admin_set_role", { p_user: u.id, p_role: role.value, p_barber: role.value === "barber" ? +barber.value : null }); toast("Acesso atualizado"); }
      catch (e) { toast(e.message); }
    };
    tr.querySelector("[data-pass]").onclick = async () => {
      if (!confirm(`Gerar uma senha provisória para ${u.name}? A senha atual deixa de funcionar.`)) return;
      try {
        const r = await callFn("admin-senha", { user_id: u.id });
        prompt("Senha provisória. Envie para o cliente e peça para ele trocar em \"Minha conta\":", r.temp_password);
      } catch (e) { toast(e.message); }
    };
  });
}

// ---------------------------------------------------------------- mensagens
async function loadMsgs() {
  const rows = await rpc("admin_messages");
  const anySent = rows.some(m => m.status === "enviado");
  $("wa-mode").textContent = anySent ? "Mensagens enviadas pelo WhatsApp oficial." :
    "O WhatsApp oficial não está ligado: as mensagens não saem sozinhas. Toque em \"Enviar no WhatsApp\" para mandar com o texto pronto.";
  const KIND = { confirmacao: "Confirmação", lembrete: "Lembrete", lista_espera: "Lista de espera", cancelamento: "Cancelamento", remarcado: "Remarcado",
    confirmar_presenca: "Confirmar presença", aniversario: "Aniversário", novo_agendamento: "Novo horário (para o barbeiro)" };
  const STATUS = { pendente: "não enviada", registrado: "não enviada", enviado_manual: "enviada à mão" };
  $("msgs").innerHTML = rows.length ? rows.map(m => `<div class="li"><div class="grow">
    <div class="row u-gap-8"><b>${KIND[m.kind] || esc(m.kind)}</b><span class="badge ${m.status === "erro" ? "erro" : ""}">${esc(STATUS[m.status] || m.status)}</span>
    <span class="muted small">${fmtPhone(m.to_phone)} · ${new Date(m.created_at).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short" })}</span></div>
    <div class="small u-mt-4">${esc(m.body)}</div>${m.error ? `<div class="err small">${esc(m.error)}</div>` : ""}</div>
    ${["pendente", "registrado", "erro"].includes(m.status) ? `<a class="btn btn-main btn-sm" data-msg="${m.id}" target="_blank" rel="noopener noreferrer"
      href="https://wa.me/${esc(m.to_phone)}?text=${encodeURIComponent(m.body)}">Enviar no WhatsApp</a>` : ""}</div>`).join("")
    : `<p class="empty">Nenhuma mensagem ainda.</p>`;
  $("msgs").querySelectorAll("[data-msg]").forEach(a => a.addEventListener("click", async () => {
    try { await rpc("admin_message_sent", { p_id: +a.dataset.msg }); loadMsgs(); } catch (e) { toast(e.message); }
  }));
}

// ---------------------------------------------------------------- configurações
async function loadConfig() {
  const [cfg, pub] = await Promise.all([rpc("admin_get_config"), rpc("public_info")]);
  for (const [k, v] of Object.entries(cfg)) { const el = $("cfg-" + k); if (el) el.value = v; }
  $("cfg-modes").textContent = `Pagamento online: ${cfg.online_pay === "1" ? "ligado (InfinitePay)" : "desligado"}`;
}
$("cfg-save").onclick = async () => {
  const p = {};
  document.querySelectorAll("[id^=cfg-]").forEach(el => {
    if (el.matches("input, select")) p[el.id.slice(4)] = el.id === "cfg-birthday_gift" ? el.value : +el.value;
  });
  try { await rpc("admin_set_config", { p }); toast("Configurações salvas"); } catch (e) { toast(e.message); }
};

boot().catch(e => toast(e.message));
