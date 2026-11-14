// Confirmar presença pelo link da mensagem (não precisa entrar na conta)
document.getElementById("topo").innerHTML = TOPO;
const box = document.getElementById("box");
const token = new URLSearchParams(location.search).get("c") || "";
// Tira o código do endereço depois de ler (não fica no histórico nem é repassado)
history.replaceState(null, "", location.pathname);

function render(b) {
  const head = `<div class="eyebrow">Confirmar presença</div>
    <h1 class="page-title u-m-0">Olá, ${esc(b.first_name)}!</h1>
    <p><b>${esc(b.service_name)}</b> com <b>${esc(b.barber_name)}</b><br>${esc(b.quando)}</p>`;

  if (b.status === "cancelado") {
    const why = b.cancelled_by === "sistema" ? "Como não recebemos a confirmação a tempo, o horário foi liberado." : "Esse horário foi cancelado.";
    box.innerHTML = `${head}<p class="muted">${why}</p><div><a class="btn btn-main" href="/agendar.html">Agendar de novo</a></div>`;
    return;
  }
  if (b.status !== "confirmado") {
    box.innerHTML = `${head}<p class="muted">Esse horário não está mais ativo.</p><div><a class="btn btn-main" href="/agendar.html">Agendar</a></div>`;
    return;
  }
  if (b.confirmed) {
    box.innerHTML = `${head}<div class="done-icon">✓</div><p><b>Presença confirmada.</b> Te esperamos! 💈</p>
      <p class="muted small">Se mudar de ideia, cancele em <a href="/conta.html">Minha conta</a> para liberar o horário.</p>`;
    return;
  }
  box.innerHTML = `${head}
    <p class="muted">Confirme até as <b>${esc(b.deadline)}</b>. Depois disso o horário é liberado para outro cliente.</p>
    <p class="err" id="err" role="alert"></p>
    <button class="btn btn-main btn-block" id="yes">Vou sim ✓</button>
    <button class="btn btn-ghost btn-block" id="no">Não vou, liberar o horário</button>`;
  document.getElementById("yes").onclick = () => answer(true);
  document.getElementById("no").onclick = () => {
    if (confirm("Liberar esse horário para outro cliente?")) answer(false);
  };
}

async function answer(going) {
  document.querySelectorAll("#box button").forEach(b => b.disabled = true);
  try {
    render(await rpc("confirm_attendance", { p_token: token, p_going: going }));
    if (!going) toast("Horário liberado. Obrigado por avisar!");
  } catch (e) {
    document.getElementById("err").textContent = e.message;
    document.querySelectorAll("#box button").forEach(b => b.disabled = false);
  }
}

if (!/^[0-9a-f]{36}$/.test(token)) {
  box.innerHTML = `<h1 class="page-title">Link inválido</h1><p class="muted">Abra o link que chegou no seu WhatsApp ou confirme em <a href="/conta.html">Minha conta</a>.</p>`;
} else {
  rpc("attendance_info", { p_token: token }).then(render).catch(e => {
    box.innerHTML = `<h1 class="page-title">Não encontramos esse horário</h1><p class="muted">${esc(e.message)}</p>
      <div><a class="btn btn-main" href="/conta.html">Minha conta</a></div>`;
  });
}
