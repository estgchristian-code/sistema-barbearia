-- ===========================================================================
-- MIGRATION 008 — Correção F3: admin_atualizar_agendamento
--
-- Contexto (achado de auditoria F3, confirmado em produção):
--   A migration 005 criava public.admin_atualizar_agendamento com uma
--   referência órfã a p_barbearia_id (parâmetro NÃO declarado na assinatura):
--
--     IF NOT EXISTS (
--       SELECT 1 FROM public.profissionais p
--        WHERE p.id = p_barbeiro_id
--          AND p.barbearia_id = p_barbearia_id   -- BUG: coluna inexistente
--          AND p.ativo = true
--          AND p.deleted_at IS NULL
--     ) THEN ...
--
--   Em tempo de execução toda chamada falha com:
--     column "p_barbearia_id" does not exist
--
--   O database/rls.sql (versão consolidada) já contém a implementação
--   correta — a validação do barbeiro foi movida para um EXISTS dentro do
--   UPDATE, garantido o cruzamento pela barbearia do agendamento (a.*):
--
--     AND EXISTS (
--       SELECT 1 FROM public.profissionais p
--        WHERE p.id = p_barbeiro_id
--          AND p.barbearia_id = a.barbearia_id   -- CORRETO
--          AND p.ativo = true
--          AND p.deleted_at IS NULL
--     )
--
-- O que esta migration faz:
--   * REEMPLAZA APENAS public.admin_atualizar_agendamento com a versão
--     correta (idêntica à do database/rls.sql);
--   * PRESERVA a assinatura pública atual (p_agendamento_id, p_barbeiro_id,
--     p_servico_id, p_cliente_id, p_data_hora_inicio, p_data_hora_fim,
--     p_status, p_observacoes) RETURNS public.agendamentos;
--   * reafirma os grants mínimos (somente authenticated);
--   * NÃO altera outras RPCs, NÃO altera RLS, NÃO altera triggers
--     (A1 trg_agendamentos_validar_bloqueios e M1
--     trg_agendamentos_derivar_duracao permanecem intactos).
--
-- Idempotente e seguro para reexecução (CREATE OR REPLACE FUNCTION +
-- REVOKE/GRANT são idempotentes). Portal de fix imediato em produção:
-- basta aplicar apenas este arquivo via SQL Editor / migration runner.
-- ===========================================================================

-- -----------------------------------------------------------------------
-- 1) RPC — admin atualizar agendamento (versão CORRETA)
-- -----------------------------------------------------------------------
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
     -- Barbeiro ativo e NÃO excluído da MESMA barbearia do agendamento
     -- (a linha excluída permanece para o histórico, mas não pode ser
     --  reatribuída em novos registros/edições).
     AND EXISTS (
       SELECT 1 FROM public.profissionais p
        WHERE p.id = p_barbeiro_id
          AND p.barbearia_id = a.barbearia_id
          AND p.ativo = true
          AND p.deleted_at IS NULL
     )
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
-- 2) Privilégios mínimos (reafirmação idempotente: acesso somente a auth)
-- -----------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.admin_atualizar_agendamento(bigint, bigint, bigint, bigint, timestamp with time zone, timestamp with time zone, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_atualizar_agendamento(bigint, bigint, bigint, bigint, timestamp with time zone, timestamp with time zone, text, text) TO authenticated;