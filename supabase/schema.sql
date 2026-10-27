-- Clínica · banco de dados (Supabase)
-- Rode uma vez no SQL Editor do Supabase: New query > colar este arquivo inteiro > Run.
--
-- Perfis de acesso
--   mestre       administrador mestre: tudo o que o administrador faz, mais definir administradores
--   admin        administrador: libera usuários, define permissões, especialidades, atalhos e agenda
--   profissional profissional da clínica: pacientes e fichas das especialidades liberadas
--   recepcao     recepção: agenda e cadastro de pacientes, sem acesso às fichas clínicas
--   paciente     paciente: vê os próprios dados
--   pendente     conta criada, aguardando liberação
--
-- Fichas clínicas (anamnese e atendimentos) só abrem para quem tem permissão na especialidade,
-- inclusive para administradores: o acesso clínico é sempre concedido de forma explícita.
-- Prontuário não se apaga pela aplicação. Toda criação e alteração de ficha fica na auditoria.

-- 1. Tabelas ------------------------------------------------------------------------

create table if not exists public.perfis (
  id uuid primary key references auth.users (id) on delete cascade,
  nome text not null default '',
  email text not null default '',
  papel text not null default 'pendente'
    check (papel in ('mestre', 'admin', 'profissional', 'recepcao', 'paciente', 'pendente')),
  ativo boolean not null default true,
  registro_profissional text,
  created_at timestamptz not null default now()
);

create table if not exists public.especialidades (
  id uuid primary key default gen_random_uuid(),
  nome text not null unique,
  cor text not null default '#3E7C6E',
  campos jsonb not null default '[]'::jsonb,   -- campos adicionais da anamnese desta especialidade
  ativa boolean not null default true,
  ordem integer not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.permissoes (
  user_id uuid not null references public.perfis (id) on delete cascade,
  especialidade_id uuid not null references public.especialidades (id) on delete cascade,
  nivel text not null check (nivel in ('leitura', 'escrita')),
  primary key (user_id, especialidade_id)
);

create table if not exists public.pacientes (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  nascimento date,
  cpf text,
  telefone text,
  email text,
  endereco text,
  contato_emergencia text,
  observacoes text,
  user_id uuid unique references public.perfis (id) on delete set null,
  ativo boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid(),
  updated_at timestamptz not null default now()
);
create unique index if not exists pacientes_email_unico on public.pacientes (lower(email)) where email is not null and email <> '';

create table if not exists public.anamneses (
  id uuid primary key default gen_random_uuid(),
  paciente_id uuid not null references public.pacientes (id) on delete restrict,
  especialidade_id uuid not null references public.especialidades (id) on delete restrict,
  dados jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid(),
  unique (paciente_id, especialidade_id)
);

create table if not exists public.atendimentos (
  id uuid primary key default gen_random_uuid(),
  paciente_id uuid not null references public.pacientes (id) on delete restrict,
  especialidade_id uuid not null references public.especialidades (id) on delete restrict,
  profissional_id uuid not null default auth.uid() references public.perfis (id),
  data date not null default ((now() at time zone 'America/Sao_Paulo')::date),
  tipo text not null default 'Sessão',
  registro text not null default '',
  conduta text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists atendimentos_paciente on public.atendimentos (paciente_id, especialidade_id, data desc);

create table if not exists public.atalhos (
  id uuid primary key default gen_random_uuid(),
  titulo text not null,
  descricao text,
  url text not null,
  cor text not null default '#3E7C6E',
  alvo text not null default 'equipe' check (alvo in ('todos', 'equipe', 'pacientes', 'selecionados')),
  usuarios uuid[] not null default '{}',
  ordem integer not null default 0,
  ativo boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.configuracoes (
  chave text primary key,
  valor jsonb not null default 'null'::jsonb,
  updated_at timestamptz not null default now()
);

create table if not exists public.auditoria (
  id bigint generated always as identity primary key,
  user_id uuid default auth.uid() references public.perfis (id) on delete set null,
  acao text not null,
  tabela text,
  registro_id uuid,
  paciente_id uuid references public.pacientes (id) on delete set null,
  detalhe text,
  criado_em timestamptz not null default now()
);
create index if not exists auditoria_data on public.auditoria (criado_em desc);

-- 2. Funções de apoio às regras de acesso ------------------------------------------

create or replace function public.meu_papel()
returns text language sql stable security definer set search_path = public as $$
  select papel from public.perfis where id = auth.uid() and ativo
$$;

create or replace function public.e_equipe()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.meu_papel() in ('mestre', 'admin', 'profissional', 'recepcao'), false)
$$;

create or replace function public.e_gestor()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.meu_papel() in ('mestre', 'admin'), false)
$$;

create or replace function public.nivel_em(p_especialidade uuid)
returns text language sql stable security definer set search_path = public as $$
  select pm.nivel from public.permissoes pm
  join public.perfis pf on pf.id = pm.user_id
  where pm.user_id = auth.uid() and pm.especialidade_id = p_especialidade
    and pf.ativo and pf.papel in ('mestre', 'admin', 'profissional')
$$;

create or replace function public.pode_ler(p_especialidade uuid)
returns boolean language sql stable as $$
  select coalesce(public.nivel_em(p_especialidade) in ('leitura', 'escrita'), false)
$$;

create or replace function public.pode_escrever(p_especialidade uuid)
returns boolean language sql stable as $$
  select coalesce(public.nivel_em(p_especialidade) = 'escrita', false)
$$;

-- 3. Conta nova: vínculo automático com o cadastro do paciente pelo e-mail ---------------

create or replace function public.ao_criar_usuario()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_paciente uuid;
begin
  select id into v_paciente from public.pacientes
  where lower(email) = lower(new.email) and user_id is null
  limit 1;

  insert into public.perfis (id, nome, email, papel)
  values (new.id,
          coalesce(nullif(new.raw_user_meta_data ->> 'nome', ''), split_part(coalesce(new.email, ''), '@', 1)),
          coalesce(new.email, ''),
          case when v_paciente is not null then 'paciente' else 'pendente' end)
  on conflict (id) do nothing;

  if v_paciente is not null then
    update public.pacientes set user_id = new.id where id = v_paciente;
  end if;
  return new;
end $$;

drop trigger if exists ao_criar_usuario on auth.users;
create trigger ao_criar_usuario after insert on auth.users
  for each row execute function public.ao_criar_usuario();

-- Paciente cadastrado depois de a pessoa já ter criado a conta: vincula pelo e-mail
create or replace function public.vincular_paciente()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_user uuid;
begin
  new.updated_at := now();
  if new.user_id is null and coalesce(new.email, '') <> '' then
    select p.id into v_user from public.perfis p
    where lower(p.email) = lower(new.email) and p.papel = 'pendente'
      and not exists (select 1 from public.pacientes x where x.user_id = p.id)
    limit 1;
    if v_user is not null then
      new.user_id := v_user;
      update public.perfis set papel = 'paciente' where id = v_user;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists vincular_paciente on public.pacientes;
create trigger vincular_paciente before insert or update of email, user_id on public.pacientes
  for each row execute function public.vincular_paciente();

-- 4. Auditoria automática de cadastros e fichas ----------------------------------------

create or replace function public.auditar()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_paciente uuid;
  v_acao text;
  v_detalhe text;
begin
  if tg_table_name = 'pacientes' then
    v_paciente := new.id;
    v_acao := case when tg_op = 'INSERT' then 'Cadastrou paciente' else 'Alterou cadastro do paciente' end;
  elsif tg_table_name = 'anamneses' then
    v_paciente := new.paciente_id;
    v_acao := case when tg_op = 'INSERT' then 'Criou anamnese' else 'Alterou anamnese' end;
    select nome into v_detalhe from public.especialidades where id = new.especialidade_id;
  elsif tg_table_name = 'atendimentos' then
    v_paciente := new.paciente_id;
    v_acao := case when tg_op = 'INSERT' then 'Registrou atendimento' else 'Alterou atendimento' end;
    select nome into v_detalhe from public.especialidades where id = new.especialidade_id;
  end if;
  insert into public.auditoria (user_id, acao, tabela, registro_id, paciente_id, detalhe)
  values (auth.uid(), v_acao, tg_table_name, new.id, v_paciente, v_detalhe);
  return new;
end $$;

drop trigger if exists auditar on public.pacientes;
create trigger auditar after insert or update on public.pacientes for each row execute function public.auditar();
drop trigger if exists auditar on public.anamneses;
create trigger auditar after insert or update on public.anamneses for each row execute function public.auditar();
drop trigger if exists auditar on public.atendimentos;
create trigger auditar after insert or update on public.atendimentos for each row execute function public.auditar();

-- Data de alteração das fichas
create or replace function public.marcar_alteracao()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  if tg_table_name = 'anamneses' then new.updated_by := auth.uid(); end if;
  return new;
end $$;

drop trigger if exists marcar_alteracao on public.anamneses;
create trigger marcar_alteracao before insert or update on public.anamneses for each row execute function public.marcar_alteracao();
drop trigger if exists marcar_alteracao on public.atendimentos;
create trigger marcar_alteracao before update on public.atendimentos for each row execute function public.marcar_alteracao();

-- 5. Ações de administração ---------------------------------------------------------

-- Altera perfil, situação e registro profissional de um usuário.
-- Só o mestre cria ou altera administradores e mestres. Ninguém altera o próprio perfil por aqui.
create or replace function public.gestor_atualizar_usuario(p_user uuid, p_papel text, p_ativo boolean, p_registro text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_eu text := public.meu_papel();
  v_alvo text;
begin
  if v_eu not in ('mestre', 'admin') or v_eu is null then raise exception 'Sem permissão.'; end if;
  if p_user = auth.uid() then raise exception 'O seu próprio perfil não pode ser alterado por aqui.'; end if;
  select papel into v_alvo from public.perfis where id = p_user;
  if v_alvo is null then raise exception 'Usuário não encontrado.'; end if;
  if p_papel not in ('mestre', 'admin', 'profissional', 'recepcao', 'paciente', 'pendente') then raise exception 'Perfil inválido.'; end if;
  if v_eu <> 'mestre' and (v_alvo in ('mestre', 'admin') or p_papel in ('mestre', 'admin')) then
    raise exception 'Somente o administrador mestre define administradores.';
  end if;
  update public.perfis
     set papel = p_papel, ativo = coalesce(p_ativo, true), registro_profissional = nullif(p_registro, '')
   where id = p_user;
  insert into public.auditoria (user_id, acao, detalhe)
  values (auth.uid(), 'Alterou acesso de usuário', (select nome from public.perfis where id = p_user) || ' · ' || p_papel || case when coalesce(p_ativo, true) then '' else ' · inativo' end);
end $$;

-- Substitui as permissões por especialidade de um usuário.
-- p_lista: [{"especialidade_id": "...", "nivel": "leitura" | "escrita"}, ...]
create or replace function public.gestor_definir_permissoes(p_user uuid, p_lista jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_eu text := public.meu_papel();
  v_alvo text;
begin
  if v_eu not in ('mestre', 'admin') or v_eu is null then raise exception 'Sem permissão.'; end if;
  select papel into v_alvo from public.perfis where id = p_user;
  if v_alvo is null then raise exception 'Usuário não encontrado.'; end if;
  if v_eu <> 'mestre' and v_alvo in ('mestre', 'admin') then
    raise exception 'Somente o administrador mestre define as permissões de administradores.';
  end if;
  delete from public.permissoes where user_id = p_user;
  insert into public.permissoes (user_id, especialidade_id, nivel)
  select p_user, (x ->> 'especialidade_id')::uuid, x ->> 'nivel'
  from jsonb_array_elements(coalesce(p_lista, '[]'::jsonb)) x
  where x ->> 'nivel' in ('leitura', 'escrita');
  insert into public.auditoria (user_id, acao, detalhe)
  values (auth.uid(), 'Alterou permissões clínicas', (select nome from public.perfis where id = p_user));
end $$;

create or replace function public.atualizar_meu_nome(p_nome text)
returns void language sql security definer set search_path = public as $$
  update public.perfis set nome = trim(p_nome) where id = auth.uid() and trim(p_nome) <> ''
$$;

-- 6. Regras de acesso (RLS) ------------------------------------------------------------

alter table public.perfis enable row level security;
alter table public.especialidades enable row level security;
alter table public.permissoes enable row level security;
alter table public.pacientes enable row level security;
alter table public.anamneses enable row level security;
alter table public.atendimentos enable row level security;
alter table public.atalhos enable row level security;
alter table public.configuracoes enable row level security;
alter table public.auditoria enable row level security;

drop policy if exists perfis_ler on public.perfis;
create policy perfis_ler on public.perfis for select to authenticated using (
  id = auth.uid() or public.e_gestor()
  or (public.e_equipe() and papel in ('mestre', 'admin', 'profissional', 'recepcao'))
);

drop policy if exists especialidades_ler on public.especialidades;
create policy especialidades_ler on public.especialidades for select to authenticated using (public.e_equipe());
drop policy if exists especialidades_gerir on public.especialidades;
create policy especialidades_gerir on public.especialidades for all to authenticated
  using (public.e_gestor()) with check (public.e_gestor());

drop policy if exists permissoes_ler on public.permissoes;
create policy permissoes_ler on public.permissoes for select to authenticated using (user_id = auth.uid() or public.e_gestor());

drop policy if exists pacientes_ler on public.pacientes;
create policy pacientes_ler on public.pacientes for select to authenticated using (public.e_equipe() or user_id = auth.uid());
drop policy if exists pacientes_incluir on public.pacientes;
create policy pacientes_incluir on public.pacientes for insert to authenticated with check (public.e_equipe());
drop policy if exists pacientes_alterar on public.pacientes;
create policy pacientes_alterar on public.pacientes for update to authenticated using (public.e_equipe()) with check (public.e_equipe());

drop policy if exists anamneses_ler on public.anamneses;
create policy anamneses_ler on public.anamneses for select to authenticated using (public.pode_ler(especialidade_id));
drop policy if exists anamneses_incluir on public.anamneses;
create policy anamneses_incluir on public.anamneses for insert to authenticated with check (public.pode_escrever(especialidade_id));
drop policy if exists anamneses_alterar on public.anamneses;
create policy anamneses_alterar on public.anamneses for update to authenticated
  using (public.pode_escrever(especialidade_id)) with check (public.pode_escrever(especialidade_id));

drop policy if exists atendimentos_ler on public.atendimentos;
create policy atendimentos_ler on public.atendimentos for select to authenticated using (public.pode_ler(especialidade_id));
drop policy if exists atendimentos_incluir on public.atendimentos;
create policy atendimentos_incluir on public.atendimentos for insert to authenticated
  with check (public.pode_escrever(especialidade_id) and profissional_id = auth.uid());
drop policy if exists atendimentos_alterar on public.atendimentos;
create policy atendimentos_alterar on public.atendimentos for update to authenticated
  using (public.pode_escrever(especialidade_id) and profissional_id = auth.uid())
  with check (public.pode_escrever(especialidade_id) and profissional_id = auth.uid());

drop policy if exists atalhos_ler on public.atalhos;
create policy atalhos_ler on public.atalhos for select to authenticated using (
  public.e_gestor()
  or (ativo and public.meu_papel() is not null and public.meu_papel() <> 'pendente' and (
       alvo = 'todos'
    or (alvo = 'equipe' and public.e_equipe())
    or (alvo = 'pacientes' and public.meu_papel() = 'paciente')
    or (alvo = 'selecionados' and auth.uid() = any (usuarios))))
);
drop policy if exists atalhos_gerir on public.atalhos;
create policy atalhos_gerir on public.atalhos for all to authenticated
  using (public.e_gestor()) with check (public.e_gestor());

drop policy if exists configuracoes_ler on public.configuracoes;
create policy configuracoes_ler on public.configuracoes for select to authenticated using (
  public.e_equipe() or chave = 'nome_clinica'
);
drop policy if exists configuracoes_gerir on public.configuracoes;
create policy configuracoes_gerir on public.configuracoes for all to authenticated
  using (public.e_gestor()) with check (public.e_gestor());

drop policy if exists auditoria_ler on public.auditoria;
create policy auditoria_ler on public.auditoria for select to authenticated using (public.e_gestor());
drop policy if exists auditoria_registrar on public.auditoria;
create policy auditoria_registrar on public.auditoria for insert to authenticated
  with check (user_id = auth.uid() and public.meu_papel() is not null);

-- 7. Permissões de execução -------------------------------------------------------------

revoke all on function public.gestor_atualizar_usuario(uuid, text, boolean, text) from public, anon;
revoke all on function public.gestor_definir_permissoes(uuid, jsonb) from public, anon;
revoke all on function public.atualizar_meu_nome(text) from public, anon;
grant execute on function public.gestor_atualizar_usuario(uuid, text, boolean, text) to authenticated;
grant execute on function public.gestor_definir_permissoes(uuid, jsonb) to authenticated;
grant execute on function public.atualizar_meu_nome(text) to authenticated;

alter function public.pode_ler(uuid) set search_path = public;
alter function public.pode_escrever(uuid) set search_path = public;
alter function public.marcar_alteracao() set search_path = public;

-- Funções de gatilho: ninguém chama diretamente
revoke all on function public.ao_criar_usuario() from public, anon, authenticated;
revoke all on function public.vincular_paciente() from public, anon, authenticated;
revoke all on function public.auditar() from public, anon, authenticated;
revoke all on function public.marcar_alteracao() from public, anon, authenticated;

-- Funções das regras de acesso: só para quem está logado
revoke all on function public.meu_papel() from public, anon;
revoke all on function public.e_equipe() from public, anon;
revoke all on function public.e_gestor() from public, anon;
revoke all on function public.nivel_em(uuid) from public, anon;
revoke all on function public.pode_ler(uuid) from public, anon;
revoke all on function public.pode_escrever(uuid) from public, anon;
grant execute on function public.meu_papel(), public.e_equipe(), public.e_gestor(), public.nivel_em(uuid), public.pode_ler(uuid), public.pode_escrever(uuid) to authenticated;

-- 8. Nome da clínica (altere à vontade) -----------------------------------------------------
insert into public.configuracoes (chave, valor) values ('nome_clinica', '"Clínica"'::jsonb)
on conflict (chave) do nothing;

-- =====================================================================================
-- Atualização 01 · agenda da clínica (salas e agendamentos)
-- Rode uma vez no SQL Editor do Supabase: New query > colar este arquivo inteiro > Run.
--
-- Regras:
-- - Cada sala tem dias da semana e horário de funcionamento. Consultas só cabem dentro desse horário.
-- - Uma sala não recebe duas consultas no mesmo horário; um profissional também não.
-- - Recepção e administradores marcam para qualquer profissional; o profissional marca na própria agenda.
-- - Toda a equipe vê a agenda completa. O paciente vê apenas as próprias consultas.
-- - Consulta não se apaga: muda de situação (agendada, confirmada, realizada, faltou, cancelada).
-- Horários no fuso de Brasília.

create extension if not exists btree_gist with schema extensions;

-- 1. Tabelas ------------------------------------------------------------------------

create table if not exists public.salas (
  id uuid primary key default gen_random_uuid(),
  nome text not null unique,
  cor text not null default '#2E6B5F',
  dias smallint[] not null default '{1,2,3,4,5}',   -- 0 = domingo, 1 = segunda ... 6 = sábado
  abre time not null default '08:00',
  fecha time not null default '18:00',
  ativa boolean not null default true,
  ordem integer not null default 0,
  created_at timestamptz not null default now(),
  check (fecha > abre)
);

create table if not exists public.agendamentos (
  id uuid primary key default gen_random_uuid(),
  paciente_id uuid not null references public.pacientes (id) on delete restrict,
  profissional_id uuid not null references public.perfis (id),
  sala_id uuid not null references public.salas (id) on delete restrict,
  inicio timestamptz not null,
  fim timestamptz not null,
  status text not null default 'agendado'
    check (status in ('agendado', 'confirmado', 'realizado', 'faltou', 'cancelado')),
  observacao text,
  criado_por uuid default auth.uid() references public.perfis (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (fim > inicio),
  constraint agenda_sala_livre exclude using gist (sala_id with =, tstzrange(inicio, fim) with &&) where (status <> 'cancelado'),
  constraint agenda_profissional_livre exclude using gist (profissional_id with =, tstzrange(inicio, fim) with &&) where (status <> 'cancelado')
);
create index if not exists agendamentos_inicio on public.agendamentos (inicio);
create index if not exists agendamentos_paciente on public.agendamentos (paciente_id, inicio desc);

-- 2. Validação: horário da sala e profissional ativo ----------------------------------

create or replace function public.validar_agendamento()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  s public.salas%rowtype;
  v_ini timestamp := new.inicio at time zone 'America/Sao_Paulo';
  v_fim timestamp := new.fim at time zone 'America/Sao_Paulo';
begin
  new.updated_at := now();
  if tg_op = 'UPDATE' and new.inicio = old.inicio and new.fim = old.fim
     and new.sala_id = old.sala_id and new.profissional_id = old.profissional_id then
    return new;
  end if;
  select * into s from public.salas where id = new.sala_id;
  if not found or not s.ativa then raise exception 'Sala indisponível.'; end if;
  if v_ini::date <> v_fim::date then raise exception 'A consulta precisa começar e terminar no mesmo dia.'; end if;
  if not (extract(dow from v_ini)::smallint = any (s.dias)) then
    raise exception 'A sala % não funciona neste dia da semana.', s.nome;
  end if;
  if v_ini::time < s.abre or v_fim::time > s.fecha then
    raise exception 'Fora do horário da sala % (% às %).', s.nome, to_char(s.abre, 'HH24:MI'), to_char(s.fecha, 'HH24:MI');
  end if;
  if not exists (select 1 from public.perfis where id = new.profissional_id and ativo and papel in ('mestre', 'admin', 'profissional')) then
    raise exception 'Escolha um profissional ativo da clínica.';
  end if;
  return new;
end $$;

drop trigger if exists validar_agendamento on public.agendamentos;
create trigger validar_agendamento before insert or update on public.agendamentos
  for each row execute function public.validar_agendamento();

-- 3. Auditoria das consultas ------------------------------------------------------------

create or replace function public.auditar_agendamento()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_acao text;
begin
  if tg_op = 'INSERT' then v_acao := 'Agendou consulta';
  elsif new.status = 'cancelado' and old.status <> 'cancelado' then v_acao := 'Cancelou consulta';
  elsif new.status <> old.status then v_acao := 'Alterou situação da consulta';
  else v_acao := 'Alterou consulta';
  end if;
  insert into public.auditoria (user_id, acao, tabela, registro_id, paciente_id, detalhe)
  values (auth.uid(), v_acao, 'agendamentos', new.id, new.paciente_id,
          (select nome from public.salas where id = new.sala_id) || ' · '
          || to_char(new.inicio at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') || ' · ' || new.status);
  return new;
end $$;

drop trigger if exists auditar_agendamento on public.agendamentos;
create trigger auditar_agendamento after insert or update on public.agendamentos
  for each row execute function public.auditar_agendamento();

-- 4. Quem pode marcar ---------------------------------------------------------------------

create or replace function public.pode_agendar(p_profissional uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.meu_papel() in ('mestre', 'admin', 'recepcao')
               or (public.meu_papel() = 'profissional' and p_profissional = auth.uid()), false)
$$;

-- 5. Consultas do paciente (área do paciente) ------------------------------------------------

create or replace function public.minhas_consultas()
returns table (id uuid, inicio timestamptz, fim timestamptz, status text, sala text, profissional text)
language sql stable security definer set search_path = public as $$
  select a.id, a.inicio, a.fim, a.status, s.nome, pf.nome
  from public.agendamentos a
  join public.pacientes p on p.id = a.paciente_id
  join public.salas s on s.id = a.sala_id
  join public.perfis pf on pf.id = a.profissional_id
  where p.user_id = auth.uid()
  order by a.inicio desc
$$;

-- 6. Regras de acesso (RLS) -------------------------------------------------------------------

alter table public.salas enable row level security;
alter table public.agendamentos enable row level security;

drop policy if exists salas_ler on public.salas;
create policy salas_ler on public.salas for select to authenticated using (public.e_equipe());
drop policy if exists salas_gerir on public.salas;
create policy salas_gerir on public.salas for all to authenticated
  using (public.e_gestor()) with check (public.e_gestor());

drop policy if exists agendamentos_ler on public.agendamentos;
create policy agendamentos_ler on public.agendamentos for select to authenticated using (public.e_equipe());
drop policy if exists agendamentos_incluir on public.agendamentos;
create policy agendamentos_incluir on public.agendamentos for insert to authenticated
  with check (public.pode_agendar(profissional_id));
drop policy if exists agendamentos_alterar on public.agendamentos;
create policy agendamentos_alterar on public.agendamentos for update to authenticated
  using (public.pode_agendar(profissional_id)) with check (public.pode_agendar(profissional_id));

-- 7. Permissões de execução -----------------------------------------------------------------

alter function public.validar_agendamento() set search_path = public;
revoke all on function public.validar_agendamento() from public, anon, authenticated;
revoke all on function public.auditar_agendamento() from public, anon, authenticated;
revoke all on function public.pode_agendar(uuid) from public, anon;
revoke all on function public.minhas_consultas() from public, anon;
grant execute on function public.pode_agendar(uuid) to authenticated;
grant execute on function public.minhas_consultas() to authenticated;

-- 8. Salas iniciais -----------------------------------------------------------------------------
insert into public.salas (nome, cor, dias, abre, fecha, ordem) values
  ('Naty Camargo', '#7A4FA0', '{1,2,3,4,5}', '08:00', '18:00', 1),
  ('Família', '#2E6B5F', '{0,1,2,3,4,5,6}', '08:00', '18:00', 2)
on conflict (nome) do nothing;

-- =====================================================================================
-- Atualização 02 · financeiro da clínica
-- Rode uma vez no SQL Editor do Supabase: New query > colar este arquivo inteiro > Run.
--
-- Regras:
-- - Somente administradores (mestre e admin) veem e lançam no financeiro.
-- - Consulta marcada como realizada gera a cobrança do paciente com o valor padrão do profissional.
--   Se o paciente tiver pacote com saldo, a consulta abate do pacote e não gera cobrança.
--   Se a consulta deixar de ser realizada, a cobrança ainda não paga é retirada.
-- - Cada profissional tem um acordo: quem recebe do paciente (clínica ou profissional) e o modelo com a clínica
--   (sem divisão, repasse mensal fixo ou aluguel de sala por hora marcada na agenda).
-- - A geração do mês cria os gastos e receitas recorrentes e calcula repasses e aluguéis.
-- Valores em reais, datas no fuso de Brasília.

-- 1. Tabelas ------------------------------------------------------------------------

create table if not exists public.fin_acordos (
  profissional_id uuid primary key references public.perfis (id) on delete cascade,
  recebedor text not null default 'clinica' check (recebedor in ('clinica', 'profissional')),
  modelo text not null default 'sem_divisao' check (modelo in ('sem_divisao', 'repasse_mensal', 'aluguel_hora')),
  valor_modelo numeric(12,2) not null default 0,       -- repasse: valor mensal; aluguel: valor por hora
  sala_id uuid references public.salas (id) on delete set null,   -- aluguel: sala considerada (vazio = todas)
  dia_vencimento smallint not null default 10 check (dia_vencimento between 1 and 28),
  valor_sessao numeric(12,2),                          -- valor padrão da consulta
  updated_at timestamptz not null default now()
);

create table if not exists public.pacotes (
  id uuid primary key default gen_random_uuid(),
  paciente_id uuid not null references public.pacientes (id) on delete restrict,
  profissional_id uuid references public.perfis (id) on delete set null,   -- vazio = vale para qualquer profissional
  descricao text not null,
  sessoes integer not null check (sessoes > 0),
  valor numeric(12,2) not null default 0 check (valor >= 0),
  ativo boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.pacote_usos (
  agendamento_id uuid primary key references public.agendamentos (id) on delete cascade,
  pacote_id uuid not null references public.pacotes (id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.fin_recorrencias (
  id uuid primary key default gen_random_uuid(),
  tipo text not null default 'despesa' check (tipo in ('receita', 'despesa')),
  descricao text not null,
  categoria text not null default 'Outras despesas',
  valor numeric(12,2) not null check (valor >= 0),
  dia_vencimento smallint not null default 10 check (dia_vencimento between 1 and 28),
  ativo boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.lancamentos (
  id uuid primary key default gen_random_uuid(),
  numero bigint generated always as identity,
  tipo text not null check (tipo in ('receita', 'despesa')),
  descricao text not null,
  categoria text not null,
  valor numeric(12,2) not null check (valor >= 0),
  vencimento date not null,
  pago_em date,
  forma_pagamento text,
  recebedor text not null default 'clinica' check (recebedor in ('clinica', 'profissional')),
  paciente_id uuid references public.pacientes (id) on delete set null,
  profissional_id uuid references public.perfis (id) on delete set null,
  agendamento_id uuid unique references public.agendamentos (id) on delete set null,
  pacote_id uuid references public.pacotes (id) on delete set null,
  recorrencia_id uuid references public.fin_recorrencias (id) on delete set null,
  origem text not null default 'manual' check (origem in ('manual', 'consulta', 'pacote', 'repasse', 'aluguel', 'recorrente')),
  competencia date,
  observacao text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists lancamentos_vencimento on public.lancamentos (vencimento);
create index if not exists lancamentos_paciente on public.lancamentos (paciente_id);
create unique index if not exists lancamentos_acordo_mes on public.lancamentos (origem, profissional_id, competencia) where origem in ('repasse', 'aluguel');
create unique index if not exists lancamentos_recorrente_mes on public.lancamentos (recorrencia_id, competencia) where recorrencia_id is not null;

create or replace function public.fin_marcar_alteracao()
returns trigger language plpgsql set search_path = public as $$
begin new.updated_at := now(); return new; end $$;
drop trigger if exists fin_marcar_alteracao on public.lancamentos;
create trigger fin_marcar_alteracao before update on public.lancamentos for each row execute function public.fin_marcar_alteracao();

-- 2. Cobrança automática da consulta realizada ------------------------------------------

create or replace function public.cobrar_consulta()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_ac public.fin_acordos%rowtype;
  v_pacote uuid;
  v_data date := (new.inicio at time zone 'America/Sao_Paulo')::date;
begin
  if new.status = 'realizado' and (tg_op = 'INSERT' or old.status <> 'realizado') then
    if exists (select 1 from public.lancamentos where agendamento_id = new.id)
       or exists (select 1 from public.pacote_usos where agendamento_id = new.id) then
      return new;
    end if;
    select p.id into v_pacote from public.pacotes p
    where p.paciente_id = new.paciente_id and p.ativo
      and (p.profissional_id is null or p.profissional_id = new.profissional_id)
      and (select count(*) from public.pacote_usos u where u.pacote_id = p.id) < p.sessoes
    order by p.created_at
    limit 1;
    if v_pacote is not null then
      insert into public.pacote_usos (agendamento_id, pacote_id) values (new.id, v_pacote);
      return new;
    end if;
    select * into v_ac from public.fin_acordos where profissional_id = new.profissional_id;
    insert into public.lancamentos (tipo, descricao, categoria, valor, vencimento, recebedor, paciente_id, profissional_id, agendamento_id, origem)
    values ('receita',
            'Consulta de ' || to_char(v_data, 'DD/MM/YYYY') || ' · ' || coalesce((select nome from public.perfis where id = new.profissional_id), ''),
            'Consultas', coalesce(v_ac.valor_sessao, 0), v_data, coalesce(v_ac.recebedor, 'clinica'),
            new.paciente_id, new.profissional_id, new.id, 'consulta');
  elsif tg_op = 'UPDATE' and old.status = 'realizado' and new.status <> 'realizado' then
    delete from public.lancamentos where agendamento_id = new.id and origem = 'consulta' and pago_em is null;
    delete from public.pacote_usos where agendamento_id = new.id;
  end if;
  return new;
end $$;

drop trigger if exists cobrar_consulta on public.agendamentos;
create trigger cobrar_consulta after insert or update of status on public.agendamentos
  for each row execute function public.cobrar_consulta();

-- 3. Geração do mês: recorrentes, repasses e aluguéis ------------------------------------

create or replace function public.fin_gerar_mes(p_mes date)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_ini date := date_trunc('month', p_mes)::date;
  v_fim date := (date_trunc('month', p_mes) + interval '1 month')::date;
  r record;
  v_n integer := 0;
  v_valor numeric(12,2);
  v_horas numeric;
begin
  if not public.e_gestor() then raise exception 'Sem permissão.'; end if;

  for r in select * from public.fin_recorrencias
           where ativo and date_trunc('month', created_at at time zone 'America/Sao_Paulo')::date <= v_ini loop
    insert into public.lancamentos (tipo, descricao, categoria, valor, vencimento, recorrencia_id, origem, competencia)
    values (r.tipo, r.descricao, r.categoria, r.valor, v_ini + (r.dia_vencimento - 1), r.id, 'recorrente', v_ini)
    on conflict (recorrencia_id, competencia) where recorrencia_id is not null do nothing;
    if found then v_n := v_n + 1; end if;
  end loop;

  for r in select a.*, pf.nome from public.fin_acordos a join public.perfis pf on pf.id = a.profissional_id
           where a.modelo in ('repasse_mensal', 'aluguel_hora') loop
    v_horas := null;
    if r.modelo = 'repasse_mensal' then
      v_valor := r.valor_modelo;
    else
      select coalesce(sum(extract(epoch from (fim - inicio)) / 3600.0), 0) into v_horas
      from public.agendamentos
      where profissional_id = r.profissional_id and status <> 'cancelado'
        and (r.sala_id is null or sala_id = r.sala_id)
        and (inicio at time zone 'America/Sao_Paulo')::date >= v_ini
        and (inicio at time zone 'America/Sao_Paulo')::date < v_fim;
      v_valor := round(v_horas * r.valor_modelo, 2);
    end if;
    insert into public.lancamentos (tipo, descricao, categoria, valor, vencimento, profissional_id, origem, competencia, observacao)
    values ('receita',
            case when r.modelo = 'repasse_mensal' then 'Repasse mensal · ' else 'Aluguel de sala · ' end || r.nome || ' · ' || to_char(v_ini, 'MM/YYYY'),
            case when r.modelo = 'repasse_mensal' then 'Repasses' else 'Aluguel de sala' end,
            v_valor, v_fim + (r.dia_vencimento - 1), r.profissional_id,
            case when r.modelo = 'repasse_mensal' then 'repasse' else 'aluguel' end, v_ini,
            case when v_horas is null then null else replace(to_char(v_horas, 'FM9990.0'), '.', ',') || ' h marcadas na agenda' end)
    on conflict (origem, profissional_id, competencia) where origem in ('repasse', 'aluguel')
    do update set valor = excluded.valor, observacao = excluded.observacao, descricao = excluded.descricao
       where public.lancamentos.pago_em is null;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- 4. Regras de acesso (RLS): só administradores ---------------------------------------------

alter table public.fin_acordos enable row level security;
alter table public.pacotes enable row level security;
alter table public.pacote_usos enable row level security;
alter table public.fin_recorrencias enable row level security;
alter table public.lancamentos enable row level security;

drop policy if exists fin_acordos_gestor on public.fin_acordos;
create policy fin_acordos_gestor on public.fin_acordos for all to authenticated using (public.e_gestor()) with check (public.e_gestor());
drop policy if exists pacotes_gestor on public.pacotes;
create policy pacotes_gestor on public.pacotes for all to authenticated using (public.e_gestor()) with check (public.e_gestor());
drop policy if exists pacote_usos_gestor on public.pacote_usos;
create policy pacote_usos_gestor on public.pacote_usos for select to authenticated using (public.e_gestor());
drop policy if exists fin_recorrencias_gestor on public.fin_recorrencias;
create policy fin_recorrencias_gestor on public.fin_recorrencias for all to authenticated using (public.e_gestor()) with check (public.e_gestor());
drop policy if exists lancamentos_gestor on public.lancamentos;
create policy lancamentos_gestor on public.lancamentos for all to authenticated using (public.e_gestor()) with check (public.e_gestor());

-- 5. Permissões de execução -----------------------------------------------------------------

revoke all on function public.cobrar_consulta() from public, anon, authenticated;
revoke all on function public.fin_marcar_alteracao() from public, anon, authenticated;
revoke all on function public.fin_gerar_mes(date) from public, anon;
grant execute on function public.fin_gerar_mes(date) to authenticated;
