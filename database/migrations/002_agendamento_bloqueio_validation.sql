-- ===========================================================================
-- MIGRATION 002 — Validação server-side obrigatória de agendamentos
-- (bloqueios gerais/específicos e horário de funcionamento) + serialização
-- para eliminar a "corrida" entre VERIFICAR e INSERIR.
--
-- Problema resolvido (auditoria A1):
--   A validação de bloqueios gerais (barbeiro_id IS NULL), bloqueios do
--   barbeiro e horário de funcionamento era feita por leitura ANTES do
--   INSERT (na Edge Function pública e, no fluxo admin, nem existia). Em
--   cenário concorrente, um agendamento podia ser confirmado num intervalo
--   que um bloqueio sobreposto deveria ter impedido.
--
-- Solução adotada (no banco — autoridade final, não depende do frontend):
--   1) Trigger BEFORE INSERT/UPDATE em public.agendamentos que:
--        * ignora linhas com status = 'cancelado' (não ocupam horário —
--          coerente com ux_agendamentos_sem_conflito);
--        * serializa a validação com um advisory lock xact por barbearia;
--        * revalida horário de funcionamento e bloqueios (geral + barbeiro);
--        * lança exceção se violar qualquer regra.
--   2) Trigger BEFORE INSERT/UPDATE em public.bloqueios_agenda que adquire o
--        MESMO advisory lock por barbearia. Assim, criar/editar um bloqueio é
--        mutuamente exclusivo com a validação de um agendamento concorrente:
--        ou o bloqueio commita antes (e o agendamento é barrado), ou o
--        agendamento commita antes (e o bloqueio vale dali em diante).
--      => impossível confirmar um agendamento que viole bloqueio / horário.
--   3) Coluna timezone em public.barbearias (default 'America/Sao_Paulo')
--        para a validação de horário usar o fuso local correto no servidor.
--
-- O mesmo trigger cobre TODAS as vias de escrita em agendamentos:
--   * Edge Function pública (criar-agendamento);
--   * RPC administrativa admin_criar_agendamento / admin_atualizar_agendamento;
--   * qualquer INSERT/UPDATE futuro.
--
-- Idempotente e seguro para reexecução. NÃO altera RLS, nem grants e NÃO
-- remove nenhuma proteção existente (mantém ux_agendamentos_sem_conflito).
-- ===========================================================================

-- -----------------------------------------------------------------------
-- 1) timezone em barbearias (fuso local típico por padrão)
-- -----------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name   = 'barbearias'
          AND column_name  = 'timezone'
    ) THEN
        ALTER TABLE public.barbearias
            ADD COLUMN timezone TEXT NOT NULL DEFAULT 'America/Sao_Paulo';
    END IF;
END $$;

UPDATE public.barbearias
   SET timezone = 'America/Sao_Paulo'
 WHERE timezone IS NULL OR timezone = '';

-- -----------------------------------------------------------------------
-- 2) Função de validação de agendamento (autoridade de negócio)
-- -----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.validar_agendamento_bloqueios()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_tz          text;
    v_dia         int;
    v_abertura    time;
    v_fechamento  time;
    v_fechado     boolean;
    v_inicio_min  int;
    v_fim_min     int;
    v_ab_min      int;
    v_fech_min    int;
    v_ts_inicio   timestamp;
    v_ts_fim      timestamp;
BEGIN
    -- Agendamentos cancelados não ocupam horário e não bloqueiam nada.
    IF NEW.status = 'cancelado' THEN
        RETURN NEW;
    END IF;

    -- Serializa a validação por barbearia, de forma mutuamente exclusiva com
    -- a criação/edição de bloqueios da mesma barbearia (trigger na seção 4).
    PERFORM pg_advisory_xact_lock(
        hashtextextended('barbearia_agenda:' || NEW.barbearia_id::text, 0)
    );

    -- 1) Fuso local da barbearia.
    SELECT b.timezone INTO v_tz
      FROM public.barbearias b
     WHERE b.id = NEW.barbearia_id;
    IF v_tz IS NULL OR v_tz = '' THEN
        v_tz := 'America/Sao_Paulo';
    END IF;

    -- 2) Horário de funcionamento do dia local do início.
    v_dia := extract(dow FROM (NEW.data_hora_inicio AT TIME ZONE v_tz))::int;

    SELECT h.hora_abertura, h.hora_fechamento, h.fechado
      INTO v_abertura, v_fechamento, v_fechado
      FROM public.horarios_funcionamento h
     WHERE h.barbearia_id = NEW.barbearia_id
       AND h.dia_semana = v_dia;

    IF NOT FOUND OR v_fechado THEN
        RAISE EXCEPTION 'Barbearia fechada neste dia.' USING ERRCODE = 'P0001';
    END IF;

    v_ab_min   := extract(hour FROM v_abertura)::int * 60
                   + extract(minute FROM v_abertura)::int;
    v_fech_min := extract(hour FROM v_fechamento)::int * 60
                   + extract(minute FROM v_fechamento)::int;

    v_ts_inicio := NEW.data_hora_inicio AT TIME ZONE v_tz;
    v_ts_fim    := NEW.data_hora_fim    AT TIME ZONE v_tz;

    v_inicio_min := extract(hour FROM v_ts_inicio)::int * 60
                     + extract(minute FROM v_ts_inicio)::int;
    v_fim_min    := extract(hour FROM v_ts_fim)::int * 60
                     + extract(minute FROM v_ts_fim)::int;

    IF v_inicio_min < v_ab_min OR v_fim_min > v_fech_min THEN
        RAISE EXCEPTION 'Este horário está fora do funcionamento da barbearia.'
            USING ERRCODE = 'P0001';
    END IF;

    -- 3) Bloqueios gerais (barbeiro_id IS NULL) e específicos do barbeiro.
    IF EXISTS (
        SELECT 1
          FROM public.bloqueios_agenda b
         WHERE b.barbearia_id = NEW.barbearia_id
           AND (b.barbeiro_id IS NULL OR b.barbeiro_id = NEW.barbeiro_id)
           AND b.inicio < NEW.data_hora_fim
           AND b.fim    > NEW.data_hora_inicio
    ) THEN
        RAISE EXCEPTION 'Este horário está bloqueado para este barbeiro.'
            USING ERRCODE = 'P0001';
    END IF;

    RETURN NEW;
END;
$$;

-- -----------------------------------------------------------------------
-- 3) Trigger em public.agendamentos (validação da autoridade)
-- -----------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_agendamentos_validar_bloqueios ON public.agendamentos;
CREATE TRIGGER trg_agendamentos_validar_bloqueios
    BEFORE INSERT OR UPDATE OF
        barbearia_id, barbeiro_id, data_hora_inicio, data_hora_fim, status
    ON public.agendamentos
    FOR EACH ROW EXECUTE FUNCTION public.validar_agendamento_bloqueios();

-- -----------------------------------------------------------------------
-- 4) Trigger em public.bloqueios_agenda (serialização com o passo 2)
-- -----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.serializar_bloqueio_barbearia()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    PERFORM pg_advisory_xact_lock(
        hashtextextended('barbearia_agenda:' || NEW.barbearia_id::text, 0)
    );
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_bloqueios_serializar ON public.bloqueios_agenda;
CREATE TRIGGER trg_bloqueios_serializar
    BEFORE INSERT OR UPDATE ON public.bloqueios_agenda
    FOR EACH ROW EXECUTE FUNCTION public.serializar_bloqueio_barbearia();

-- -----------------------------------------------------------------------
-- 5) Privilégios mínimos (funções de trigger não ficam expostas)
-- -----------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.validar_agendamento_bloqueios() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.serializar_bloqueio_barbearia() FROM PUBLIC, anon;
