-- ===========================================================================
-- MIGRATION 005 — Exclusão lógica (soft delete) de profissionais
--
-- Decisão do produto:
--   * NUNCA excluir fisicamente um profissional: o histórico de
--     agendamentos e bloqueios continua apontando para ele (FKs RESTRICT).
--   * A exclusão é marcada com deleted_at = now() e ativo = false.
--   * Um profissional excluído: some das listas normais e dos seletores de
--     novos agendamentos; perde acesso ao sistema (Auth removido de forma
--     segura no servidor); a operação é exclusiva de Admin, server-side,
--     via RPC admin_excluir_profissional.
--
-- O que esta migração faz:
--   1) Adiciona a coluna deleted_at (timestamptz, NULL = não excluído).
--   2) Reforça as 5 funções auxiliares de RLS com `deleted_at IS NULL`:
--      um excluído NUNCA volta a operar, mesmo que ativo seja reativado.
--   3) Impede que RPCs de agendamento atribuam um profissional excluído:
--      admin_criar_agendamento e admin_atualizar_agendamento passam a
--      exigir barbeiro ativo e não excluído da própria barbearia.
--   4) Nova RPC admin_excluir_profissional(p_id) (SECURITY DEFINER):
--      valida admin da MESMA barbearia, impede excluir a si mesmo e o
--      único admin ativo, e marca deleted_at + ativo = false.
--   5) Grants mínimos: REVOKE de PUBLIC/anon + GRANT EXECUTE apenas para
--      authenticated (padrão do arquivo rls.sql).
--
-- Proteções preservadas (nada é desligado):
--   * created_at permanece intacto (nenhum comando toca essa coluna);
--   * nenhum DELETE físico: agendamentos/bloqueios com FKs RESTRICT são
--     preservados;
--   * A1/M1 (validar_agendamento_bloqueios / derivar_duracao_agendamento)
--     NÃO são alterados;
--   * RLS continua valendo: ninguém exclui por fora da RPC.
--
-- Idempotente e seguro para reexecução. NÃO altera produção automaticamente
-- (executar no SQL Editor quando aprovado pela equipe).
-- ===========================================================================

-- -----------------------------------------------------------------------
-- 1) Coluna deleted_at
-- -----------------------------------------------------------------------
ALTER TABLE public.profissionais
  ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

COMMENT ON COLUMN public.profissionais.deleted_at
  IS 'Momento da exclusão lógica (soft delete). NULL = profissional vigente.';

-- Índice parcial opcional: consultas que filtram profissionais vigentes.
CREATE INDEX IF NOT EXISTS idx_profissionais_barbearia_vigentes
  ON public.profissionais (barbearia_id)
  WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------
-- 2) Funções auxiliares de RLS passam a diferenciar excluído de inativo
-- -----------------------------------------------------------------------
-- Antes usavam apenas `ativo = true`. Como a exclusão também seta
-- ativo = false isso já bloqueava o excluído — MAS um admin poderia
-- reativar (ativo = true) um profissional já excluído (deleted_at não nulo),
-- fazendo-o voltar a operar. A condição extra fecha essa brecha.
CREATE OR REPLACE FUNCTION public.profissional_autenticado_id()
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT p.id
  FROM public.profissionais p
  WHERE p.auth_user_id = auth.uid()
    AND p.ativo = true
    AND p.deleted_at IS NULL
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.barbearia_profissional_autenticado()
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT p.barbearia_id
  FROM public.profissionais p
  WHERE p.auth_user_id = auth.uid()
    AND p.ativo = true
    AND p.deleted_at IS NULL
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.usuario_pertence_a_barbearia(p_barbearia bigint)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profissionais p
    WHERE p.auth_user_id = auth.uid()
      AND p.barbearia_id = p_barbearia
      AND p.ativo = true
      AND p.deleted_at IS NULL
  );
$$;

CREATE OR REPLACE FUNCTION public.usuario_e_admin_da_barbearia(p_barbearia bigint)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profissionais p
    WHERE p.auth_user_id = auth.uid()
      AND p.cargo = 'admin'
      AND p.barbearia_id = p_barbearia
      AND p.ativo = true
      AND p.deleted_at IS NULL
  );
$$;

CREATE OR REPLACE FUNCTION public.usuario_e_barbeiro_autenticado()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profissionais p
    WHERE p.auth_user_id = auth.uid()
      AND p.cargo = 'barbeiro'
      AND p.ativo = true
      AND p.deleted_at IS NULL
  );
$$;

-- -----------------------------------------------------------------------
-- 3) RPCs de agendamento passam a exigir barbeiro ATIVO e NÃO excluído
-- -----------------------------------------------------------------------
-- Sem este guard, um profissional excluído (a linha ainda existe para
-- preservar o histórico) continuaria satisfazendo a FK composta
-- fk_agendamentos_barbeiro e poderia receber novos agendamentos.
CREATE OR REPLACE FUNCTION public.admin_criar_agendamento(
  p_barbearia_id bigint,
  p_barbeiro_id bigint,
  p_servico_id bigint,
  p_cliente_id bigint,
  p_data_hora_inicio timestamp with time zone,
  p_data_hora_fim timestamp with time zone,
  p_status text,
  p_observacoes text
)
RETURNS public.agendamentos
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_agendamento public.agendamentos;
BEGIN
  -- Só pode criar se o próprio admin pertence à barbearia informada.
  IF NOT public.usuario_e_admin_da_barbearia(p_barbearia_id) THEN
    RAISE EXCEPTION 'somente admin da própria barbearia pode criar agendamento';
  END IF;

  -- Novo agendamento começa SÓ como 'pendente' (não admite outros status
  -- no momento da criação; para confirmar/alterar usa admin_atualizar).
  IF p_status IS NOT NULL AND p_status <> 'pendente' THEN
    RAISE EXCEPTION 'novo agendamento deve iniciar com status pendente';
  END IF;

  -- Barbeiro deve existir, ser da mesma barbearia, ativo e NÃO excluído.
  IF NOT EXISTS (
    SELECT 1 FROM public.profissionais p
     WHERE p.id = p_barbeiro_id
       AND p.barbearia_id = p_barbearia_id
       AND p.cargo = 'barbeiro'
       AND p.ativo = true
       AND p.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'barbeiro inválido ou indisponível';
  END IF;

  INSERT INTO public.agendamentos (
    barbearia_id, barbeiro_id, servico_id, cliente_id,
    data_hora_inicio, data_hora_fim, status, observacoes
  ) VALUES (
    p_barbearia_id, p_barbeiro_id, p_servico_id, p_cliente_id,
    p_data_hora_inicio, p_data_hora_fim,
    COALESCE(p_status, 'pendente'), p_observacoes
  )
  RETURNING * INTO v_agendamento;

  RETURN v_agendamento;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_atualizar_agendamento(
  p_agendamento_id bigint,
  p_barbeiro_id bigint,
  p_servico_id bigint,
  p_cliente_id bigint,
  p_data_hora_inicio timestamp with time zone,
  p_data_hora_fim timestamp with time zone,
  p_status text,
  p_observacoes text
)
RETURNS public.agendamentos
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_agendamento public.agendamentos;
BEGIN
  -- Barbeiro deve existir, pertencer à MESMA barbearia do agendamento,
  -- ser ativo e NÃO excluído.
  IF NOT EXISTS (
    SELECT 1 FROM public.profissionais p
     WHERE p.id = p_barbeiro_id
       AND p.barbearia_id = p_barbearia_id
       AND p.ativo = true
       AND p.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'barbeiro inválido ou indisponível';
  END IF;

  UPDATE public.agendamentos a
     SET barbeiro_id      = p_barbeiro_id,
         servico_id       = p_servico_id,
         cliente_id       = p_cliente_id,
         data_hora_inicio = p_data_hora_inicio,
         data_hora_fim    = p_data_hora_fim,
         status           = p_status,
         observacoes      = p_observacoes
   WHERE a.id = p_agendamento_id
     AND public.usuario_e_admin_da_barbearia(a.barbearia_id)
     AND (
       p_status = a.status                              -- status inalterado
       OR public.transicao_status_valida(p_status, a.status)
     )
  RETURNING * INTO v_agendamento;

  IF v_agendamento.id IS NULL THEN
    RAISE EXCEPTION 'agendamento não encontrado, pertence a outra barbearia ou transição de status inválida';
  END IF;

  RETURN v_agendamento;
END;
$$;

-- -----------------------------------------------------------------------
-- 4) RPC — admin excluir profissional (soft delete server-side)
-- -----------------------------------------------------------------------
-- A barbearia é derivada do REGISTRO alvo (nunca do payload) e o chamador
-- precisa ser admin dessa MESMA barbearia. O comando NUNCA exclui a linha:
-- seta deleted_at = now(), ativo = false e updated_at (created_at intacto).
CREATE OR REPLACE FUNCTION public.admin_excluir_profissional(p_profissional_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_barbearia        bigint;
  v_cargo            text;
  v_id_autenticado   bigint;
BEGIN
  SELECT p.barbearia_id, p.cargo
    INTO v_barbearia, v_cargo
    FROM public.profissionais p
   WHERE p.id = p_profissional_id;

  IF v_barbearia IS NULL THEN
    RAISE EXCEPTION 'profissional não encontrado';
  END IF;

  -- Somente Admin da MESMA barbearia do profissional alvo.
  IF NOT public.usuario_e_admin_da_barbearia(v_barbearia) THEN
    RAISE EXCEPTION 'somente admin da própria barbearia pode excluir profissional';
  END IF;

  -- O admin não pode excluir o próprio cadastro (ficaria sem acesso).
  v_id_autenticado := public.profissional_autenticado_id();
  IF v_id_autenticado = p_profissional_id THEN
    RAISE EXCEPTION 'você não pode excluir o próprio cadastro';
  END IF;

  -- Não pode excluir o ÚNICO admin ativo (não excluído) da barbearia.
  IF v_cargo = 'admin' AND NOT EXISTS (
    SELECT 1 FROM public.profissionais p
     WHERE p.barbearia_id = v_barbearia
       AND p.cargo = 'admin'
       AND p.ativo = true
       AND p.deleted_at IS NULL
       AND p.id <> p_profissional_id
  ) THEN
    RAISE EXCEPTION 'não é possível excluir o único administrador da barbearia';
  END IF;

  UPDATE public.profissionais
     SET deleted_at = now(),
         ativo      = false,
         updated_at = now()
   WHERE id = p_profissional_id
     AND deleted_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'profissional não encontrado ou já excluído';
  END IF;
END;
$$;

-- -----------------------------------------------------------------------
-- 5) Privilégios mínimos (somente authenticated, sem acesso para PUBLIC/anon)
-- -----------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.admin_excluir_profissional(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_excluir_profissional(bigint) TO authenticated;