// Administrador remove um cliente. O WhatsApp e o e-mail ficam livres para um novo cadastro.
// O banco (admin_remove_client) confere as regras e guarda o histórico; aqui só apagamos o login.
import { authAdmin, getUser, handler, HttpError, readJson, rpc } from "../_shared/util.ts";

Deno.serve(handler(async (req) => {
  const user = await getUser(req);
  if ((await rpc("is_admin", {}, user.token)) !== true) throw new HttpError(403, "Acesso só para o administrador.");
  const target = String((await readJson(req)).user_id ?? "");
  if (!/^[0-9a-f-]{36}$/.test(target)) throw new HttpError(400, "Cliente inválido.");
  if (target === user.id) throw new HttpError(400, "Você não pode remover a sua própria conta.");

  const r = await rpc("admin_remove_client", { p_user: target }, user.token);
  // Login apagado => perfil apagado pelo gatilho (o histórico já foi para "Cliente avulso")
  if (r?.has_login) await authAdmin(`users/${target}`, "DELETE");
  return { ok: true };
}));
