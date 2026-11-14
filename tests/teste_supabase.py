"""Teste de ponta a ponta no Supabase publicado: fluxo de agendamento + segurança (RLS).

Rodar depois do publicar.py (com PAYMENT_PROVIDER=teste):  python tests/teste_supabase.py
Cria duas contas de teste e apaga tudo no final.
"""
import json
import re
import secrets
import sys
import urllib.error
import urllib.request
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import publicar  # noqa: E402  (reaproveita o acesso ao banco pela API de gerenciamento)

cfg = json.loads(re.search(r"APP_CONFIG = (\{.*\});", (ROOT / "site/js/config.js").read_text(encoding="utf-8"), re.S).group(1))
URL, ANON = cfg["SUPABASE_URL"], cfg["SUPABASE_ANON_KEY"]
falhas = []


def req(method, path, body=None, token=None):
    r = urllib.request.Request(f"{URL}{path}", method=method, data=json.dumps(body).encode() if body is not None else None,
                               headers={"apikey": ANON, "Authorization": f"Bearer {token or ANON}", "Content-Type": "application/json",
                                        "Origin": "http://localhost:8080"})
    try:
        with urllib.request.urlopen(r, timeout=60) as resp:
            t = resp.read().decode()
            return resp.status, (json.loads(t) if t else None)
    except urllib.error.HTTPError as e:
        t = e.read().decode()
        try:
            return e.code, json.loads(t)
        except ValueError:
            return e.code, t


def rpc(fn, args=None, token=None):
    return req("POST", f"/rest/v1/rpc/{fn}", args or {}, token)


def check(nome, cond, detalhe=""):
    print(("  OK   " if cond else "  FALHA ") + nome + ("" if cond else f"  -> {detalhe}"))
    if not cond:
        falhas.append(nome)


def signup(nome, fone):
    email = f"teste.{secrets.token_hex(4)}@magraobarbershop.com.br"
    st, d = req("POST", "/auth/v1/signup", {"email": email, "password": "Teste1234",
                                             "data": {"name": nome, "phone": fone, "privacy": "true"}})
    assert st == 200 and d.get("access_token"), (st, d)
    return email, d["access_token"], d["user"]["id"]


usuarios = []
try:
    print("Visitante sem login")
    st, pub = rpc("public_info")
    check("vê serviços e barbeiros", st == 200 and len(pub["services"]) > 0, pub)
    st, d = req("GET", "/rest/v1/profiles?select=*")
    check("não vê perfis", st in (401, 403) or d == [], (st, d))
    st, d = req("GET", "/rest/v1/bookings?select=*")
    check("não vê agendamentos", st in (401, 403) or d == [], (st, d))
    st, d = req("GET", "/rest/v1/messages?select=*")
    check("não vê mensagens", st in (401, 403) or d == [], (st, d))
    st, d = rpc("create_booking", {"p_service": 1, "p_date": "2030-01-01", "p_time": "10:00"})
    check("não agenda sem conta", st == 401, (st, d))
    st, d = rpc("confirm_payment", {"p_booking": 1})
    check("não confirma pagamento", st in (401, 403, 404), (st, d))

    print("Cadastro")
    a_email, A, a_id = signup("Cliente A Teste", "(19) 90000-1111")
    b_email, B, b_id = signup("Cliente B Teste", "(19) 90000-2222")
    usuarios += [a_id, b_id]
    st, d = req("POST", "/auth/v1/signup", {"email": f"x{secrets.token_hex(3)}@magraobarbershop.com.br", "password": "Teste1234",
                                            "data": {"name": "Dup", "phone": "19900001111", "privacy": "true"}})
    check("WhatsApp repetido é recusado", st >= 400, (st, d))
    if st == 200 and d.get("user"):
        usuarios.append(d["user"]["id"])
    st, me = rpc("my_profile", token=A)
    check("perfil criado com telefone normalizado", st == 200 and me["phone"] == "5519900001111", me)

    print("Escalada de privilégio")
    st, d = req("PATCH", f"/rest/v1/profiles?id=eq.{a_id}", {"role": "admin"}, A)
    st2, me = rpc("my_profile", token=A)
    check("cliente não vira admin pela API", me["role"] == "client", (st, d))
    st, d = rpc("admin_set_role", {"p_user": a_id, "p_role": "admin"}, A)
    check("cliente não chama função de admin", st == 403, (st, d))
    st, d = rpc("admin_agenda", {"p_date": str(date.today())}, A)
    check("cliente não vê agenda da equipe", st == 403, (st, d))

    print("Agendamento")
    svc = pub["services"][0]
    st, dias = rpc("available_days", {"p_service": svc["id"]})
    dia = next(x for x in dias if x["free"])["date"]
    st, slots = rpc("availability", {"p_service": svc["id"], "p_day": dia})
    hora = slots[0]["time"]
    st, bk = rpc("create_booking", {"p_service": svc["id"], "p_date": dia, "p_time": hora}, A)
    check("A agenda", st == 200 and bk["status"] == "pendente", (st, bk))
    st, d = rpc("create_booking", {"p_service": svc["id"], "p_date": dia, "p_time": hora}, B)
    check("B não pega o mesmo horário", st == 409, (st, d))
    st, d = req("GET", f"/rest/v1/bookings?id=eq.{bk['id']}&select=*", token=B)
    check("B não vê o agendamento de A", d == [], d)
    st, d = rpc("booking_status", {"p_id": bk["id"]}, B)
    check("B não consulta o agendamento de A", st == 404, (st, d))
    st, d = req("PATCH", f"/rest/v1/bookings?id=eq.{bk['id']}", {"status": "confirmado"}, A)
    st2, bk2 = rpc("booking_status", {"p_id": bk["id"]}, A)
    check("A não confirma sozinho pela API", bk2["status"] == "pendente", (st, d))
    st, w = rpc("join_waitlist", {"p_service": svc["id"], "p_date": dia}, B)
    check("B entra na lista de espera", st == 200, (st, w))

    print("Pix (modo teste)")
    st, pix = req("POST", "/functions/v1/criar-pix", {"booking_id": bk["id"]}, A)
    check("gera Pix", st == 200 and pix.get("pix_code"), (st, pix))
    st, d = req("POST", "/functions/v1/pix-status", {"booking_id": bk["id"], "simular": True}, B)
    check("B não paga/consulta Pix de A", st == 404, (st, d))
    st, d = req("POST", "/functions/v1/pix-status", {"booking_id": bk["id"], "simular": True}, A)
    check("pagamento confirma", st == 200 and d["status"] == "confirmado", (st, d))
    msgs = publicar.sql("select kind from public.messages where to_phone = '5519900001111'")
    check("mensagem de confirmação na fila", any(m["kind"] == "confirmacao" for m in msgs), msgs)
    st, d = req("POST", "/functions/v1/worker", {}, A)
    check("rotina recusa chamada sem segredo", st in (401, 403), (st, d))

    print("Remanejar (dono)")
    publicar.sql(f"update public.profiles set role = 'admin' where id = '{a_id}'")
    st, load = rpc("admin_day_load", {"p_from": str(date.today()), "p_days": 14}, A)
    check("ocupação dos dias", st == 200 and len(load) == 14, (st, load))
    alvo = next(x for x in dias if x["free"] and x["date"] != dia)["date"]
    st, livres = rpc("admin_move_slots", {"p_id": bk["id"], "p_date": alvo, "p_barber": bk["barber_id"]}, A)
    st, mv = rpc("admin_move_booking", {"p_id": bk["id"], "p_date": alvo, "p_time": livres[0], "p_barber": bk["barber_id"]}, A)
    check("move para outro dia", st == 200 and mv["moved_by_shop"], (st, mv))
    msgs = publicar.sql("select kind, body from public.messages order by id")
    check("cliente avisado da mudança", any(m["kind"] == "remarcado" for m in msgs), msgs[-3:])
    check("lista de espera avisada da vaga", any(m["kind"] == "lista_espera" for m in msgs), msgs[-3:])
    publicar.sql(f"update public.profiles set role = 'client' where id = '{a_id}'")

    print("Cancelamento")
    st, c = rpc("cancel_booking", {"p_id": bk["id"]}, A)
    check("remanejado pela barbearia: cancela com devolução", st == 200 and c["refund"], (st, c))

    print("Rotina automática")
    publicar.sql("select public.tick()")
    check("tick roda sem erro", True)
finally:
    if usuarios:
        ids = ",".join(f"'{u}'" for u in usuarios)
        publicar.sql(f"delete from public.messages where to_phone in ('5519900001111','5519900002222');"
                     f"delete from auth.users where id in ({ids});")
        print("Contas de teste apagadas.")

print("\n" + ("TUDO OK" if not falhas else f"{len(falhas)} FALHA(S): " + "; ".join(falhas)))
sys.exit(1 if falhas else 0)
