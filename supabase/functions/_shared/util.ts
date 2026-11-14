// Utilitários comuns das funções (sem dependências externas)

export const env = (k: string, fallback = "") => Deno.env.get(k) ?? fallback;

const SUPABASE_URL = env("SUPABASE_URL");
const ANON_KEY = env("SUPABASE_ANON_KEY");
const SERVICE_KEY = env("SUPABASE_SERVICE_ROLE_KEY");
export class HttpError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

// Endereços que podem chamar as funções pelo navegador: segredo SITE_URL ou, se não houver,
// a configuração "allowed_origins" do banco (lida uma vez por instância)
let originsCache: string[] | null = null;
async function allowedOrigins(): Promise<string[]> {
  if (originsCache) return originsCache;
  const fromEnv = env("SITE_URL");
  if (fromEnv) return (originsCache = fromEnv.split(",").map((s) => s.trim()).filter(Boolean));
  try {
    const rows = await rest("settings?key=eq.allowed_origins&select=value");
    originsCache = String(rows?.[0]?.value ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  } catch {
    originsCache = [];
  }
  return originsCache;
}

export async function corsHeaders(req: Request): Promise<Record<string, string>> {
  const origin = req.headers.get("origin") ?? "";
  const allowed = await allowedOrigins();
  return {
    "Access-Control-Allow-Origin": allowed.includes(origin) ? origin : (allowed[0] ?? ""),
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

export async function reply(req: Request, body: unknown, status = 200): Promise<Response> {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...(await corsHeaders(req)), "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

/** Envolve o handler: CORS, erros padronizados e nenhum detalhe interno vazando para o cliente. */
export function handler(fn: (req: Request) => Promise<unknown>) {
  return async (req: Request) => {
    if (req.method === "OPTIONS") return new Response(null, { headers: await corsHeaders(req) });
    if (req.method !== "POST") return reply(req, { message: "Método não permitido" }, 405);
    try {
      return reply(req, await fn(req));
    } catch (e) {
      if (e instanceof HttpError) return reply(req, { message: e.message }, e.status);
      console.error(e);
      return reply(req, { message: "Erro interno. Tente de novo em instantes." }, 500);
    }
  };
}

type RestOpts = { method?: string; body?: unknown; token?: string; prefer?: string };

/** Chamada ao banco (PostgREST). Sem token = chave de serviço (ignora RLS: use só no servidor). */
export async function rest(path: string, { method = "GET", body, token, prefer }: RestOpts = {}) {
  const headers: Record<string, string> = {
    apikey: token ? ANON_KEY : SERVICE_KEY,
    Authorization: `Bearer ${token ?? SERVICE_KEY}`,
    "Content-Type": "application/json",
  };
  if (prefer) headers.Prefer = prefer;
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, { method, headers, body: body ? JSON.stringify(body) : undefined });
  const text = await r.text();
  const data = text ? JSON.parse(text) : null;
  if (!r.ok) {
    const status = r.status >= 400 && r.status < 500 ? r.status : 500;
    throw new HttpError(status, data?.message ?? "Erro no banco");
  }
  return data;
}

export const rpc = (fn: string, args: Record<string, unknown> = {}, token?: string) =>
  rest(`rpc/${fn}`, { method: "POST", body: args, token });

export function bearer(req: Request): string {
  const h = req.headers.get("authorization") ?? "";
  if (!h.startsWith("Bearer ")) throw new HttpError(401, "Entre na sua conta para continuar.");
  return h.slice(7);
}

/** Confere o login do usuário direto no Supabase Auth. */
export async function getUser(req: Request): Promise<{ id: string; email: string; token: string }> {
  const token = bearer(req);
  const r = await fetch(`${SUPABASE_URL}/auth/v1/user`, { headers: { apikey: ANON_KEY, Authorization: `Bearer ${token}` } });
  if (!r.ok) throw new HttpError(401, "Sua sessão expirou. Entre de novo.");
  const u = await r.json();
  return { id: u.id, email: u.email, token };
}

export async function authAdmin(path: string, method: string, body?: unknown) {
  const r = await fetch(`${SUPABASE_URL}/auth/v1/admin/${path}`, {
    method,
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!r.ok) throw new Error(`auth admin ${r.status}: ${await r.text()}`);
  return r.status === 204 ? null : r.json();
}

export async function readJson(req: Request): Promise<Record<string, unknown>> {
  try {
    const b = await req.json();
    return b && typeof b === "object" ? b : {};
  } catch {
    throw new HttpError(400, "Pedido inválido.");
  }
}

export function positiveInt(v: unknown, name: string): number {
  const n = Number(v);
  if (!Number.isInteger(n) || n <= 0) throw new HttpError(400, `${name} inválido.`);
  return n;
}

export function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
