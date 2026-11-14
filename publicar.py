"""Publica o backend no Supabase (só Python padrão, sem instalar nada).

  python publicar.py                 aplica banco, login, funções, segredos e rotina; gera site/js/config.js
  python publicar.py admin EMAIL     dá acesso de administrador para a conta com esse e-mail
  python publicar.py sql ARQUIVO     roda um arquivo SQL no banco (manutenção)

Lê as chaves do arquivo .env (veja .env.example).
"""
import json
import secrets
import sys
import urllib.error
import urllib.request
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent
API = "https://api.supabase.com/v1"
FUNCTIONS = {  # nome: exige login?
    "criar-pix": True,
    "pix-status": True,
    "admin-senha": True,
    "excluir-conta": True,
    "admin-remover-cliente": True,
    "staff-criar-conta": True,
    "mp-webhook": False,   # chamado pelo Mercado Pago (valida assinatura)
    "worker": False,       # chamado pelo pg_cron (valida segredo)
}
SECRET_KEYS = ["SITE_URL", "PAYMENT_PROVIDER", "MP_ACCESS_TOKEN", "MP_WEBHOOK_SECRET", "WHATSAPP_PROVIDER", "WA_TOKEN",
               "WA_PHONE_NUMBER_ID", "WA_TEMPLATE_LANG", "WA_TEMPLATE_CONFIRMACAO", "WA_TEMPLATE_LEMBRETE",
               "WA_TEMPLATE_LISTA_ESPERA", "WA_TEMPLATE_REMARCADO", "WA_TEMPLATE_CANCELAMENTO", "WORKER_SECRET"]


def load_env() -> dict:
    env_file = ROOT / ".env"
    if not env_file.exists():
        sys.exit("Crie o arquivo .env (copie de .env.example) e preencha SUPABASE_ACCESS_TOKEN e SUPABASE_PROJECT_REF.")
    env = {}
    for line in env_file.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    for k in ("SUPABASE_ACCESS_TOKEN", "SUPABASE_PROJECT_REF", "SITE_URL"):
        if not env.get(k):
            sys.exit(f"Preencha {k} no .env")
    if not env.get("WORKER_SECRET"):
        env["WORKER_SECRET"] = secrets.token_urlsafe(32)
        with env_file.open("a", encoding="utf-8") as f:
            f.write(f"\n# Gerado automaticamente: segredo da rotina automática\nWORKER_SECRET={env['WORKER_SECRET']}\n")
    return env


ENV = load_env()
REF = ENV["SUPABASE_PROJECT_REF"]


def call(method: str, path: str, body=None, raw: bytes | None = None, content_type: str = "application/json"):
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(f"{API}{path}", data=data, method=method, headers={
        "Authorization": f"Bearer {ENV['SUPABASE_ACCESS_TOKEN']}",
        "Content-Type": content_type,
        "User-Agent": "magrao-publicar/1.0",
    })
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            text = r.read().decode()
            return json.loads(text) if text else None
    except urllib.error.HTTPError as e:
        sys.exit(f"Erro {e.code} em {method} {path}: {e.read().decode()[:800]}")


def sql(query: str):
    return call("POST", f"/projects/{REF}/database/query", {"query": query})


def esc(s: str) -> str:
    return s.replace("'", "''")


def migrations():
    sql("create schema if not exists ops; create table if not exists ops.migrations (name text primary key, applied_at timestamptz default now());"
        "revoke all on schema ops from anon, authenticated;")
    done = {r["name"] for r in sql("select name from ops.migrations")}
    if not done and sql("select to_regclass('public.settings') is not null as existe")[0]["existe"]:
        # Banco já criado por outro caminho (ex.: conexão do Claude): marca tudo como aplicado
        for f in sorted((ROOT / "supabase" / "migrations").glob("*.sql")):
            sql(f"insert into ops.migrations (name) values ('{esc(f.name)}') on conflict do nothing")
        done = {f.name for f in (ROOT / "supabase" / "migrations").glob("*.sql")}
    for f in sorted((ROOT / "supabase" / "migrations").glob("*.sql")):
        if f.name in done:
            continue
        print(f"  banco: aplicando {f.name}")
        sql(f.read_text(encoding="utf-8") + f"\ninsert into ops.migrations (name) values ('{esc(f.name)}');")
    site = ENV["SITE_URL"].split(",")[0].rstrip("/")
    sql(f"update public.settings set value = '{esc(site)}' where key = 'site_url';"
        f"update public.settings set value = '{esc(ENV.get('PAYMENT_PROVIDER', 'teste'))}' where key = 'payment_provider';")


def auth_config():
    site = ENV["SITE_URL"].split(",")[0].rstrip("/")
    allow = ",".join(f"{u.strip().rstrip('/')}/**" for u in ENV["SITE_URL"].split(","))
    cfg = {
        "site_url": site,
        "uri_allow_list": allow,
        "mailer_autoconfirm": True,          # sem e-mail de confirmação (o contato principal é o WhatsApp)
        "password_min_length": 8,
        "password_required_characters": "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ:0123456789",
        "external_phone_enabled": False,
        "mailer_secure_email_change_enabled": True,
        "security_refresh_token_reuse_interval": 10,
        "rate_limit_email_sent": 4,
        "jwt_exp": 3600,
    }
    if ENV.get("TURNSTILE_SECRET"):
        cfg.update(security_captcha_enabled=True, security_captcha_provider="turnstile", security_captcha_secret=ENV["TURNSTILE_SECRET"])
    if ENV.get("SMTP_HOST"):
        cfg.update(smtp_host=ENV["SMTP_HOST"], smtp_port=ENV.get("SMTP_PORT", "465"), smtp_user=ENV.get("SMTP_USER", ""),
                   smtp_pass=ENV.get("SMTP_PASS", ""), smtp_admin_email=ENV.get("SMTP_FROM", ""), smtp_sender_name="Magrão Barber Shop")
    call("PATCH", f"/projects/{REF}/config/auth", cfg)


def set_secrets():
    items = [{"name": k, "value": ENV[k]} for k in SECRET_KEYS if ENV.get(k)]
    call("POST", f"/projects/{REF}/secrets", items)


def deploy_function(name: str, verify_jwt: bool):
    base = ROOT / "supabase" / "functions"
    files = [base / name / "index.ts", *sorted((base / "_shared").glob("*.ts"))]
    boundary = uuid.uuid4().hex
    parts = []
    meta = {"name": name, "entrypoint_path": f"{name}/index.ts", "verify_jwt": verify_jwt}
    parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="metadata"\r\n\r\n{json.dumps(meta)}\r\n'.encode())
    for f in files:
        rel = f.relative_to(base).as_posix()
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{rel}"\r\n'
                     f'Content-Type: application/typescript\r\n\r\n'.encode() + f.read_bytes() + b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode())
    call("POST", f"/projects/{REF}/functions/deploy?slug={name}", raw=b"".join(parts),
         content_type=f"multipart/form-data; boundary={boundary}")


def cron():
    url = f"https://{REF}.supabase.co/functions/v1/worker"
    sql(f"""
      create extension if not exists pg_cron with schema pg_catalog;
      create extension if not exists pg_net with schema extensions;
      delete from vault.secrets where name = 'worker_secret';
      select vault.create_secret('{esc(ENV['WORKER_SECRET'])}', 'worker_secret');
      select cron.unschedule(jobname) from cron.job where jobname in ('magrao-tick', 'magrao-worker');
      select cron.schedule('magrao-tick', '* * * * *', $$ select public.tick() $$);
      select cron.schedule('magrao-worker', '* * * * *', $job$
        select net.http_post(
          url := '{url}',
          headers := jsonb_build_object('Content-Type', 'application/json', 'x-worker-secret',
                     (select decrypted_secret from vault.decrypted_secrets where name = 'worker_secret')),
          body := '{{}}'::jsonb)
        where exists (select 1 from public.messages where status = 'pendente')
           or exists (select 1 from public.bookings where refund_status = 'pendente')
      $job$);
    """)


def write_config():
    keys = call("GET", f"/projects/{REF}/api-keys?reveal=false")
    anon = next((k["api_key"] for k in keys if k.get("name") == "anon"), None)
    if not anon:
        sys.exit("Não achei a chave anon do projeto.")
    cfg = {
        "SUPABASE_URL": f"https://{REF}.supabase.co",
        "SUPABASE_ANON_KEY": anon,
        "TURNSTILE_SITE_KEY": ENV.get("TURNSTILE_SITE_KEY", ""),
        "WHATSAPP": ENV.get("WHATSAPP_BARBEARIA", "5519984094568"),
    }
    (ROOT / "site" / "js" / "config.js").write_text(
        "// Gerado pelo script de publicação (publicar.py). Estas chaves são públicas por natureza:\n"
        "// a segurança dos dados fica nas regras do banco (RLS), não em esconder estas chaves.\n"
        f"window.APP_CONFIG = {json.dumps(cfg, indent=2)};\n", encoding="utf-8")


def publish():
    print("1/6 Banco de dados e regras");      migrations()
    print("2/6 Login (Supabase Auth)");        auth_config()
    print("3/6 Segredos das funções");          set_secrets()
    print("4/6 Funções");
    for name, jwt in FUNCTIONS.items():
        print(f"  função: {name}")
        deploy_function(name, jwt)
    print("5/6 Rotina automática (a cada minuto)"); cron()
    print("6/6 Configuração do site");          write_config()
    print("\nPronto. Agora publique a pasta site/ no Cloudflare Pages.")


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        publish()
    elif args[0] == "admin" and len(args) == 2:
        r = sql(f"update public.profiles set role = 'admin' where id = (select id from auth.users where lower(email) = lower('{esc(args[1])}')) returning name")
        print(f"Administrador: {r[0]['name']}" if r else "Nenhuma conta com esse e-mail. Crie a conta no site primeiro.")
    elif args[0] == "sql" and len(args) == 2:
        print(json.dumps(sql(Path(args[1]).read_text(encoding="utf-8")), indent=2, ensure_ascii=False))
    else:
        print(__doc__)
