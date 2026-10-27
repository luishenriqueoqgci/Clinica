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
