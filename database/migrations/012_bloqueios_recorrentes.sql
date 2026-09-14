-- =====================================================================
-- MIGRATION 012 — BLOQUEIOS RECORRENTES POR DIA DA SEMANA
-- =====================================================================
-- Objetivo: permitir bloqueios que se repetem toda semana em dias
-- específicos, mantendo os bloqueios pontuais atuais funcionando
-- exatamente como hoje.
--
-- Exemplo:
--   12:00–13:00, segunda a sábado, todos os barbeiros, motivo "Almoço"
--
-- Abordagem (revisada e aprovada):
--   1) Duas colunas novas em public.bloqueios_agenda:
--        recorrencia_dias INT[] — dias da semana [0=Dom .. 6=Sáb];
--                                  NULL = bloqueio PONTUAL (comportamento antigo);
--        recorrencia_fim  DATE  — última data em que a recorrência vale;
--                                  NULL = sem fim.
--   2) Bloqueios pontuais (recorrencia_dias IS NULL) seguem idênticos.
--   3) A validação A1 (validar_agendamento_bloqueios) ganha uma perna
--      adicional: se o dia da semana do agendamento estiver em
--      recorrencia_dias E o horário-do-dia (no fuso local da barbearia)
--      sobrepuser o bloco, o agendamento é barrado.
--      Para o RECORRENTE apenas o HORÁRIO DO DIA de inicio/fim importa
--      (a data dos campos é só referência/origem).
--
-- Regras:
--   * Nenhum job/cron: a recorrência é avaliada na validação (A1), que é
--     a autoridade final — sem gerar registros futuros.
--   * Não altera RLS, nem grants, nem o advisory lock existente.
--   * Idempotente e seguro para reexecução.
-- =====================================================================

-- ----------------------------------------------------------------------
-- 1. COLUNAS NOVAS (idempotente)
-- ----------------------------------------------------------------------
ALTER TABLE public.bloqueios_agenda
    ADD COLUMN IF NOT EXISTS recorrencia_dias INT[], -- NULL = pontual
    ADD COLUMN IF NOT EXISTS recorrencia_fim  DATE; -- NULL = sem fim

COMMENT ON COLUMN public.bloqueios_agenda.recorrencia_dias IS
  'Dias da semana da recorrência (0=Dom .. 6=Sáb). NULL = bloqueio pontual (intervalo único).';
COMMENT ON COLUMN public.bloqueios_agenda.recorrencia_fim IS
  'Última data em que a recorrência vale. NULL = recorrência sem fim.';

-- ----------------------------------------------------------------------
-- 2. CONSTRAINTS
-- ----------------------------------------------------------------------
-- * Quando recorrente: de 1 a 7 dias, todos entre 0 e 6.
-- * recorrencia_fim, quando informada, deve ser >= à data de origem.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'chk_bloqueios_recorrencia_dias'
          AND conrelid = 'public.bloqueios_agenda'::regclass
    ) THEN
        ALTER TABLE public.bloqueios_agenda
            ADD CONSTRAINT chk_bloqueios_recorrencia_dias
            CHECK (
                recorrencia_dias IS NULL OR (
                    cardinality(recorrencia_dias) BETWEEN 1 AND 7
                    AND recorrencia_dias <@ ARRAY[0,1,2,3,4,5,6]::int[]
                )
            );
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'chk_bloqueios_recorrencia_fim'
          AND conrelid = 'public.bloqueios_agenda'::regclass
    ) THEN
        ALTER TABLE public.bloqueios_agenda
            ADD CONSTRAINT chk_bloqueios_recorrencia_fim
            CHECK (
                recorrencia_fim IS NULL OR recorrencia_fim >= inicio::date
            );
    END IF;
END $$;

-- ----------------------------------------------------------------------
-- 3. A1 — validar_agendamento_bloqueios (recorrência + pontual)
-- ----------------------------------------------------------------------
-- Mantém o advisory lock, o horário de funcionamento, a regra de
-- cancelado e TODAS as validações existentes. A perna de bloqueios
-- pontuais é idêntica à original (agora com o filtro recorrencia_dias
-- IS NULL, para não misturar os dois tipos na comparação de timestamps).
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

    -- 3) Bloqueios PONTUAIS (recorrencia_dias IS NULL) — comparação exata de
    -- timestamps (sobreposição real), idêntica à validação original.
    IF EXISTS (
        SELECT 1
          FROM public.bloqueios_agenda b
         WHERE b.barbearia_id = NEW.barbearia_id
           AND b.recorrencia_dias IS NULL
           AND (b.barbeiro_id IS NULL OR b.barbeiro_id = NEW.barbeiro_id)
           AND b.inicio < NEW.data_hora_fim
           AND b.fim    > NEW.data_hora_inicio
    ) THEN
        RAISE EXCEPTION 'Este horário está bloqueado para este barbeiro.'
            USING ERRCODE = 'P0001';
    END IF;

    -- 3b) Bloqueios RECORRENTES (recorrencia_dias IS NOT NULL): repetem toda
    -- semana naqueles dias da semana, no horário-do-dia de inicio~fim (a data
    -- dos campos é só referência), até recorrencia_fim quando informada.
    -- O dia da semana e os minutos são calculados no FUSO LOCAL da barbearia.
    IF EXISTS (
        SELECT 1
          FROM public.bloqueios_agenda b
          CROSS JOIN LATERAL (
              SELECT (extract(hour FROM b.inicio)::int * 60
                      + extract(minute FROM b.inicio)::int) AS b_ini,
                     (extract(hour FROM b.fim)::int * 60
                      + extract(minute FROM b.fim)::int)    AS b_fim
          ) t
         WHERE b.barbearia_id = NEW.barbearia_id
           AND b.recorrencia_dias IS NOT NULL
           AND (b.barbeiro_id IS NULL OR b.barbeiro_id = NEW.barbeiro_id)
           AND (b.recorrencia_fim IS NULL
                OR b.recorrencia_fim >= (NEW.data_hora_inicio AT TIME ZONE v_tz)::date)
           AND v_dia = ANY (b.recorrencia_dias)
           AND (
               -- Bloqueio no mesmo dia do agendamento: sobreposição simples.
               (t.b_ini < v_fim_min AND t.b_fim > v_inicio_min)
               OR
               -- Bloqueio que cruza a meia-noite (fim "antes" do início no
               -- relógio): conflita se o agendamento cai depois do início
               -- OU antes do fim.
               (t.b_fim <= t.b_ini
                AND (v_inicio_min < t.b_fim OR v_fim_min > t.b_ini))
           )
    ) THEN
        RAISE EXCEPTION 'Este horário está bloqueado para este barbeiro.'
            USING ERRCODE = 'P0001';
    END IF;

    RETURN NEW;
END;
$$;

-- ----------------------------------------------------------------------
-- 4. Privilégios mínimos (funções de trigger não ficam expostas)
-- ----------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.validar_agendamento_bloqueios() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.serializar_bloqueio_barbearia() FROM PUBLIC, anon;