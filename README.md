# Clínica · painel de atendimento

Aplicação web da clínica: login único para equipe e pacientes, painel de botões por perfil, agenda compartilhada (Google Agenda), cadastro de pacientes e ficha clínica separada por especialidade, com anamnese e histórico de atendimentos. Mesmo modelo do Diagnóstico OQGCI: arquivo único, publicado no GitHub Pages, com login e banco no Supabase.

## O que já funciona

| Área | Quem vê | O que faz |
| --- | --- | --- |
| Entrada | Todos | Login com e-mail e senha, criação de acesso e recuperação de senha |
| Painel | Todos | Botões das áreas internas e atalhos externos, conforme o perfil. Atalhos abrem em nova aba; o painel continua aberto na aba original |
| Agenda | Equipe | Agenda própria por sala: visão por dia ou semana, de todos ou por sala, profissional e paciente. Bloqueia conflito de sala e de profissional e respeita o horário de cada sala. Situações: agendada, confirmada, realizada, faltou e cancelada. Google Agenda opcional para consulta |
| Minhas consultas | Paciente | Próximas consultas e histórico, com sala e profissional |
| Financeiro | Mestre e administradores | Resumo do mês (recebido, a receber, pago, a pagar e resultado), contas a receber e a pagar com vencimentos e atrasos, cobrança automática da consulta realizada, pacotes de sessões, acordo por profissional (quem recebe, valor da consulta, repasse mensal fixo ou aluguel de sala por hora), gastos recorrentes e recibo para o paciente |
| Pacientes | Equipe | Lista com busca, cadastro e edição |
| Ficha do paciente | Profissionais com permissão | Uma aba por especialidade: anamnese (campos comuns + campos próprios da especialidade) e atendimentos (data, tipo, evolução e conduta) |
| Meus dados | Paciente | O próprio cadastro |
| Administração | Mestre e administradores | Usuários e permissões, salas e horários, especialidades, atalhos, nome da clínica, dados do recibo, Google Agenda, auditoria e demonstração com dados de exemplo |

## Perfis

| Perfil | Acesso |
| --- | --- |
| Administrador mestre | Tudo o que o administrador faz, e é o único que cria ou altera administradores |
| Administrador | Libera contas, define perfis e permissões, especialidades, atalhos e agenda |
| Profissional | Agenda (vê a de todos e marca na própria), pacientes e as fichas das especialidades liberadas, em leitura ou em leitura e escrita |
| Recepção | Agenda (marca para qualquer profissional) e cadastro de pacientes, sem acesso às fichas clínicas |
| Paciente | Os próprios dados e os atalhos destinados a pacientes |
| Aguardando liberação | Nenhum, até a administração definir o perfil |

Regras de proteção dos dados de saúde (LGPD):
- Ficha clínica só abre para quem tem permissão na especialidade, inclusive para administradores. O mestre concede a si mesmo as permissões das especialidades em que atende.
- Atendimento só é alterado por quem o registrou. A aplicação não apaga prontuário.
- Cadastros, consultas e alterações de ficha e mudanças de acesso ficam na Auditoria.
- As regras valem no banco (RLS do Supabase), independentemente da tela.

## Como cada pessoa entra

- **Equipe:** cria o acesso em **Criar acesso**. A conta fica aguardando liberação até um administrador definir o perfil em Administração > Usuários.
- **Paciente:** a recepção cadastra o paciente com o e-mail dele. O paciente cria o acesso com esse mesmo e-mail e entra direto na área dele. Se a conta for criada antes do cadastro, o vínculo acontece quando o e-mail for cadastrado na ficha.

## Estrutura

| Pasta ou arquivo | Conteúdo |
| --- | --- |
| `src/app.html` | Código da aplicação (fonte única) |
| `build.py` | Gera `public/index.html` e a prévia a partir de `src/app.html` |
| `public/` | O site publicado pelo GitHub Pages |
| `public/config.js` | Endereço e chave pública do Supabase. Vazio = modo demonstração |
| `supabase/schema.sql` | Tabelas, regras de acesso, funções e auditoria |
| `.github/workflows/pages.yml` | Publicação automática no GitHub Pages a cada envio ao ramo `main` |

## Publicação gratuita, passo a passo

### 1. Repositório no GitHub
1. Crie um repositório novo (por exemplo, `clinica`). Para um sistema com dados de saúde, prefira **privado**. O GitHub Pages em repositório privado exige plano pago do GitHub; no plano gratuito, o repositório precisa ser público. O código público não expõe dados: eles ficam no Supabase, protegidos pelas regras de acesso.
2. Envie todos os arquivos desta pasta.

### 2. Supabase (login e banco)
1. Crie um projeto novo em supabase.com, região South America (São Paulo). Use um projeto separado do OQGCI.
2. Abra **SQL Editor > New query**, cole o conteúdo de `supabase/schema.sql` e clique em **Run**.
3. Em **Project Settings > API**, copie o **Project URL** e a chave **anon public** (ou **publishable**).
4. Em **Authentication > URL Configuration**, preencha **Site URL** com o endereço do site (passo 3) e adicione o mesmo endereço em **Redirect URLs**.

### 3. GitHub Pages
1. No repositório, abra **Settings > Pages** e escolha **GitHub Actions** como fonte.
2. O fluxo `.github/workflows/pages.yml` publica a pasta `public` a cada envio ao ramo `main`.

### 4. Ligar os dois
1. Preencha `public/config.js` com o Project URL e a chave pública.
2. Entre no site, use **Criar acesso** e crie a sua conta.
3. No SQL Editor do Supabase, rode, com o seu e-mail:
   `update public.perfis set papel = 'mestre' where email = 'seu-email';`
4. Entre de novo: o botão **Administração** aparece no painel.

### 5. Primeiros ajustes no painel
1. **Configurações:** nome da clínica e código de incorporação do Google Agenda.
2. **Especialidades:** cadastre as especialidades e os campos próprios de anamnese de cada uma.
3. **Usuários:** libere a equipe, defina perfis e as permissões por especialidade (inclusive as suas).
4. **Atalhos:** cadastre os botões externos, como a Rede Ayla, e escolha quem vê cada um.

## Atualizações do banco
Projetos criados com o `schema.sql` atual já têm tudo. Em projetos antigos, rode no SQL Editor, uma vez:
- `supabase/atualizacao-01-agenda.sql` · salas, agendamentos e consultas do paciente (já aplicada no projeto da clínica)
- `supabase/atualizacao-02-financeiro.sql` · financeiro: lançamentos, pacotes, acordos por profissional e recorrentes (já aplicada no projeto da clínica)

## Observações
- A chave pública pode ficar no site: o acesso aos dados é protegido pelas regras de RLS do `schema.sql`.
- No plano gratuito do Supabase, o projeto pode pausar após um período sem uso. Ele é reativado pelo painel do Supabase.
- Para alterar a aplicação, edite `src/app.html` e rode `python3 build.py`.
- Agenda: os eventos aparecem para quem estiver conectado ao Google com uma conta que tenha acesso à agenda. Compartilhe a agenda da clínica no Google com o e-mail de cada pessoa da equipe.
