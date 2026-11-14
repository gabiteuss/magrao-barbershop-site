// Minha conta: horários, lista de espera, dados e segurança
document.getElementById("topo").innerHTML = TOPO;
const $ = id => document.getElementById(id);

function show(section) {
  for (const id of ["guest", "recovery", "logged"]) $(id).hidden = id !== section;
}

async function load() {
  const user = await currentUser();
  if (!user) { show("guest"); return authForm($("auth"), load); }
  show("logged");
  $("hello").textContent = user.name.split(" ")[0];
  $("me-info").textContent = `${fmtPhone(user.phone)} · ${user.email}`;
  $("staff-link").hidden = user.role === "client";
  $("profile-form").elements.namedItem("name").value = user.name;
  $("profile-form").elements.namedItem("phone").value = fmtPhone(user.phone);
  $("profile-form").elements.namedItem("birth_date").value = user.birth_date || "";
  $("profile-form").elements.namedItem("pref_pay").value = user.pref_pay || "";
  $("birth-ask").hidden = !!user.birth_date;
  await backFromPayment();

  const [bookings, wait, pub, pk, kids] = await Promise.all([rpc("my_bookings"), rpc("my_waitlist"), rpc("public_info"), rpc("my_packages"), rpc("my_children")]);
  renderKids(kids);
  const forKid = b => b.child_name ? ` · <b>para ${esc(b.child_name)}</b>` : "";
  const confirmOn = pub.settings.confirm_required === 1;
  const onlineOn = pk.online_pay;
  const payLine = b => b.pay_method === "pacote" ? ` · pago com o pacote ${esc(b.package_name)}`
    : b.paid_online ? ` · pago pelo site (${PAY[b.pay_method] || "online"})${b.receipt_url ? ` · <a href="${esc(b.receipt_url)}" target="_blank" rel="noopener noreferrer">comprovante</a>` : ""}`
    : b.deposit_cents ? ` · sinal ${brl(b.deposit_cents)} · restante ${brl(b.remaining_cents)}`
    : ` · ${b.price_from ? "a partir de " : ""}${brl(b.price_cents)} na barbearia`;
  const now = new Date();
  const upcoming = bookings.filter(b => ["pendente", "confirmado"].includes(b.status) && new Date(b.start_at) > now).reverse();
  const past = bookings.filter(b => !upcoming.includes(b));

  $("next").innerHTML = upcoming.length ? upcoming.map(b => `
    <div class="li">
      <div class="grow">
        <div class="row u-gap-8"><h3>${esc(b.quando)}</h3><span class="badge ${b.status}">${STATUS[b.status]}</span>
          ${b.moved_by_shop ? `<span class="badge">remarcado pela barbearia</span>` : ""}
          ${confirmOn && b.status === "confirmado" ? (b.attendance_confirmed ? `<span class="badge confirmado">presença confirmada</span>` : `<span class="badge pendente">confirme até ${esc(b.confirm_deadline)} do dia</span>`) : ""}</div>
        <div class="muted small">${esc(b.service_name)} com ${esc(b.barber_name)}${forKid(b)}${payLine(b)}
          ${b.moved_from ? `<br>Era ${esc(b.moved_from)}. Se não puder no novo horário, cancele por aqui${b.paid ? " e o sinal é devolvido" : ""}.` : ""}</div>
      </div>
      <div class="row">
        ${b.status === "pendente" ? `<a class="btn btn-main btn-sm" href="/agendar.html?pagar=${b.id}">Pagar Pix</a>` : ""}
        ${onlineOn && b.status === "confirmado" && !b.pay_method && !b.paid_online && !b.price_from ? `<button class="btn btn-main btn-sm" data-pay-booking="${b.id}">Pagar agora</button>` : ""}
        ${confirmOn && b.status === "confirmado" && !b.attendance_confirmed ? `<button class="btn btn-main btn-sm" data-confirm="${b.id}">Confirmar presença</button>` : ""}
        ${b.status === "confirmado" ? `<a class="btn btn-ghost btn-sm" target="_blank" rel="noopener noreferrer" href="${waBarber(b)}">Falar com ${esc(b.barber_name)}</a>` : ""}
        <button class="btn btn-bad btn-sm" data-cancel="${b.id}" data-refund="${b.refund_if_cancel}" data-status="${b.status}" data-hours="${b.cancel_hours}" data-paid="${b.paid}">Cancelar</button>
      </div>
    </div>`).join("") : `<p class="empty">Você não tem horários marcados.</p>`;

  $("past").innerHTML = past.length ? past.map(b => `
    <div class="li">
      <div class="grow">
        <div class="row u-gap-8"><h3>${esc(b.quando)}</h3><span class="badge ${b.status}">${STATUS[b.status] || esc(b.status)}</span>
          ${b.refund_status === "reembolsado" ? `<span class="badge">sinal devolvido</span>` : ""}
          ${b.refund_status === "pendente" ? `<span class="badge pendente">devolvendo sinal</span>` : ""}</div>
        <div class="muted small">${esc(b.service_name)} com ${esc(b.barber_name)}${forKid(b)}${b.items?.length ? ` · ${b.items.map(i => `${i.qty}x ${esc(i.name)}`).join(", ")}` : ""}
          ${b.pending_cents ? `<br><b class="err">Pendente: ${brl(b.pending_cents)}</b> · acerte na barbearia` : ""}</div>
      </div>
    </div>`).join("") : `<p class="empty">Nada por aqui ainda.</p>`;
  const debt = past.reduce((s, b) => s + (b.pending_cents || 0), 0);
  $("debt").hidden = !debt;
  if (debt) $("debt").innerHTML = `Você tem <b>${brl(debt)}</b> pendente na barbearia (ex.: corte de filho que ficou para pagar depois). Veja no histórico abaixo.`;

  // pacotes do cliente e pacotes à venda
  $("my-pkgs").innerHTML = pk.mine.map(p => `
    <div class="li"><div class="grow">
      <div class="row u-gap-8"><h3>${esc(p.name)}</h3>
        <span class="badge ${p.status === "ativo" ? "confirmado" : p.status === "pendente" ? "pendente" : "cancelado"}">${{ ativo: "ativo", pendente: "esperando pagamento", vencido: "vencido" }[p.status] || esc(p.status)}</span></div>
      <div class="muted small">${p.status === "pendente" ? `${p.qty}x ${esc(p.service_name)} · ${brl(p.price_cents)}`
        : `${p.left} de ${p.qty} ${esc(p.service_name)} restantes · ${p.status === "vencido" ? "venceu" : "vale até"} ${esc(p.valid_until_fmt)}`}</div></div>
      ${p.status === "pendente" && onlineOn && !p.plan_link ? `<button class="btn btn-main btn-sm" data-buy="${p.id}" data-pkg-order="1">Pagar</button>` : ""}
    </div>`).join("");
  $("buy-pkgs").innerHTML = pk.catalog.map(k => `
    <div class="li"><div class="grow">
      <div class="row u-gap-8"><h3>${esc(k.name)}</h3>${k.kind === "plano" ? `<span class="badge">mensal</span>` : ""}</div>
      <div class="muted small">${k.qty}x ${esc(k.service_name)} por ${brl(k.price_cents)} (${brl(k.unit_cents)} cada) · ${k.kind === "plano" ? "renova todo mês" : `vale ${k.valid_days} dias`}${k.description ? `<br>${esc(k.description)}` : ""}</div></div>
      ${onlineOn ? `<button class="btn btn-main btn-sm" data-buy-pkg="${k.id}">${k.kind === "plano" ? "Assinar" : "Comprar"}</button>`
        : `<a class="btn btn-ghost btn-sm" target="_blank" rel="noopener noreferrer" href="https://wa.me/${CFG.WHATSAPP}?text=${encodeURIComponent(`Olá! Quero o ${k.name} (${k.qty}x ${k.service_name} por ${brl(k.price_cents)}).`)}">Pedir no WhatsApp</a>`}
    </div>`).join("");
  $("pacotes").hidden = !pk.mine.length && !pk.catalog.length;
  if (location.hash === "#pacotes") $("pacotes").scrollIntoView();

  const openPay = async (btn, body) => {
    btn.disabled = true;
    try {
      const r = await callFn("pagar-online", body);
      if (r.external) toast("Assine na página da InfinitePay. A barbearia libera os cortes quando o pagamento aparecer.");
      location.href = r.url;
    } catch (e) { toast(e.message); btn.disabled = false; }
  };
  document.querySelectorAll("[data-pay-booking]").forEach(btn => btn.onclick = () => openPay(btn, { booking_id: +btn.dataset.payBooking }));
  document.querySelectorAll("[data-buy-pkg]").forEach(btn => btn.onclick = () => openPay(btn, { package_id: +btn.dataset.buyPkg }));
  document.querySelectorAll("[data-pkg-order]").forEach(btn => btn.onclick = () => {
    const p = pk.mine.find(x => x.id === +btn.dataset.buy);
    if (p?.checkout_url) location.href = p.checkout_url; else toast("Escolha o pacote de novo na lista abaixo.");
  });

  $("wait-wrap").hidden = !wait.length;
  $("wait").innerHTML = wait.map(w => `
    <div class="li"><div class="grow"><h3>${dateLabel(w.date)}</h3>
      <div class="muted small">${esc(w.service_name)} · ${esc(w.barber_name || "qualquer barbeiro")} · ${w.status === "avisado" ? "vaga avisada no WhatsApp" : "aguardando vaga"}</div></div>
      <button class="btn btn-ghost btn-sm" data-leave="${w.id}">Sair da lista</button></div>`).join("");

  document.querySelectorAll("[data-cancel]").forEach(btn => btn.onclick = async () => {
    const d = btn.dataset;
    const msg = d.status === "pendente" || d.paid !== "true" ? "Cancelar esse agendamento?"
      : d.refund === "true" ? "Cancelar? O sinal será devolvido no seu Pix."
      : `Faltam menos de ${d.hours}h para o horário: o sinal NÃO será devolvido. Cancelar mesmo assim?`;
    if (!confirm(msg)) return;
    try {
      const r = await rpc("cancel_booking", { p_id: +d.cancel });
      toast(r.refund ? "Cancelado. O sinal volta para o seu Pix em instantes." : "Agendamento cancelado.");
      load();
    } catch (e) { toast(e.message); }
  });
  document.querySelectorAll("[data-confirm]").forEach(btn => btn.onclick = async () => {
    try { await rpc("my_confirm_attendance", { p_id: +btn.dataset.confirm }); toast("Presença confirmada. Te esperamos!"); load(); }
    catch (e) { toast(e.message); }
  });
  document.querySelectorAll("[data-leave]").forEach(btn => btn.onclick = async () => {
    await rpc("leave_waitlist", { p_id: +btn.dataset.leave });
    load();
  });
}

// Filhos do cliente (para marcar o corte deles junto)
function renderKids(kids) {
  $("kids").innerHTML = kids.map(k => `<div class="li"><div class="grow"><h3>${esc(k.name)}</h3></div>
    <button class="btn btn-ghost btn-sm" data-kid-del="${k.id}">Remover</button></div>`).join("")
    || `<p class="empty">Nenhum filho cadastrado.</p>`;
  $("kids").querySelectorAll("[data-kid-del]").forEach(btn => btn.onclick = async () => {
    if (!confirm("Remover do cadastro? Os horários já marcados continuam.")) return;
    try { renderKids(await rpc("remove_my_child", { p_id: +btn.dataset.kidDel })); } catch (e) { toast(e.message); }
  });
}
$("kid-form").onsubmit = async e => {
  e.preventDefault();
  const input = e.target.elements.namedItem("name");
  try { renderKids(await rpc("save_my_child", { p_id: null, p_name: input.value })); input.value = ""; toast("Filho cadastrado"); }
  catch (ex) { toast(ex.message); }
};

// Volta da página de pagamento da InfinitePay: confere no servidor e limpa o endereço
async function backFromPayment() {
  const q = new URLSearchParams(location.search);
  if (q.get("pagamento") !== "1" || !q.get("order_nsu")) return;
  history.replaceState(null, "", "/conta.html");
  try {
    const r = await callFn("pagamento-retorno", Object.fromEntries(
      ["order_nsu", "transaction_nsu", "slug", "receipt_url", "capture_method"].map(k => [k, q.get(k) || ""])));
    toast(r.paid ? (r.kind === "pacote" ? "Pagamento aprovado! Seu pacote já está ativo." : "Pagamento aprovado! Seu horário está pago.")
      : "O pagamento ainda não apareceu. Se você pagou, ele é confirmado em instantes.");
  } catch (e) { toast(e.message); }
}

$("profile-form").onsubmit = async e => {
  e.preventDefault();
  const f = e.target.elements;
  try {
    await rpc("set_my_pay_pref", { p_pref: f.namedItem("pref_pay").value || null });
    await rpc("update_my_profile", { p_name: f.namedItem("name").value, p_phone: f.namedItem("phone").value,
      p_birth_date: f.namedItem("birth_date").value || null });
    toast("Dados salvos"); load();
  } catch (ex) { toast(ex.message); }
};

// nome e telefone do formulário de perfil, para a senha não repetir esses dados
const dadosDaPessoa = () => { const f = $("profile-form").elements; return [f.namedItem("name").value, f.namedItem("phone").value.replace(/\D/g, "")]; };

$("password-form").onsubmit = async e => {
  e.preventDefault();
  const pw = e.target.elements.password.value;
  const fraca = senhaFraca(pw, dadosDaPessoa());
  if (fraca) return toast(fraca);
  try { await auth.updatePassword(pw); e.target.reset(); toast("Senha trocada"); } catch (ex) { toast(ex.message); }
};

$("recovery-form").onsubmit = async e => {
  e.preventDefault();
  const pw = e.target.elements.password.value, err = e.target.querySelector(".err");
  const fraca = senhaFraca(pw, dadosDaPessoa());
  if (fraca) return err.textContent = fraca;
  try { await auth.updatePassword(pw); toast("Nova senha salva!"); load(); } catch (ex) { err.textContent = ex.message; }
};

$("delete-account").onclick = async () => {
  if (!confirm("Excluir sua conta e todos os seus dados? Isso não pode ser desfeito.")) return;
  try {
    await callFn("excluir-conta");
    Session.set(null);
    toast("Conta excluída.");
    load();
  } catch (e) { toast(e.message); }
};

$("logout").onclick = async () => { await auth.signOut(); load(); };

if (auth.takeRecoveryFromUrl()) show("recovery");
else load().catch(e => toast(e.message));
