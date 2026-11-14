/* =========================================================
   CONTEÚDO DA PÁGINA INICIAL: edite só esta parte.
   Serviços, preços, barbeiros e horários vêm do painel (/painel.html).
   price: número em reais, ou null para mostrar "Consulte"
   ========================================================= */
const FAIXA = { text: "Agende online em 1 minuto e garanta seu horário.", link: "/agendar.html", linkText: "Agendar agora" };

// Promoções: vêm do painel (Serviços e preços → Promoções da página inicial)

const PRODUTOS = [
  { cat: "cuidados", name: "Pasta Black Premium", desc: "Fox For Men · 150g · fixação extra forte", img: "pasta-black", price: null },
  { cat: "cuidados", name: "Wax Toque Seco", desc: "Fox For Men · 120g · fixação forte", img: "wax-toque-seco", price: null },
  { cat: "cuidados", name: "Pasta Orange", desc: "Fox For Men · 120g · fixação forte, incolor", img: "pasta-orange", price: null },
  { cat: "cuidados", name: "Cera Hair Caramelo", desc: "Fox For Men · 130g · com queratina", img: "cera-caramelo", price: null },
  { cat: "cuidados", name: "Creme Modelador Efeito Teia", desc: "Fox For Men · 150g · fixação suave", img: "creme-teia", price: null },
  { cat: "cuidados", name: "Gel Cera Uva", desc: "Fox For Men · 300g · mega fixação", img: "gel-uva", price: null },
  { cat: "cuidados", name: "Sérum Skin Fox", desc: "30ml · para pelos encravados, pós-barba", img: "serum-skin-fox", price: null },
  { cat: "bebidas", name: "Heineken", desc: "Long neck 330ml", img: "heineken", price: null },
  { cat: "bebidas", name: "Corona Extra", desc: "Long neck 330ml", img: "corona", price: null },
  { cat: "bebidas", name: "Budweiser", desc: "Long neck 330ml", img: "budweiser", price: null },
  { cat: "bebidas", name: "Brahma Chopp", desc: "Lata 350ml", img: "brahma", price: null },
  { cat: "bebidas", name: "Skol", desc: "Lata 350ml", img: "skol", price: null },
  { cat: "bebidas", name: "Antarctica", desc: "Lata 350ml", img: "antarctica", price: null },
  { cat: "bebidas", name: "51 Ice Limão", desc: "275ml", img: "51-ice", price: null },
  { cat: "bebidas", name: "Água Lindoya com gás", desc: "510ml", img: "agua-lindoya", price: null },
];

const ENDERECO = "R. Hermínio Berton, 209 – Sacilotto<br>Artur Nogueira – SP, 13160-000";
const MAPA_BUSCA = "Magrão BARBER SHOP, R. Hermínio Berton, 209 - Sacilotto, Artur Nogueira - SP";
const FOTOS_CORTES = 22; // img/cortes/corteN.webp (grande) e corteN-p.webp (miniatura)
// Usado só se o banco estiver fora do ar (o normal é vir do expediente cadastrado no painel)
const HORARIO_RESERVA = [
  { weekday: 1, open: "07:00", close: "20:00" }, { weekday: 2, open: "07:00", close: "20:00" },
  { weekday: 3, open: "07:00", close: "20:00" }, { weekday: 4, open: "06:00", close: "20:00" },
  { weekday: 5, open: "06:00", close: "21:00" }, { weekday: 6, open: "06:00", close: "17:00" },
];

/* ===================== fim do conteúdo ===================== */

const reais = v => v == null ? "Consulte" : "R$ " + v.toLocaleString("pt-BR", { minimumFractionDigits: v % 1 ? 2 : 0 });
const wa = msg => `https://wa.me/${CFG.WHATSAPP}?text=${encodeURIComponent(msg)}`;
const $ = id => document.getElementById(id);
const WEEKDAYS = ["Domingo", "Segunda", "Terça", "Quarta", "Quinta", "Sexta", "Sábado"];

$("strip").innerHTML = `${esc(FAIXA.text)} <a href="${esc(FAIXA.link)}">${esc(FAIXA.linkText)}</a>`;

function renderPromos(promos) {
  $("promocoes").hidden = !promos.length;  // sem promoção disponível, a seção some
  document.querySelector('a[href="#promocoes"]')?.closest("li")?.toggleAttribute("hidden", !promos.length);
  $("promos").innerHTML = promos.map(p => {
    const on = p.available !== false;
    return `
  <article class="promo${on ? "" : " off"}">
    <div class="promo-top">${p.tag ? `<span class="tag">${esc(p.tag)}</span>` : "<span></span>"}
      <span class="status ${on ? "on" : "off"}">${on ? "Disponível" : "Indisponível"}</span></div>
    <h3>${esc(p.title)}</h3>
    ${p.service && p.service !== p.title ? `<small class="svc">${esc(p.service)}</small>` : ""}
    <p>${esc(p.body)}</p>
    ${p.price_cents != null ? `<div class="price">${p.from_cents ? `<s>${reais(p.from_cents / 100)}</s>` : ""}${reais(p.price_cents / 100)}</div>` : ""}
    ${on ? `<a target="_blank" rel="noopener noreferrer" href="${wa(`Olá! Quero aproveitar a promoção "${p.title}" 💈`)}">Quero essa →</a>`
         : `<span class="unavail">No momento indisponível</span>`}
  </article>`;
  }).join("");
}

function renderHours(hours) {
  const today = new Date().getDay();
  const byDay = Object.fromEntries(hours.map(h => [h.weekday, `${h.open.replace(":00", "h")} – ${h.close.replace(":00", "h")}`]));
  // Segunda primeiro, domingo por último
  $("hours").innerHTML = [1, 2, 3, 4, 5, 6, 0].map(d =>
    `<li class="${d === today ? "today" : ""}"><span>${WEEKDAYS[d]}</span><span>${byDay[d] || "Fechado"}</span></li>`).join("");
}

rpc("public_info").then(({ services, barbers, hours, promos }) => {
  renderPromos(promos || []);
  $("menu").innerHTML = services.map(s => `
    <div class="item"><div><h3>${esc(s.name)}</h3><small>${esc(s.description)}</small></div><span class="dots"></span>
      <span class="price">${s.price_from ? "<small>a partir de</small> " : ""}${reais(s.price_cents / 100)}</span></div>`).join("");
  $("team").innerHTML = barbers.map(b => `
    <article class="barber">
      <div class="pic ph"><span class="ini">${esc(b.name[0])}</span>${b.photo ? `<img src="${esc(b.photo)}" alt="${esc(b.name)}" loading="lazy">` : ""}</div>
      <div class="body">
        <div class="eyebrow u-m-0">${esc(b.title)}</div>
        <h3>${esc(b.name)}</h3>
        <p>${esc(b.bio)}</p>
        <a class="btn btn-ghost" href="/agendar.html?barbeiro=${b.id}">Agendar com ${esc(b.name)}</a>
      </div>
    </article>`).join("");
  $("team").querySelectorAll("img").forEach(img => img.addEventListener("error", () => img.remove()));
  renderHours(hours);
}).catch(() => {
  $("menu").innerHTML = `<p class="u-muted">Veja os preços na tela de <a class="u-td-underline" href="/agendar.html">agendamento</a>.</p>`;
  renderHours(HORARIO_RESERVA);
  renderPromos([]);
});

// Galeria: miniaturas na grade (9 primeiro, "Ver mais" mostra o resto) e foto grande ao tocar
const VISIVEIS = 9;
for (let i = 1; i <= FOTOS_CORTES; i++) {
  const box = document.createElement("button");
  box.type = "button";
  box.className = "shot ph" + (i > VISIVEIS ? " more" : "");
  box.setAttribute("aria-label", `Ver o corte ${i} em tamanho grande`);
  const img = new Image();
  img.loading = "lazy";
  img.decoding = "async";
  img.width = 450; img.height = 600;
  img.alt = `Corte ${i} feito na Magrão Barber Shop em Artur Nogueira`;
  img.src = `img/cortes/corte${i}-p.webp`;
  img.onerror = () => { box.remove(); };
  box.appendChild(img);
  box.onclick = () => abrirFoto(i);
  $("grid").appendChild(box);
}
if (FOTOS_CORTES > VISIVEIS) {
  $("grid-more").hidden = false;
  $("grid-more").textContent = `Ver mais ${FOTOS_CORTES - VISIVEIS} fotos`;
  $("grid-more").onclick = () => { $("grid").classList.add("all"); $("grid-more").hidden = true; };
}

let fotoAtual = 1;
function abrirFoto(i) {
  fotoAtual = (i - 1 + FOTOS_CORTES) % FOTOS_CORTES + 1;
  $("lb-img").src = `img/cortes/corte${fotoAtual}.webp`;
  $("lb-img").alt = `Corte ${fotoAtual} feito na Magrão Barber Shop`;
  $("lb-count").textContent = `${fotoAtual} de ${FOTOS_CORTES}`;
  if (!$("lb").open) $("lb").showModal();
}
$("lb-prev").onclick = () => abrirFoto(fotoAtual - 1);
$("lb-next").onclick = () => abrirFoto(fotoAtual + 1);
$("lb-close").onclick = () => $("lb").close();
$("lb").addEventListener("click", e => { if (e.target === $("lb")) $("lb").close(); });
$("lb").addEventListener("keydown", e => {
  if (e.key === "ArrowLeft") abrirFoto(fotoAtual - 1);
  if (e.key === "ArrowRight") abrirFoto(fotoAtual + 1);
});
let toqueX = null;  // arrastar para o lado no celular
$("lb").addEventListener("touchstart", e => { toqueX = e.touches[0].clientX; }, { passive: true });
$("lb").addEventListener("touchend", e => {
  if (toqueX === null) return;
  const dx = e.changedTouches[0].clientX - toqueX; toqueX = null;
  if (Math.abs(dx) > 50) abrirFoto(fotoAtual + (dx < 0 ? 1 : -1));
});

function showProds(cat) {
  $("prods").innerHTML = PRODUTOS.filter(p => p.cat === cat).map(p => `
    <article class="prod">
      <img src="img/produtos/${p.img}.webp" alt="${esc(p.name)}" loading="lazy" width="600" height="800">
      <div class="body"><h3>${esc(p.name)}</h3><small>${esc(p.desc)}</small><span class="price">${reais(p.price)}</span></div>
    </article>`).join("");
  $("prod-note").hidden = cat !== "bebidas";
  document.querySelectorAll("#produtos .tabs button").forEach(b => b.setAttribute("aria-selected", b.dataset.cat === cat));
}
document.querySelectorAll("#produtos .tabs button").forEach(b => b.onclick = () => showProds(b.dataset.cat));
showProds("cuidados");

$("endereco").innerHTML = ENDERECO;
$("mapa").src = `https://www.google.com/maps?q=${encodeURIComponent(MAPA_BUSCA)}&output=embed`;
$("rota").href = `https://www.google.com/maps/dir/?api=1&destination=${encodeURIComponent(MAPA_BUSCA)}`;

document.querySelectorAll(".js-wa").forEach(a => {
  a.href = wa("Olá! Vim pelo site e quero agendar um horário na Magrão Barber Shop 💈");
  a.target = "_blank"; a.rel = "noopener noreferrer";
});

const ano = new Date().getFullYear();
$("ano").textContent = ano;
$("anos").textContent = (ano - 2015) + "+";

// Carrossel do salão (Nossa história): a 1ª foto é a do salão hoje, depois a dos produtos
(() => {
  const car = $("salao-car");
  if (!car) return;
  const track = car.querySelector(".car-track"), dots = car.querySelector(".car-dots");
  const fotos = () => [...track.querySelectorAll("img")];
  const atual = () => Math.round(track.scrollLeft / track.clientWidth);
  const ir = i => { const n = fotos().length; track.scrollTo({ left: ((i + n) % n) * track.clientWidth }); };
  const montar = () => {
    const n = fotos().length;
    car.querySelectorAll(".car-btn").forEach(b => b.hidden = n < 2);
    dots.innerHTML = n < 2 ? "" : fotos().map((_, i) => `<button type="button" aria-label="Foto ${i + 1} de ${n}"></button>`).join("");
    dots.querySelectorAll("button").forEach((b, i) => b.onclick = () => ir(i));
    marcar();
  };
  const marcar = () => dots.querySelectorAll("button").forEach((b, i) => b.setAttribute("aria-current", i === atual()));
  fotos().forEach(img => img.addEventListener("error", () => { img.remove(); montar(); }));
  car.querySelector(".car-prev").onclick = () => ir(atual() - 1);
  car.querySelector(".car-next").onclick = () => ir(atual() + 1);
  track.addEventListener("scroll", marcar, { passive: true });
  track.addEventListener("scrollend", marcar);
  montar();
  if (!matchMedia("(prefers-reduced-motion: reduce)").matches) {
    let pausa = false;
    car.addEventListener("pointerenter", () => pausa = true);
    car.addEventListener("pointerleave", () => pausa = false);
    car.addEventListener("focusin", () => pausa = true);
    car.addEventListener("focusout", () => pausa = false);
    setInterval(() => { if (!pausa && !document.hidden && fotos().length > 1) ir(atual() + 1); }, 5000);
  }
})();

const header = $("top");
const onScroll = () => header.classList.toggle("solid", scrollY > 40);
addEventListener("scroll", onScroll, { passive: true }); onScroll();

const io = new IntersectionObserver(es => es.forEach(e => { if (e.isIntersecting) { e.target.classList.add("on"); io.unobserve(e.target); } }), { threshold: .12 });
document.querySelectorAll(".reveal").forEach(el => io.observe(el));
