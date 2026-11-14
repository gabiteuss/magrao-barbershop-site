// Administrador gera uma senha provisória para o cliente que esqueceu a dele
import { authAdmin, getUser, handler, HttpError, readJson, rpc } from "../_shared/util.ts";

Deno.serve(handler(async (req) => {
  const user = await getUser(req);
  if ((await rpc("is_admin", {}, user.token)) !== true) throw new HttpError(403, "Acesso só para o administrador.");
  const target = String((await readJson(req)).user_id ?? "");
  if (!/^[0-9a-f-]{36}$/.test(target)) throw new HttpError(400, "Cliente inválido.");

  const alphabet = "abcdefghjkmnpqrstuvwxyz23456789";
  const bytes = crypto.getRandomValues(new Uint8Array(10));
  const temp = [...bytes].map((b) => alphabet[b % alphabet.length]).join("");
  await authAdmin(`users/${target}`, "PUT", { password: temp });
  return { temp_password: temp };
}));
