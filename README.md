# Magrão Barber Shop: site e sistema de agendamento

Site com agendamento online feito para uma barbearia de Artur Nogueira (SP).
O cliente marca o horário pelo celular; a equipe gerencia agenda, caixa e comissões por um painel.

🌐 **No ar:** [magrãobarbershop.com.br](https://xn--magrobarbershop-nkb.com.br)

## O que o sistema faz

**Para o cliente**
- Agendamento em poucos passos: serviço → barbeiro → dia e horário → confirmação
- Vários serviços no mesmo horário e corte do filho junto
- Lista de espera para dias lotados
- Área "Minha conta": ver, cancelar e confirmar presença, editar dados e excluir a conta
- Pagamento na barbearia ou online (cartão e Pix), pronto para ligar

**Para a equipe**
- Agenda do dia, encaixes, bloqueio de horários e remanejamento de clientes
- Caixa, comissões, pacotes e promoções
- Cada barbeiro vê só a própria agenda; o administrador vê tudo
- Aviso no celular a cada novo agendamento, mesmo com o painel fechado (PWA + Web Push)

## Como foi feito

| Parte | Tecnologia | Pasta |
|---|---|---|
| Site | HTML, CSS e JavaScript puro, mobile first, hospedado no Cloudflare | `site/` |
| Banco e regras de negócio | Supabase: PostgreSQL, Auth e Row Level Security | `supabase/migrations/` |
| Pagamentos, mensagens e tarefas do servidor | Supabase Edge Functions (Deno/TypeScript) | `supabase/functions/` |
| Rotinas automáticas (lembretes, fila de mensagens) | pg_cron | `supabase/migrations/` |
| Testes | Regras do banco em SQL e teste de carga em Python | `tests/` |

## Páginas

| Endereço | Para quem | O que faz |
|---|---|---|
| `/` | todos | Preços, barbeiros, produtos, horários e mapa |
| `/agendar.html` | cliente | Fluxo de agendamento |
| `/conta.html` | cliente | Horários, lista de espera, dados e senha |
| `/confirmar.html` | cliente | Confirmar presença pelo link recebido |
| `/painel.html` | equipe | Agenda, clientes, caixa, comissões e configurações |
| `/privacidade.html` | todos | Política de privacidade (LGPD) |

## Segurança

- **RLS em todas as tabelas**: o navegador não escreve direto em nenhuma tabela. Toda ação passa por funções do banco que conferem quem está pedindo.
- Cliente só vê os próprios dados; barbeiro só vê a própria agenda; ninguém consegue se dar acesso de administrador.
- Dados da equipe (telefone, comissão) fora da API pública.
- Dois clientes nunca pegam o mesmo horário (trava na agenda e regra no banco contra horários sobrepostos).
- Link de confirmação com código aleatório; não mostra telefone nem sobrenome.
- Chaves secretas só nos segredos do servidor ou no Vault do banco, nunca no site. O `.env` não vai para o git.
- Cabeçalhos de segurança (`site/_headers`): CSP sem scripts inline, HSTS, proteção contra iframe.
- Webhooks de pagamento validados por assinatura ou conferidos direto no provedor.
- Captcha (Cloudflare Turnstile) no cadastro e no login.
- Senha com no mínimo 8 caracteres, letras e números; o site recusa senhas muito usadas em vazamentos e senhas com o nome, e-mail ou telefone da pessoa.
- Área sensível do painel com senha própria (hash bcrypt) e bloqueio após 5 tentativas erradas.
- LGPD: aceite da política no cadastro, edição de dados e exclusão da conta pelo próprio cliente.

## Rodar o site localmente

```bash
python -m http.server 8080 --directory site
```

Para um backend próprio, copie `.env.example` para `.env`, preencha com as chaves do seu projeto Supabase e rode `python publicar.py`.

---

Desenvolvido por [Gabriel Conceição](https://github.com/gabiteuss).
