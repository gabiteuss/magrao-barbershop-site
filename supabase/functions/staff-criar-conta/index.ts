// Barbeiro/administrador cria a conta no site para um cliente do balcão ou de encaixe.
// O banco (staff_client_for_account) confere a permissão e devolve nome e WhatsApp do cadastro do balcão;
// ao criar o login, o gatilho handle_new_user faz a conta assumir esse cadastro (histórico, filhos, pacotes).
import { authAdmin, getUser, handler, HttpError, readJson, rpc } from "../_shared/util.ts";

Deno.serve(handler(async (req) => {
  const user = await getUser(req);
  const body = await readJson(req);
  const target = String(body.user_id ?? "");
  const email = String(body.email ?? "").trim().toLowerCase();
  if (!/^[0-9a-f-]{36}$/.test(target)) throw new HttpError(400, "Cliente inválido.");
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 120) throw new HttpError(400, "Digite um e-mail válido.");

  const c = await rpc("staff_client_for_account", { p_user: target }, user.token);

  const alphabet = "abcdefghjkmnpqrstuvwxyz23456789";
  const bytes = crypto.getRandomValues(new Uint8Array(10));
  const temp = [...bytes].map((b) => alphabet[b % alphabet.length]).join("");
  try {
    await authAdmin("users", "POST", {
      email, password: temp, email_confirm: true,
      user_metadata: { name: c.name, phone: c.phone, birth_date: c.birth_date ?? "", privacy: "false" },
    });
  } catch (e) {
    const msg = String((e as Error).message);
    if (/already|exists|registered/i.test(msg)) throw new HttpError(400, "Esse e-mail já tem conta no site.");
    throw e;
  }
  return { temp_password: temp, email };
}));
