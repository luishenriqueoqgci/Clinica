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
