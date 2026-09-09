-- ===========================================================================
-- MIGRATION 003 — Duração do agendamento derivada do serviço (autoridade do banco)
--
-- Problema resolvido (auditoria M1):
--   As RPCs admin_criar_agendamento / admin_atualizar_agendamento aceitavam
--   data_hora_fim arbitrário; nenhuma constraint/trigger garantia que:
--     data_hora_fim - data_hora_inicio = servicos.duracao_minutos
--
-- Solução adotada (no banco — autoridade final, não depende do frontend):
--   Trigger BEFORE INSERT/UPDATE em public.agendamentos que:
--     1. localiza o serviço pela combinação (servico_id, barbearia_id);
--     2. obtém duracao_minutos DIRETO do banco (nunca do cliente);
--     3. sobrescreve NEW.data_hora_fim = data_hora_inicio + duracao;
--     4. rejeita serviço inexistente/inválido.
--
-- O trigger dispara em INSERT e em UPDATE OF servico_id, data_hora_inicio,
-- data_hora_fim — incluir o fim é OBRIGATÓRIO para impedir que alguém altere
-- SOMENTE data_hora_fim e escape da derivação.
--
-- Ordem de execução: como o nome do trigger (derivar_...) é alfabeticamente
-- anterior a trg_agendamentos_validar_bloqueios (validar_...), a derivação
-- roda ANTES do validador de bloqueios/horário — que enxerga o fim JÁ
-- derivado. As demais validações existentes são preservadas.
--
-- Cobre TODAS as vias de escrita em agendamentos:
--   * RPC administrativa admin_criar_agendamento / admin_atualizar_agendamento;
--   * Edge Function pública (criar-agendamento, via service-role);
--   * qualquer INSERT/UPDATE futuro.
--
-- Idempotente e seguro para reexecução. NÃO altera RLS, NÃO altera grants e
-- NÃO abre nenhuma permissão nova (não concede EXECUTE a ninguém).
-- ===========================================================================

-- -----------------------------------------------------------------------
-- 1) Função de derivação (SECURITY DEFINER, roda como dono / sem search_path)
-- -----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.derivar_duracao_agendamento()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_duracao integer;
BEGIN
    -- 1) Localiza o serviço pela combinação (servico_id, barbearia_id).
    -- 2) A duração vem DIRETO do banco — nunca do cliente.
    SELECT s.duracao_minutos
      INTO v_duracao
      FROM public.servicos s
     WHERE s.id = NEW.servico_id
       AND s.barbearia_id = NEW.barbearia_id;

    IF v_duracao IS NULL THEN
        RAISE EXCEPTION 'serviço inválido para o agendamento'
            USING ERRCODE = 'P0001';
    END IF;

    -- 3) Substitui o fim pelo valor calculado (qualquer fim enviado é ignorado).
    NEW.data_hora_fim := NEW.data_hora_inicio + make_interval(mins => v_duracao);
    RETURN NEW;
END;
$$;

-- -----------------------------------------------------------------------
-- 2) Trigger em public.agendamentos (dispara ANTES do validador de bloqueios)
-- -----------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_agendamentos_derivar_duracao ON public.agendamentos;
CREATE TRIGGER trg_agendamentos_derivar_duracao
    BEFORE INSERT OR UPDATE OF
        servico_id, data_hora_inicio, data_hora_fim
    ON public.agendamentos
    FOR EACH ROW EXECUTE FUNCTION public.derivar_duracao_agendamento();

-- -----------------------------------------------------------------------
-- 3) Privilégios mínimos (função de trigger não fica exposta)
-- -----------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.derivar_duracao_agendamento() FROM PUBLIC, anon;