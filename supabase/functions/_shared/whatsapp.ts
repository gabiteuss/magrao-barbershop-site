// Envio de WhatsApp pelo número da barbearia.
//   "console"   só registra no painel (sem WhatsApp ligado)
//   "360dialog" parceiro oficial da Meta com coexistência: o mesmo número segue funcionando no app
//               WhatsApp Business do celular do Magrão (ele vê e responde tudo por lá)
//   "meta"      WhatsApp Cloud API direto da Meta (sem coexistência)
// Os dois últimos usam o mesmo formato de mensagem da Cloud API, com modelos aprovados.
import { env } from "./util.ts";

export const PROVIDER = env("WHATSAPP_PROVIDER", "console");

// Nome do modelo aprovado na Meta para cada tipo de mensagem (mesmos parâmetros, na mesma ordem).
// Textos e categorias em docs/modelos-whatsapp.md
const TEMPLATES: Record<string, string> = {
  confirmacao: env("WA_TEMPLATE_CONFIRMACAO", "agendamento_confirmado"),
  lembrete: env("WA_TEMPLATE_LEMBRETE", "lembrete_horario"),
  lista_espera: env("WA_TEMPLATE_LISTA_ESPERA", "vaga_lista_espera"),
  remarcado: env("WA_TEMPLATE_REMARCADO", "horario_remarcado"),
  cancelamento: env("WA_TEMPLATE_CANCELAMENTO", "horario_cancelado"),
  confirmar_presenca: env("WA_TEMPLATE_CONFIRMAR", "confirmar_presenca"),
  aniversario: env("WA_TEMPLATE_ANIVERSARIO", "feliz_aniversario"),
  novo_agendamento: env("WA_TEMPLATE_NOVO_AGENDAMENTO", "novo_agendamento"),
};

function endpoint(): { url: string; headers: Record<string, string> } {
  const token = env("WA_TOKEN");
  if (!token) throw new Error("WA_TOKEN não configurado");
  if (PROVIDER === "360dialog") {
    return {
      url: env("WA_API_URL", "https://waba-v2.360dialog.io/messages"),
      headers: { "D360-API-KEY": token, "Content-Type": "application/json" },
    };
  }
  const numberId = env("WA_PHONE_NUMBER_ID");
  if (!numberId) throw new Error("WA_PHONE_NUMBER_ID não configurado");
  return {
    url: `https://graph.facebook.com/v21.0/${numberId}/messages`,
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
  };
}

export async function sendTemplate(phone: string, kind: string, params: string[]): Promise<void> {
  const template = TEMPLATES[kind];
  if (!template) throw new Error(`Sem modelo para ${kind}`);
  const { url, headers } = endpoint();
  const r = await fetch(url, {
    method: "POST",
    headers,
    body: JSON.stringify({
      messaging_product: "whatsapp",
      recipient_type: "individual",
      to: phone,
      type: "template",
      template: {
        name: template,
        language: { code: env("WA_TEMPLATE_LANG", "pt_BR") },
        components: [{ type: "body", parameters: params.map((text) => ({ type: "text", text: String(text).slice(0, 900) })) }],
      },
    }),
  });
  if (!r.ok) throw new Error(`${r.status}: ${(await r.text()).slice(0, 300)}`);
}
