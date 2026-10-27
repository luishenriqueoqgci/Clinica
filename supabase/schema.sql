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
