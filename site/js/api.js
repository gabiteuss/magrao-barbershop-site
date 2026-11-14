// Cliente mínimo do Supabase (login, banco e funções) + utilidades das telas
const CFG = window.APP_CONFIG || {};
const SESSION_KEY = "magrao.sessao";

class ApiError extends Error {
  constructor(message, status) { super(message); this.status = status; }
}

const Session = {
  get() { try { return JSON.parse(localStorage.getItem(SESSION_KEY)); } catch { return null; } },
  set(s) {
    try {
      if (s) localStorage.setItem(SESSION_KEY, JSON.stringify({
        access_token: s.access_token, refresh_token: s.refresh_token,
        expires_at: s.expires_at || Math.floor(Date.now() / 1000) + (s.expires_in || 3600),
      }));
      else localStorage.removeItem(SESSION_KEY);
    } catch { /* navegador sem armazenamento */ }
  },
};

// Traduz os erros do Supabase Auth para mensagens claras
function authMessage(data, status) {
  const raw = data?.msg || data?.error_description || data?.message || "";
  const code = data?.error_code || data?.code || "";
  if (/already registered|user_already_exists/i.test(raw + code)) return "Esse e-mail já tem conta. Use \"Já tenho conta\".";
  if (/Database error saving new user/i.test(raw)) return "Não foi possível criar a conta. Confira o WhatsApp (com DDD) — ele pode já estar cadastrado.";
  if (/Invalid login credentials/i.test(raw)) return "E-mail ou senha incorretos.";
  if (/weak_password|Password should/i.test(raw + code)) return "Senha fraca: use pelo menos 8 caracteres, com letras e números.";
  if (/captcha/i.test(raw)) return "Confirme que você não é um robô.";
  if (status === 429) return "Muitas tentativas. Espere alguns minutos.";
  return raw || "Não foi possível entrar. Tente de novo.";
}

async function authFetch(path, body, method = "POST", token) {
  const res = await fetch(`${CFG.SUPABASE_URL}/auth/v1/${path}`, {
    method,
    headers: { apikey: CFG.SUPABASE_ANON_KEY, "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await res.json().catch(() => null);
  if (!res.ok) throw new ApiError(authMessage(data, res.status), res.status);
  return data;
}

let refreshing = null;
async function accessToken() {
  const s = Session.get();
  if (!s) return null;
  if (s.expires_at - 60 > Date.now() / 1000) return s.access_token;
  refreshing ||= authFetch("token?grant_type=refresh_token", { refresh_token: s.refresh_token })
    .then(d => { Session.set(d); return d.access_token; })
    .catch(() => { Session.set(null); return null; })
    .finally(() => { refreshing = null; });
  return refreshing;
}

const auth = {
  async signUp({ name, phone, email, password, privacy, birth_date, captchaToken }) {
    const d = await authFetch("signup", {
      email, password, data: { name, phone, birth_date, privacy: privacy ? "true" : "false" },
      ...(captchaToken ? { gotrue_meta_security: { captcha_token: captchaToken } } : {}),
    });
    if (!d.access_token) throw new ApiError("Conta criada. Confirme o seu e-mail para entrar.");
    Session.set(d);
  },
  async signIn(email, password, captchaToken) {
    Session.set(await authFetch("token?grant_type=password", {
      email, password, ...(captchaToken ? { gotrue_meta_security: { captcha_token: captchaToken } } : {}),
    }));
  },
  async signOut() {
    const t = await accessToken();
    if (t) await authFetch("logout", null, "POST", t).catch(() => {});
    Session.set(null);
  },
  recover: (email, captchaToken) => authFetch(`recover?redirect_to=${encodeURIComponent(location.origin + "/conta.html")}`, {
    email, ...(captchaToken ? { gotrue_meta_security: { captcha_token: captchaToken } } : {}),
  }),
  async updatePassword(password) { await authFetch("user", { password }, "PUT", await accessToken()); },
  // Link de "esqueci a senha": o Supabase volta para o site com a sessão no endereço (#access_token=...)
  takeRecoveryFromUrl() {
    const h = new URLSearchParams(location.hash.slice(1));
    if (h.get("type") !== "recovery" || !h.get("access_token")) return false;
    Session.set({ access_token: h.get("access_token"), refresh_token: h.get("refresh_token"), expires_in: +h.get("expires_in") || 3600 });
    history.replaceState(null, "", location.pathname);
    return true;
  },
  loggedIn: () => !!Session.get(),
};

async function rpc(fn, args = {}) {
  const token = await accessToken();
  const res = await fetch(`${CFG.SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: { apikey: CFG.SUPABASE_ANON_KEY, Authorization: `Bearer ${token || CFG.SUPABASE_ANON_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify(args),
  });
  const data = await res.json().catch(() => null);
  if (!res.ok) {
    if (res.status === 401 && token) Session.set(null);
    throw new ApiError(data?.message || "Algo deu errado. Tente de novo.", res.status);
  }
  return data;
}

async function callFn(name, body = {}) {
  const token = await accessToken();
  if (!token) throw new ApiError("Entre na sua conta para continuar.", 401);
  const res = await fetch(`${CFG.SUPABASE_URL}/functions/v1/${name}`, {
    method: "POST",
    headers: { apikey: CFG.SUPABASE_ANON_KEY, Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const data = await res.json().catch(() => null);
  if (!res.ok) throw new ApiError(data?.message || "Algo deu errado. Tente de novo.", res.status);
  return data;
}

async function currentUser() {
  if (!auth.loggedIn()) return null;
  try { return await rpc("my_profile"); } catch { return null; }
}

// ------------------------------------------------------------ utilidades das telas
const brl = cents => (cents / 100).toLocaleString("pt-BR", { style: "currency", currency: "BRL" });
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
// Senhas que aparecem em vazamentos (o plano grátis do Supabase não confere isso sozinho)
const SENHAS_COMUNS = new Set(("12345678 123456789 1234567890 87654321 11223344 12341234 12121212 11111111 00000000 " +
  "senha123 senha1234 senha12345 senha@123 mudar123 trocar123 acesso123 admin123 admin1234 root1234 teste123 teste1234 " +
  "password1 password123 passw0rd p@ssw0rd qwerty123 qwerty12 asdf1234 asdfgh12 zxcvbn12 abc12345 abcd1234 a1b2c3d4 q1w2e3r4 1q2w3e4r " +
  "iloveyou1 monkey123 dragon123 master123 welcome1 letmein1 sunshine1 princess1 football1 baseball1 superman1 batman123 " +
  "brasil123 brasil2026 flamengo1 flamengo123 corinthians1 palmeiras1 saopaulo1 santos123 vasco123 gremio123 " +
  "amor1234 amor12345 deus1234 jesus123 jesus1234 familia1 familia123 gabriel1 gabriel123 matheus1 lucas123 pedro123 " +
  "magrao123 barbearia1 barber123 barbershop1").split(" "));
const SEQUENCIAS = ["0123456789", "9876543210", "abcdefghijklmnopqrstuvwxyz", "qwertyuiop", "asdfghjkl", "zxcvbnm"];
/** Devolve o motivo se a senha for fraca, ou "" se estiver boa. extras: e-mail, nome, telefone da pessoa. */
function senhaFraca(pw, extras = []) {
  pw = pw || "";
  if (pw.length < 8) return "A senha precisa ter pelo menos 8 caracteres.";
  if (!/[a-zA-Z]/.test(pw) || !/\d/.test(pw)) return "Use letras e números na senha.";
  const s = pw.toLowerCase();
  const base = s.replace(/[^a-z0-9]/g, "");
  if (SENHAS_COMUNS.has(s) || SENHAS_COMUNS.has(base) || new Set(s).size <= 3
      || SEQUENCIAS.some(q => q.includes(base.replace(/\d+$/, "")) && base.replace(/\d+$/, "").length >= 6))
    return "Essa senha é muito usada e fácil de adivinhar. Escolha outra.";
  for (const x of extras) {
    const t = String(x || "").toLowerCase().split("@")[0].replace(/[^a-z0-9]/g, "");
    if (t.length >= 4 && (base.includes(t) || (t.length >= 8 && base.includes(t.slice(-8)))))
      return "Não use seu nome, e-mail ou telefone na senha.";
  }
  return "";
}
const fmtPhone = p => p?.length >= 12 ? `(${p.slice(2, 4)}) ${p.slice(4, -4)}-${p.slice(-4)}` : p;
const DIAS = ["dom", "seg", "ter", "qua", "qui", "sex", "sáb"];
const STATUS = { pendente: "aguardando Pix", confirmado: "confirmado", concluido: "concluído", faltou: "faltou", cancelado: "cancelado", expirado: "expirado" };
// WhatsApp do barbeiro do horário, com a mensagem pronta (sem número cadastrado: WhatsApp da barbearia)
const waBarber = b => `https://wa.me/${b.barber_whatsapp || CFG.WHATSAPP}?text=${encodeURIComponent(
  `Olá, ${b.barber_name}! Meu corte está marcado para ${b.quando}${b.child_name ? ` (corte do ${b.child_name})` : ""}.`)}`;
const PAY = { dinheiro: "dinheiro", credito: "crédito", debito: "débito", pix: "Pix", pacote: "pacote", pendente: "pendente", nao_informado: "não informado" };
const dateLabel = iso => { const d = new Date(iso + "T12:00"); return `${DIAS[d.getDay()]} ${d.toLocaleDateString("pt-BR", { day: "2-digit", month: "2-digit" })}`; };

function toast(msg) {
  let t = document.querySelector(".toast");
  if (!t) { t = document.createElement("div"); t.className = "toast"; t.setAttribute("role", "status"); document.body.appendChild(t); }
  t.textContent = msg;
  t.classList.add("on");
  clearTimeout(t._h);
  t._h = setTimeout(() => t.classList.remove("on"), 2800);
}

// Captcha anti-robô (Cloudflare Turnstile), só se a chave estiver configurada
let turnstileReady = null;
function loadTurnstile() {
  if (!CFG.TURNSTILE_SITE_KEY) return Promise.resolve(false);
  turnstileReady ||= new Promise(res => {
    const s = document.createElement("script");
    s.src = "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit";
    s.onload = () => res(true);
    s.onerror = () => res(false);
    document.head.appendChild(s);
  });
  return turnstileReady;
}

// Formulário de entrar / criar conta / esqueci a senha
function authForm(container, onDone) {
  container.innerHTML = `
    <div class="tabs u-mb-18" role="tablist">
      <button type="button" data-m="login" aria-selected="true">Já tenho conta</button>
      <button type="button" data-m="signup" aria-selected="false">Criar conta</button>
    </div>
    <form class="stack" novalidate>
      <label data-only="signup" hidden>Nome<input name="name" autocomplete="name" placeholder="Seu nome" maxlength="80"></label>
      <label data-only="signup" hidden>WhatsApp<input name="phone" type="tel" inputmode="tel" autocomplete="tel" placeholder="(19) 99999-9999" maxlength="20"></label>
      <label data-only="signup" hidden>Data de nascimento<input name="birth_date" type="date" autocomplete="bday" min="1900-01-01">
        <small class="muted">No seu aniversário tem presente da barbearia 🎁</small></label>
      <label>E-mail<input name="email" type="email" autocomplete="email" placeholder="voce@email.com" maxlength="120"></label>
      <label data-only="login signup">Senha<input name="password" type="password" autocomplete="current-password" placeholder="Mínimo 8 caracteres" maxlength="72"></label>
      <label class="check small" data-only="signup" hidden><input type="checkbox" name="privacy">
        <span>Li e aceito a <a href="/privacidade.html" target="_blank" rel="noopener">política de privacidade</a>.</span></label>
      <div class="captcha"></div>
      <p class="err" role="alert"></p>
      <button class="btn btn-main btn-block" type="submit">Entrar</button>
      <p class="small" data-only="login"><a href="#" data-m="forgot">Esqueci minha senha</a></p>
      <p class="small" data-only="forgot" hidden><a href="#" data-m="login">← Voltar para entrar</a></p>
    </form>`;
  let mode = "login", widget = null;
  const form = container.querySelector("form");
  const err = form.querySelector(".err");
  const submit = form.querySelector("button[type=submit]");
  const setMode = m => {
    mode = m;
    container.querySelectorAll(".tabs button").forEach(b => b.setAttribute("aria-selected", b.dataset.m === m));
    container.querySelectorAll("[data-only]").forEach(el => el.hidden = !el.dataset.only.split(" ").includes(m));
    submit.textContent = { login: "Entrar", signup: "Criar conta", forgot: "Enviar link para criar nova senha" }[m];
    form.password.autocomplete = m === "signup" ? "new-password" : "current-password";
    err.textContent = "";
  };
  container.querySelectorAll("[data-m]").forEach(b => b.onclick = e => { e.preventDefault(); setMode(b.dataset.m); });

  // Link de cadastro mandado pela barbearia no WhatsApp: abre em "Criar conta" com nome e WhatsApp preenchidos
  const q = new URLSearchParams(location.search);
  if (q.has("cadastro")) {
    setMode("signup");
    form.name.value = (q.get("nome") || "").slice(0, 80);
    const tel = (q.get("tel") || "").replace(/\D/g, "").replace(/^55(?=\d{10,11}$)/, "");
    if (tel) form.phone.value = fmtPhone("55" + tel);
  }

  loadTurnstile().then(ok => {
    if (ok && window.turnstile) widget = window.turnstile.render(form.querySelector(".captcha"), { sitekey: CFG.TURNSTILE_SITE_KEY, theme: "dark", language: "pt-br" });
  });

  form.onsubmit = async e => {
    e.preventDefault();
    const f = Object.fromEntries(new FormData(form));
    f.privacy = form.privacy.checked;
    const captchaToken = widget !== null ? window.turnstile.getResponse(widget) : undefined;
    err.textContent = "";
    if (!/^\S+@\S+\.\S+$/.test(f.email || "")) return err.textContent = "Digite um e-mail válido.";
    if (mode === "signup") {
      if ((f.name || "").trim().length < 2) return err.textContent = "Digite seu nome.";
      if (!/^\d{10,11}$/.test((f.phone || "").replace(/\D/g, ""))) return err.textContent = "Digite o WhatsApp com DDD.";
      const fraca = senhaFraca(f.password, [f.email, f.name, (f.phone || "").replace(/\D/g, "")]);
      if (fraca) return err.textContent = fraca;
      if (!f.birth_date || f.birth_date > new Date().toLocaleDateString("sv-SE") || f.birth_date < "1900-01-01") return err.textContent = "Digite sua data de nascimento.";
      if (!f.privacy) return err.textContent = "Aceite a política de privacidade para continuar.";
    }
    submit.disabled = true;
    try {
      if (mode === "login") await auth.signIn(f.email, f.password, captchaToken);
      else if (mode === "signup") await auth.signUp({ ...f, captchaToken });
      else {
        await auth.recover(f.email, captchaToken);
        err.textContent = "";
        toast("Se o e-mail tiver conta, enviamos um link para criar uma nova senha.");
        return setMode("login");
      }
      onDone(await currentUser());
    } catch (ex) {
      err.textContent = ex.message;
      if (widget !== null) window.turnstile.reset(widget);
    } finally {
      submit.disabled = false;
    }
  };
}

const TOPO = `
  <header class="top"><div class="wrap">
    <a class="brand" href="/"><span class="pole"></span>Magrão <b>Barber</b></a>
    <nav><a class="hide-sm" href="/">Início</a><a href="/agendar.html">Agendar</a><a href="/conta.html">Minha conta</a></nav>
  </div></header>`;
