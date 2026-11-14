// Tela de agendamento: serviço → barbeiro → dia/horário → conta → Pix
document.getElementById("topo").innerHTML = TOPO;
const $ = id => document.getElementById(id);
const params = new URLSearchParams(location.search);
const S = { step: 1, service: null, barber: null, assigned: null, locked: null, date: null, time: null, booking: null, user: null, packages: [], pay: null,
  kids: [], kid: null, picked: [], extras: [] };
let PUB, pollTimer, clockTimer;

const TITLES = {
  1: ["Escolha o serviço", ""],
  2: ["Escolha o barbeiro", "Ou deixe que a gente escolha quem estiver livre."],
  3: ["Escolha o dia e o horário", ""],
  4: ["Entre na sua conta", "Precisamos do seu WhatsApp para confirmar o horário e mandar o lembrete."],
  5: ["Confirme seu horário", ""],
  6: ["Tudo certo", ""],
};

function go(step) {
  S.step = step;
  document.querySelectorAll("[data-step]").forEach(s => s.hidden = +s.dataset.step !== step);
  $("expired").hidden = true;
  const [t, sub] = TITLES[step];
  $("title").textContent = t;
  $("subtitle").textContent = sub;
  $("steps").querySelectorAll("span").forEach((s, i) => s.classList.toggle("on", i < Math.min(step, 5)));
  $("back").hidden = step === 1 || step === 6 || (step === 5 && !!S.booking);
  window.scrollTo({ top: 0, behavior: "smooth" });
  ({ 1: renderServices, 2: renderBarbers, 3: renderDays, 4: renderAuth, 5: renderReview })[step]?.();
}

$("back").onclick = () => {
  let prev = S.step - 1;
  if (prev === 4 && S.user) prev = 3;
  if (prev === 2 && (PUB.barbers.length < 2 || S.locked)) prev = 1;
  go(prev);
};

const priceLabel = s => (s.price_from ? "a partir de " : "") + brl(s.price_cents);

function avatar(b) {
  return b.photo
    ? `<span class="avatar"><img src="${esc(b.photo)}" alt=""></span>`
    : `<span class="avatar">${esc(b.name[0])}</span>`;
}

// Vários serviços no mesmo horário: o primeiro escolhido é o principal, os outros vão como extras.
// S.service vira o "combo": nome, tempo e preço somados (o resto da tela usa como se fosse um serviço só).
function setCombo() {
  const list = S.picked.map(id => PUB.services.find(s => s.id === id)).filter(Boolean);
  S.picked = list.map(s => s.id);
  S.extras = S.picked.slice(1);
  S.service = list.length ? {
    id: list[0].id, name: list.map(s => s.name).join(" + "), description: list[0].description,
    duration_min: list.reduce((t, s) => t + s.duration_min, 0), price_cents: list.reduce((t, s) => t + s.price_cents, 0),
    price_from: list.some(s => s.price_from), count: list.length,
  } : null;
}
const extrasArg = () => S.extras.length ? S.extras : null;

function renderServices() {
  const dep = PUB.settings.deposit_percent;
  $("services").innerHTML = `<p class="muted small u-mb-4">Pode escolher mais de um (ex.: corte + barba + alisamento).</p>` + PUB.services.map(s => {
    const n = S.picked.indexOf(s.id);
    return `<button class="opt" data-id="${s.id}" aria-pressed="${n >= 0}">
      <span class="pick-mark">${n >= 0 ? "✓" : ""}</span>
      <div class="grow"><h3>${esc(s.name)}</h3><div class="muted small">${esc(s.description)}</div></div>
      <div class="u-ta-right"><div class="price">${priceLabel(s)}</div>${dep ? `<div class="muted small">sinal ${brl(Math.round(s.price_cents * dep / 100))}</div>` : ""}</div>
    </button>`;
  }).join("");
  $("services").querySelectorAll(".opt").forEach(b => b.onclick = () => {
    const id = +b.dataset.id, i = S.picked.indexOf(id);
    if (i >= 0) S.picked.splice(i, 1);
    else if (S.picked.length >= 6) return toast("No máximo 6 serviços no mesmo horário.");
    else S.picked.push(id);
    setCombo(); S.time = null;
    renderServices();
  });
  const c = S.service;
  $("svc-bar").hidden = !c;
  if (c) {
    $("svc-sum").innerHTML = `<b>${esc(c.name)}</b><br><span class="muted small">${priceLabel(c)}</span>`;
    $("svc-go").textContent = c.count > 1 ? `Continuar com ${c.count} serviços` : "Continuar";
  }
}
$("svc-go").onclick = () => { if (S.service) go(PUB.barbers.length < 2 || S.locked ? 3 : 2); };

function renderBarbers() {
  const opts = [{ id: 0, name: "Qualquer barbeiro", bio: "Mostra todos os horários livres", photo: "" }, ...PUB.barbers];
  $("barbers").innerHTML = opts.map(b => `
    <button class="opt" data-id="${b.id}" aria-pressed="${(S.barber?.id ?? 0) === b.id}">
      ${avatar(b)}
      <div class="grow"><h3>${esc(b.name)}</h3><div class="muted small">${esc(b.bio || b.title || "")}</div></div>
    </button>`).join("");
  $("barbers").querySelectorAll(".opt").forEach(b => b.onclick = () => {
    S.barber = PUB.barbers.find(x => x.id === +b.dataset.id) || null;
    S.time = null;
    go(3);
  });
}

// Botões para trocar de barbeiro direto na tela de horários
function renderBarberChips() {
  const chips = $("barber-chips");
  if (PUB.barbers.length < 2) { chips.hidden = true; $("lock-note").hidden = true; return; }
  chips.hidden = false;
  const opts = [{ id: 0, name: "Todos" }, ...PUB.barbers];
  const current = S.barber?.id ?? 0;
  chips.innerHTML = opts.map(b => {
    const blocked = S.locked && b.id !== S.locked.id;
    return `<button type="button" role="tab" data-id="${b.id}" aria-selected="${b.id === current}" ${blocked ? "disabled" : ""}>${esc(b.name)}</button>`;
  }).join("");
  chips.querySelectorAll("button:not([disabled])").forEach(btn => btn.onclick = () => {
    const id = +btn.dataset.id;
    if (id === current) return;
    S.barber = PUB.barbers.find(x => x.id === id) || null;
    S.time = null;
    renderDays();
  });
  $("lock-note").hidden = !S.locked;
  if (S.locked) {
    $("lock-note").innerHTML = `Você já tem um horário marcado com <b>${esc(S.locked.name)}</b>, então os próximos ficam com ele. `
      + `Para marcar com outro barbeiro, cancele o atual em <a href="/conta.html">Minha conta</a>.`;
  }
}

async function renderDays() {
  $("subtitle").textContent = S.locked
    ? `${S.service.name} · com ${S.locked.name}, que já tem um horário seu marcado`
    : `${S.service.name} · ${S.barber ? S.barber.name : "qualquer barbeiro"}`;
  renderBarberChips();
  $("days").innerHTML = `<span class="spinner"></span>`;
  $("times").innerHTML = "";
  $("waitbox").hidden = true;
  const days = await rpc("available_days", { p_service: S.service.id, p_barber: S.barber?.id ?? null, p_extras: extrasArg() });
  const usable = d => d.open && d.released !== false;
  if (!S.date || !days.some(d => d.date === S.date && usable(d))) S.date = (days.find(d => d.free) || days.find(usable) || days[0]).date;
  $("days").innerHTML = days.map(d => {
    const dt = new Date(d.date + "T12:00");
    const soon = d.open && d.released === false;
    const cls = !d.open || soon ? "closed" : d.free ? "" : "full";
    const info = !d.open ? "fechado" : soon ? "em breve" : d.free ? `${d.free} vagas` : "lotado";
    return `<button class="day ${cls}" data-d="${d.date}" aria-pressed="${d.date === S.date}" ${d.open && !soon ? "" : "disabled"}>
      <small>${DIAS[dt.getDay()]}</small><b>${dt.getDate()}</b><i>${info}</i></button>`;
  }).join("");
  $("days").querySelectorAll(".day").forEach(b => b.onclick = () => {
    S.date = b.dataset.d; S.time = null;
    $("days").querySelectorAll(".day").forEach(x => x.setAttribute("aria-pressed", x === b));
    renderTimes();
  });
  $("days").querySelector("[aria-pressed=true]")?.scrollIntoView({ inline: "center", block: "nearest" });
  renderTimes();
}

async function renderTimes() {
  $("times").innerHTML = `<span class="spinner"></span>`;
  // Todos os horários do dia, barbeiro por barbeiro, com livre / ocupado
  const grid = await rpc("day_grid", { p_service: S.service.id, p_day: S.date, p_barber: S.barber?.id ?? null, p_extras: extrasArg() });
  const label = { livre: "", ocupado: "ocupado", encerrado: "encerrado", fechado: "em breve" };
  const anyFree = grid.some(g => g.slots.some(x => x.status === "livre"));
  $("times").innerHTML = grid.length ? grid.map(g => `
    <div class="barber-day">
      <div class="barber-day-head">${avatar({ name: g.barber_name, photo: g.photo })}<b>${esc(g.barber_name)}</b>
        <span class="muted small">${g.slots.filter(x => x.status === "livre").length} livre(s)</span></div>
      ${g.slots.length ? `<div class="times">${g.slots.map(x => `
        <button class="time ${x.status === "livre" ? "" : "busy"}" data-t="${x.time}" data-b="${g.barber_id}"
          ${x.status === "livre" ? "" : "disabled"} aria-label="${x.time} ${x.status}">
          ${x.time}${label[x.status] ? `<small>${label[x.status]}</small>` : ""}</button>`).join("")}</div>`
        : `<p class="muted small">Não trabalha nesse dia.</p>`}
    </div>`).join("") : `<p class="empty">Nenhum barbeiro nesse dia.</p>`;
  if (!anyFree) $("times").insertAdjacentHTML("afterbegin", `<p class="empty u-mb-12">Todos os horários desse dia estão ocupados.</p>`);
  $("waitbox").hidden = false;
  $("times").querySelectorAll(".time:not([disabled])").forEach(b => b.onclick = () => {
    S.time = b.dataset.t;
    S.assigned = PUB.barbers.find(x => x.id === +b.dataset.b) || null;
    go(S.user ? 5 : 4);
  });
}

$("join-wait").onclick = () => {
  if (!S.user) { S.afterAuth = "wait"; return go(4); }
  joinWait();
};
async function joinWait() {
  try {
    const r = await rpc("join_waitlist", { p_service: S.service.id, p_date: S.date, p_barber: S.barber?.id ?? null });
    toast(`Pronto! Você é o ${r.position}º da lista de espera desse dia.`);
  } catch (e) { toast(e.message); }
  if (S.step !== 3) go(3);
}

function renderAuth() {
  authForm($("auth"), async user => {
    S.user = user;
    await loadLocked();
    if (S.afterAuth === "wait") { S.afterAuth = null; return joinWait(); }
    if (S.locked && S.assigned?.id !== S.locked.id) {
      toast(`Você já tem horário com ${S.locked.name}. Escolha um horário com ele.`);
      S.time = null;
      return go(3);
    }
    go(5);
  });
}

function renderReview() {
  if (S.booking) return;
  const s = S.service, set = PUB.settings;
  const dep = Math.round(s.price_cents * set.deposit_percent / 100);
  $("summary").innerHTML = `
    <dt>${s.count > 1 ? "Serviços" : "Serviço"}</dt><dd>${esc(s.name)}</dd>
    <dt>Barbeiro</dt><dd>${S.assigned ? esc(S.assigned.name) : "Quem estiver livre"}</dd>
    <dt>Quando</dt><dd>${dateLabel(S.date)} às ${S.time}</dd>
    <dt>Cliente</dt><dd>${esc(S.user.name)}</dd>
    <dt class="total">Valor do serviço</dt><dd class="total">${priceLabel(s)}</dd>
    ${dep ? `<dt>Sinal agora no Pix (${set.deposit_percent}%)</dt><dd>${brl(dep)}</dd>
    <dt>Restante na barbearia</dt><dd>${s.price_from ? "a combinar" : brl(s.price_cents - dep)}</dd>` : ""}`;
  $("policy").textContent = dep
    ? `Cancelando com pelo menos ${set.cancel_hours}h de antecedência, o sinal é devolvido. Depois disso, ou se faltar, o sinal não é devolvido.`
    : "Se não puder vir, cancele pelo site para liberar o horário.";
  renderPayOpts(dep);
  renderKidBox();
  $("review").hidden = false; $("pixbox").hidden = true; $("review-err").textContent = "";
}

// "Meu filho também vai cortar": escolhe o filho e o serviço; o horário vem depois de confirmar o do pai
function renderKidBox() {
  $("kidbox").hidden = !S.user;
  if (!S.user) return;
  const cur = $("kid-sel").value;
  $("kid-sel").innerHTML = S.kids.map(k => `<option value="${k.id}">${esc(k.name)}</option>`).join("") + `<option value="new">+ Outro filho</option>`;
  if ([...$("kid-sel").options].some(o => o.value === cur)) $("kid-sel").value = cur;
  if (!$("kid-svc").options.length) {
    $("kid-svc").innerHTML = PUB.services.map(s => `<option value="${s.id}">${esc(s.name)} · ${priceLabel(s)}</option>`).join("");
    $("kid-svc").value = S.service.id;
  }
  const on = $("kid-on").checked;
  $("kid-opts").hidden = $("kid-note").hidden = !on;
  $("kid-new-wrap").hidden = !on || $("kid-sel").value !== "new";
}
$("kid-on").onchange = $("kid-sel").onchange = renderKidBox;

function readKid() {
  if (!S.user || !$("kid-on").checked) return null;
  const isNew = $("kid-sel").value === "new";
  const name = isNew ? $("kid-new").value.trim() : S.kids.find(k => k.id === +$("kid-sel").value)?.name;
  if (!name || name.length < 2) throw new Error("Digite o nome do filho.");
  return { id: isNew ? null : +$("kid-sel").value, name, service: +$("kid-svc").value };
}

// Depois de confirmar o horário do pai: horários livres mais perto para o filho
async function renderKidStep() {
  const k = S.kid;
  $("kid-done").hidden = !k;
  if (!k) return;
  $("kid-title").textContent = `Horário de ${k.name}`;
  $("kid-times").innerHTML = `<span class="spinner"></span>`;
  try {
    if (!k.id) {
      S.kids = await rpc("save_my_child", { p_id: null, p_name: k.name });
      const saved = S.kids.filter(x => x.name.toLowerCase() === k.name.toLowerCase()).pop() ?? S.kids[S.kids.length - 1];
      k.id = saved.id; k.name = saved.name;
      $("kid-title").textContent = `Horário de ${k.name}`;
    }
    const sug = await rpc("child_suggestions", { p_booking: S.booking.id, p_service: k.service });
    const dadStart = S.booking.start_at.slice(11, 16);
    const rel = x => x.barber_id === S.booking.barber_id ? (x.time < dadStart ? "logo antes do seu" : "logo depois do seu")
      : x.time === dadStart ? "junto com você" : x.time < dadStart ? "antes do seu" : "depois do seu";
    $("kid-sub").textContent = sug.length ? "Escolha um horário perto do seu:" : "";
    $("kid-times").innerHTML = sug.map((x, i) => `
      <button class="opt" data-i="${i}"><div class="grow"><h3>${x.time} com ${esc(x.barber_name)}</h3>
        <div class="muted small">${rel(x)}</div></div></button>`).join("")
      || `<p class="muted small">Não sobrou horário livre nesse dia para ele. <a href="/agendar.html">Marque outro dia</a>.</p>`;
    $("kid-times").querySelectorAll("[data-i]").forEach(btn => btn.onclick = async () => {
      const x = sug[+btn.dataset.i];
      btn.disabled = true;
      try {
        const b = await rpc("create_booking", { p_service: k.service, p_date: x.date, p_time: x.time, p_barber: x.barber_id, p_pay: "local", p_child: k.id });
        $("kid-sub").textContent = "";
        $("kid-times").innerHTML = `<p><b>✓ ${esc(b.service_name)}</b> para ${esc(k.name)} com <b>${esc(b.barber_name)}</b> · ${esc(b.quando)}</p>`;
        const aviso = decodeURIComponent($("wa-aviso").href.split("text=")[1] || "");
        $("wa-aviso").href = `https://wa.me/${CFG.WHATSAPP}?text=${encodeURIComponent(`${aviso}\nFilho (${k.name}): ${b.service_name} com ${b.barber_name}, ${b.quando}`)}`;
      } catch (e) { toast(e.message); btn.disabled = false; renderKidStep(); }
    });
  } catch (e) { $("kid-times").innerHTML = `<p class="err small">${esc(e.message)}</p>`; }
}

// Formas de pagamento: pacote com saldo, online (crédito até 12x ou Pix) ou na barbearia
function renderPayOpts(dep) {
  const s = S.service;
  // Pacote vale só para o serviço dele sozinho (com serviços a mais, paga na barbearia)
  const pkg = !S.extras.length && S.packages.find(p => p.status === "ativo" && p.service_id === s.id && p.left > 0 && p.valid_until >= S.date);
  const opts = [];
  if (pkg) opts.push(["pacote", `Usar meu pacote`, `${esc(pkg.name)} · ${pkg.left} de ${pkg.qty} restantes`]);
  if (!dep && PUB.settings.online_pay === 1 && !s.price_from) opts.push(["online", "Pagar agora pelo site", `Cartão de crédito em até 12x ou Pix · ${brl(s.price_cents)}`]);
  opts.push(["local", "Pagar na barbearia", "Dinheiro, cartão de crédito, débito ou Pix"]);
  if (!opts.some(o => o[0] === S.pay)) S.pay = opts[0][0];
  $("pay-opts").innerHTML = opts.map(([k, t, sub]) => `
    <button class="opt" data-pay="${k}" aria-pressed="${S.pay === k}"><div class="grow"><h3>${t}</h3><div class="muted small">${sub}</div></div></button>`).join("");
  $("pay-opts").querySelectorAll("[data-pay]").forEach(b => b.onclick = () => { S.pay = b.dataset.pay; renderPayOpts(dep); });
  $("paybox").hidden = !!dep;
  const offer = !pkg && (PUB.packages || []).find(k => k.service_id === s.id);
  $("pkg-tip").hidden = !offer;
  if (offer) $("pkg-tip").innerHTML = `Vem sempre? <b>${esc(offer.name)}</b>: ${offer.qty} por ${brl(offer.price_cents)} (${brl(offer.unit_cents)} cada). Compre em <a href="/conta.html#pacotes">Minha conta</a>.`;
  const who = `${S.assigned ? S.assigned.name : "o barbeiro"} · ${dateLabel(S.date)} às ${S.time}`;
  $("pay-btn").textContent = dep ? "Pagar sinal no Pix" : S.pay === "online" ? `Confirmar e pagar · ${who}` : `Confirmar com ${who}`;
}

$("pay-btn").onclick = async () => {
  $("pay-btn").disabled = true;
  try {
    S.kid = readKid();
    const pay = $("paybox").hidden ? "local" : S.pay;
    let b = await rpc("create_booking", { p_service: S.service.id, p_date: S.date, p_time: S.time, p_barber: S.assigned?.id ?? S.barber?.id ?? null, p_pay: pay, p_extras: extrasArg() });
    if (b.status === "pendente") b = await callFn("criar-pix", { booking_id: b.id });
    S.booking = b;
    if (pay === "online" && b.status === "confirmado") {
      try { location.href = (await callFn("pagar-online", { booking_id: b.id })).url; return; }
      catch (e) { toast(`Horário marcado, mas o pagamento não abriu (${e.message}). Pague em "Minha conta" ou na barbearia.`); }
    }
    b.status === "pendente" ? showPix() : handleStatus(b);
  } catch (e) {
    $("review-err").textContent = e.message;
    if (e.status === 409) setTimeout(() => go(3), 1800);
  } finally { $("pay-btn").disabled = false; }
};

function showPix() {
  const b = S.booking;
  go(5);
  $("review").hidden = true; $("pixbox").hidden = false; $("back").hidden = true;
  $("subtitle").textContent = `${b.service_name} com ${b.barber_name} · ${b.quando}`;
  $("pix-amount").textContent = brl(b.deposit_cents);
  $("pix-code").textContent = b.pix_code || "";
  $("pix-qr").hidden = !b.pix_qr_base64;
  if (b.pix_qr_base64) {  // blob: em vez de data: (a CSP não libera data:)
    const bin = atob(b.pix_qr_base64), bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    if ($("pix-qr").src.startsWith("blob:")) URL.revokeObjectURL($("pix-qr").src);
    $("pix-qr").src = URL.createObjectURL(new Blob([bytes], { type: "image/png" }));
  }
  $("fake-pay").hidden = PUB.payment_provider !== "teste";
  const until = Date.now() + b.hold_seconds_left * 1000;
  clearInterval(clockTimer);
  const tickClock = () => {
    const s = Math.max(0, Math.round((until - Date.now()) / 1000));
    $("timer").textContent = `${String(Math.floor(s / 60)).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}`;
  };
  tickClock(); clockTimer = setInterval(tickClock, 1000);
  clearInterval(pollTimer);
  pollTimer = setInterval(poll, 5000);
}

async function poll() {
  try { handleStatus(await callFn("pix-status", { booking_id: S.booking.id })); } catch { /* tenta de novo */ }
}

function handleStatus(b) {
  S.booking = b;
  if (b.status === "confirmado") {
    clearInterval(pollTimer); clearInterval(clockTimer);
    const payInfo = b.pay_method === "pacote" ? `Pago com o pacote ${esc(b.package_name)}`
      : b.paid_online ? "Pago pelo site" : `A pagar na barbearia: ${b.price_from ? "a partir de " : ""}${brl(b.remaining_cents)}`;
    $("done-text").innerHTML = `<b>${esc(b.service_name)}</b> com <b>${esc(b.barber_name)}</b><br>${esc(b.quando)}<br><span class="muted">${payInfo}</span>`
      + (PUB.settings.confirm_required === 1
        ? `<br><br><b>Importante:</b> umas ${Math.round(PUB.settings.confirm_ask_minutes / 60)}h antes você recebe um pedido para confirmar a presença. Se não confirmar até ${PUB.settings.confirm_deadline_minutes} minutos antes, o horário é liberado. Dá para confirmar também em "Minha conta".`
        : "");
    const aviso = `Olá! Acabei de agendar pelo site:\n${b.service_name} com ${b.barber_name}\n${b.quando}\nNome: ${S.user?.name ?? ""}`;
    $("wa-aviso").href = `https://wa.me/${CFG.WHATSAPP}?text=${encodeURIComponent(aviso)}`;
    // Conversa direto com o barbeiro do horário (sem número cadastrado, vai para o WhatsApp da barbearia)
    $("wa-barber").textContent = `Falar com ${b.barber_name} no WhatsApp`;
    $("wa-barber").href = waBarber(b);
    go(6);
    renderKidStep();
  } else if (b.status === "expirado" || b.status === "cancelado") {
    clearInterval(pollTimer); clearInterval(clockTimer);
    document.querySelectorAll("[data-step]").forEach(s => s.hidden = true);
    $("expired").hidden = false; $("back").hidden = true;
  }
}

$("copy").onclick = async () => {
  try { await navigator.clipboard.writeText(S.booking.pix_code); toast("Código Pix copiado!"); }
  catch { toast("Selecione o código e copie manualmente."); }
};
$("fake-pay").onclick = async () => {
  try { handleStatus(await callFn("pix-status", { booking_id: S.booking.id, simular: true })); } catch (e) { toast(e.message); }
};
$("restart").onclick = () => { location.href = "/agendar.html"; };

// Cliente com horário marcado só agenda de novo com o mesmo barbeiro
async function loadLocked() {
  S.locked = null;
  if (!S.user) return;
  rpc("my_packages").then(r => { S.packages = r.mine; if (S.step === 5 && !S.booking) renderReview(); }).catch(() => {});
  rpc("my_children").then(r => { S.kids = r; if (S.step === 5 && !S.booking) renderKidBox(); }).catch(() => {});
  try {
    const l = await rpc("my_locked_barber");
    if (l) { S.locked = PUB.barbers.find(b => b.id === l.id) || l; S.barber = S.locked; }
  } catch { /* segue sem trava; o banco confere de novo ao agendar */ }
}

(async function init() {
  [PUB, S.user] = await Promise.all([rpc("public_info"), currentUser()]);
  if (PUB.settings.deposit_percent) TITLES[5][0] = "Confirme e pague o sinal";
  const pagar = +params.get("pagar");
  if (pagar && S.user) {
    try {
      let b = await rpc("booking_status", { p_id: pagar });
      if (b.status === "pendente" && !b.pix_code) b = await callFn("criar-pix", { booking_id: pagar });
      S.booking = b;
      return b.status === "pendente" ? showPix() : handleStatus(b);
    } catch { /* segue o fluxo normal */ }
  }
  await loadLocked();
  S.picked = PUB.services.some(s => s.id === +params.get("servico")) ? [+params.get("servico")] : [];
  setCombo();
  S.barber = S.locked || PUB.barbers.find(b => b.id === +params.get("barbeiro")) || (PUB.barbers.length === 1 ? PUB.barbers[0] : null);
  const d = params.get("data");
  S.date = /^\d{4}-\d{2}-\d{2}$/.test(d || "") ? d : null;
  if (!S.service && S.barber && params.get("barbeiro")) TITLES[1][1] = `Agendando com ${S.barber.name}.`;
  go(S.service ? 3 : 1);
})().catch(e => { $("subtitle").textContent = e.message; });
