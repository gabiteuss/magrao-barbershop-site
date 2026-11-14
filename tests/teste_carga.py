"""Teste de segurança e de pico do site no ar (Cloudflare + Supabase). Só Python padrão.

  python tests/teste_carga.py seguranca                 visitante sem login não lê nem mexe em nada
  python tests/teste_carga.py leitura 500 [RAMPA]       500 pessoas abrindo a página de agendar (chegando em RAMPA segundos)
  python tests/teste_carga.py agendamento 500 DIA CHAVE [RAMPA]  500 pessoas tentando agendar (4 barbeiros)

O modo "agendamento" precisa de clientes de teste e da função loadtest_book criados antes no banco
(tests/carga_preparar.sql) e apagados depois (tests/carga_limpar.sql).
"""
import json
import random
import re
import statistics
import sys
import threading
import time
import http.client
import urllib.parse
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
_cfg = (ROOT / "site/js/config.js").read_text(encoding="utf-8")
API, ANON = (re.search(rf'{k}:\s*"([^"]+)"', _cfg).group(1) for k in ("SUPABASE_URL", "SUPABASE_ANON_KEY"))
SITE = "https://xn--magrobarbershop-nkb.com.br"
ORIGIN = SITE


_conns = threading.local()  # como um navegador: cada pessoa (thread) reaproveita a conexão com cada servidor


def req(method, url, body=None, timeout=30):
    """Devolve (status, corpo, segundos). status 0 = sem resposta (timeout/conexão)."""
    headers = {"apikey": ANON, "Authorization": f"Bearer {ANON}", "Content-Type": "application/json", "Origin": ORIGIN,
               "User-Agent": "magrao-teste-carga/1.0", "Connection": "keep-alive"}
    u = urllib.parse.urlsplit(url)
    pool = getattr(_conns, "pool", None)
    if pool is None:
        pool = _conns.pool = {}
    t0 = time.perf_counter()
    for tentativa in (1, 2):  # conexão reaproveitada pode ter sido fechada pelo servidor: reabre uma vez
        conn = pool.get(u.netloc) or http.client.HTTPSConnection(u.netloc, timeout=timeout)
        pool[u.netloc] = conn
        try:
            conn.request(method, u.path + ("?" + u.query if u.query else ""),
                         body=json.dumps(body).encode() if body is not None else None, headers=headers)
            resp = conn.getresponse()
            return resp.status, resp.read(), time.perf_counter() - t0
        except (http.client.RemoteDisconnected, BrokenPipeError, ConnectionResetError) as e:
            conn.close(); pool.pop(u.netloc, None)
            if tentativa == 2:
                return 0, str(e).encode(), time.perf_counter() - t0
        except Exception as e:  # noqa: BLE001
            conn.close(); pool.pop(u.netloc, None)
            return 0, str(e).encode(), time.perf_counter() - t0


def rpc(fn, args=None, timeout=30):
    return req("POST", f"{API}/rest/v1/rpc/{fn}", args or {}, timeout)


def resumo(nome, tempos, codigos):
    tempos = sorted(tempos)
    q = lambda p: tempos[min(len(tempos) - 1, int(len(tempos) * p))] if tempos else 0  # noqa: E731
    cont = {}
    for c in codigos:
        cont[c] = cont.get(c, 0) + 1
    print(f"  {nome:<28} {len(tempos):>5} req · mediana {statistics.median(tempos) if tempos else 0:5.2f}s"
          f" · 95% até {q(0.95):5.2f}s · pior {tempos[-1] if tempos else 0:5.2f}s · códigos {cont}")
    return {"req": len(tempos), "p50": statistics.median(tempos) if tempos else 0, "p95": q(0.95),
            "max": tempos[-1] if tempos else 0, "codigos": cont}


# ------------------------------------------------------------------ segurança (visitante sem login)
def seguranca():
    falhas = []

    def check(nome, ok, det=""):
        print(("  OK    " if ok else "  FALHA ") + nome + ("" if ok else f" -> {det}"))
        if not ok:
            falhas.append(nome)

    st, b, _ = rpc("public_info")
    check("visitante vê serviços e barbeiros", st == 200 and json.loads(b)["services"], (st, b[:200]))
    for tabela in ("profiles", "bookings", "messages", "children", "products", "booking_items", "settings", "client_packages"):
        st, b, _ = req("GET", f"{API}/rest/v1/{tabela}?select=*&limit=1")
        check(f"não lê a tabela {tabela}", st in (401, 403, 404) or b.strip() == b"[]", (st, b[:120]))
    st, b, _ = rpc("create_booking", {"p_service": 1, "p_date": "2030-01-01", "p_time": "10:00"})
    check("não agenda sem login", st in (401, 403), (st, b[:120]))
    for fn, args in [("admin_agenda", {"p_date": "2026-12-10"}), ("staff_cashbox", {"p_from": "2026-12-01", "p_to": "2026-12-31"}),
                     ("admin_messages", {}), ("staff_settle", {"p_id": 1, "p_method": "pix"}),
                     ("admin_save_product", {"p": {"name": "x", "price_cents": 1}}), ("my_children", {}),
                     ("admin_set_status", {"p_id": 1, "p_status": "concluido"}), ("loadtest_book", {})]:
        st, b, _ = rpc(fn, args)
        corpo = b.decode(errors="replace")
        check(f"visitante não usa {fn}", st in (401, 403, 404) or (st == 200 and corpo.strip() in ("[]", "null")), (st, corpo[:120]))
    st, b, _ = req("GET", f"{SITE}/painel")
    check("painel abre (pede login na tela)", st == 200, st)
    st, b, _ = req("GET", f"{SITE}/robots.txt")
    check("robots bloqueia painel e conta", st == 200 and b"painel" in b, (st, b[:200]))
    print("\n" + ("SEGURANÇA OK" if not falhas else f"{len(falhas)} FALHA(S): " + "; ".join(falhas)))
    return not falhas


# ------------------------------------------------------------------ pico de leitura (abrir a página e ver horários)
def leitura(n, rampa=0.0):
    st, b, _ = rpc("public_info")
    pub = json.loads(b)
    servicos = [s["id"] for s in pub["services"]]
    barbeiros = [x["id"] for x in pub["barbers"]]
    st, b, _ = rpc("available_days", {"p_service": servicos[0], "p_barber": None})
    dias = [d["date"] for d in json.loads(b) if d.get("open") and d.get("released", True) is not False]
    pagina = req("GET", f"{SITE}/agendar")[1].decode(errors="replace")
    estaticos = sorted(set(re.findall(r'(?:href|src)="((?:css|js|img)/[^"]+)"', pagina)))

    tempos = {k: [] for k in ("pagina", "estaticos", "public_info", "available_days", "day_grid")}
    codigos = {k: [] for k in tempos}
    lock = threading.Lock()
    largada = threading.Barrier(n)

    def anota(k, r):
        with lock:
            tempos[k].append(r[2]); codigos[k].append(r[0])

    def pessoa(i):
        largada.wait()
        time.sleep(rampa * i / n)  # chegadas espalhadas em `rampa` segundos (0 = todos no mesmo instante)
        anota("pagina", req("GET", f"{SITE}/agendar"))
        for e in estaticos:
            anota("estaticos", req("GET", f"{SITE}/{e}"))
        anota("public_info", rpc("public_info"))
        svc = random.choice(servicos)
        bar = barbeiros[i % len(barbeiros)]
        anota("available_days", rpc("available_days", {"p_service": svc, "p_barber": bar}))
        for _ in range(2):  # olha dois dias
            anota("day_grid", rpc("day_grid", {"p_service": svc, "p_day": random.choice(dias), "p_barber": bar}))

    t0 = time.perf_counter()
    with ThreadPoolExecutor(max_workers=n) as ex:
        list(ex.map(pessoa, range(n)))
    total = time.perf_counter() - t0
    print(f"\n{n} pessoas ao mesmo tempo · terminou em {total:.1f}s")
    out = {k: resumo(k, tempos[k], codigos[k]) for k in tempos}
    erros = sum(c for k in out.values() for cod, c in k["codigos"].items() if cod != 200)
    print(f"\nRequisições com erro: {erros} de {sum(k['req'] for k in out.values())}")
    return {"pessoas": n, "segundos": total, "etapas": out, "erros": erros}


# ------------------------------------------------------------------ pico de agendamento
def agendamento(n, dia, chave, rampa=0.0):
    usuarios = json.loads(sys.stdin.read()) if not sys.stdin.isatty() else None
    st, b, _ = rpc("loadtest_users", {"p_key": chave})
    usuarios = usuarios or json.loads(b)
    st, b, _ = rpc("public_info")
    pub = json.loads(b)
    servico = pub["services"][0]["id"]
    barbeiros = [x["id"] for x in pub["barbers"]]
    nomes = {x["id"]: x["name"] for x in pub["barbers"]}
    # cada pessoa olha a grade do barbeiro dela e clica num horário livre (como no site)
    grades = {}
    for bar in barbeiros:
        st, b, _ = rpc("day_grid", {"p_service": servico, "p_day": dia, "p_barber": bar})
        g = json.loads(b)
        grades[bar] = [s["time"] for s in (g[0]["slots"] if g else []) if s["status"] == "livre"]
    print("Horários livres no dia de teste: " + ", ".join(f"{nomes[k]} {len(v)}" for k, v in grades.items()))

    res, lock = [], threading.Lock()
    largada = threading.Barrier(n)

    def pessoa(i):
        bar = barbeiros[i % len(barbeiros)]
        livres = grades[bar] or ["10:00"]
        hora = random.choice(livres)
        largada.wait()
        time.sleep(rampa * i / n)
        r = rpc("loadtest_book", {"p_key": chave, "p_user": usuarios[i], "p_service": servico, "p_date": dia,
                                  "p_time": hora, "p_barber": bar}, timeout=60)
        msg = ""
        if r[0] != 200:
            try:
                msg = json.loads(r[1]).get("message", "")
            except Exception:  # noqa: BLE001
                msg = r[1][:120].decode(errors="replace")
        with lock:
            res.append({"barbeiro": nomes[bar], "hora": hora, "status": r[0], "seg": r[2], "msg": msg})

    t0 = time.perf_counter()
    with ThreadPoolExecutor(max_workers=n) as ex:
        list(ex.map(pessoa, range(n)))
    total = time.perf_counter() - t0
    print(f"\n{n} pessoas clicando em Agendar ao mesmo tempo · terminou em {total:.1f}s")
    resumo("agendar", [r["seg"] for r in res], [r["status"] for r in res])
    por = {}
    for r in res:
        d = por.setdefault(r["barbeiro"], {"conseguiu": 0, "ocupado": 0, "outro_erro": 0})
        if r["status"] == 200:
            d["conseguiu"] += 1
        elif r["status"] == 409 or "ocupado" in r["msg"]:
            d["ocupado"] += 1
        else:
            d["outro_erro"] += 1
    for k, v in por.items():
        print(f"  {k:<10} conseguiu {v['conseguiu']:>3} · horário já ocupado {v['ocupado']:>3} · outro erro {v['outro_erro']:>3}")
    outros = {}
    for r in res:
        if r["status"] not in (200, 409) and "ocupado" not in r["msg"]:
            outros[f"{r['status']} {r['msg']}"] = outros.get(f"{r['status']} {r['msg']}", 0) + 1
    if outros:
        print("  Outros erros: " + json.dumps(outros, ensure_ascii=False))
    return {"pessoas": n, "segundos": total, "por_barbeiro": por, "outros_erros": outros,
            "tempos": sorted(r["seg"] for r in res)}


if __name__ == "__main__":
    modo = sys.argv[1] if len(sys.argv) > 1 else "seguranca"
    if modo == "seguranca":
        sys.exit(0 if seguranca() else 1)
    elif modo == "leitura":
        out = leitura(int(sys.argv[2]) if len(sys.argv) > 2 else 500, float(sys.argv[3]) if len(sys.argv) > 3 else 0)
        (ROOT / "tests/resultado_leitura.json").write_text(json.dumps(out, indent=1), encoding="utf-8")
    elif modo == "agendamento":
        out = agendamento(int(sys.argv[2]), sys.argv[3], sys.argv[4], float(sys.argv[5]) if len(sys.argv) > 5 else 0)
        (ROOT / "tests/resultado_agendamento.json").write_text(json.dumps(out, indent=1, ensure_ascii=False), encoding="utf-8")
