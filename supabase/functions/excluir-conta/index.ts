// O próprio cliente apaga a conta e os dados pessoais (LGPD)
import { authAdmin, getUser, handler, HttpError, rest } from "../_shared/util.ts";

Deno.serve(handler(async (req) => {
  const user = await getUser(req);
  const ativos = await rest(`bookings?user_id=eq.${user.id}&status=in.(pendente,confirmado)&select=id`, { token: user.token });
  if (ativos.length) throw new HttpError(400, "Cancele seus horários marcados antes de excluir a conta.");
  const [p] = await rest(`profiles?id=eq.${user.id}&select=role,phone`);
  if (p?.role !== "client") throw new HttpError(400, "Contas da equipe são removidas pelo administrador.");
  // Perfil, agendamentos e lista de espera saem em cascata; o histórico de mensagens sai aqui
  await rest(`messages?to_phone=eq.${p.phone}`, { method: "DELETE" });
  await authAdmin(`users/${user.id}`, "DELETE");
  return { ok: true };
}));
