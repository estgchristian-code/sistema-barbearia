-- ===========================================================================
-- TESTE — Migration 002 (validação server-side de bloqueios e horário)
--
-- Executar no Supabase SQL Editor DEPOIS de aplicar
--   database/migrations/002_agendamento_bloqueio_validation.sql
--
-- Este script é AUTOCONTIDO e SEGURO:
--   * usa UMA TRANSAÇÃO EXPLÍCITA (BEGIN ... ROLLBACK), sem depender do
--     autocommit nem do ROLLBACK implícito de DO block;
--   * cria uma barbearia/horário/serviço/barbeiro/cliente TÉCNICOS;
--   * valida os cenários abaixo e executa ROLLBACK ao final (nada persiste);
--   * se todas as asserções passarem, imprime 'SUCESSO: NN/NN';
--   * se alguma falhar, lança exceção (e a transação é revertida pelo ROLLBACK);
--   * o banco fica limpo após QUALQUER execução (sucesso ou falha).
--
-- Cenários cobertos:
--   1. agendamento VÁLIDO (dentro do horário, sem bloqueio) -> aceito;
--   2. agendamento FORA do horário de funcionamento -> rejeitado;
--   3. dia FECHADO (fechado = true) -> rejeitado;
--   4. bloqueio GERAL (barbeiro_id IS NULL) sobreposto -> rejeitado;
--   5. bloqueio ESPECÍFICO do barbeiro sobreposto -> rejeitado;
--   6. agendamento com status 'cancelado' mesmo sobre bloqueio -> aceito
--      (exceção correta, coerente com ux_agendamentos_sem_conflito).
--
-- Nota sobre o blasto CONCORRENTE:
--   A serialização usa pg_advisory_xact_lock por barbearia, compartilhado
--   entre o trigger de agendamentos e o de bloqueios_agenda. Isso torna a
--   criação/edição de bloqueio mutuamente exclusiva com a validação de um
--   agendamento concorrente. Um teste 100% concorrente exige DOIS clientes
--   SQL simultâneos (o roteiro roda dentro de uma única transação
--   BEGIN ... ROLLBACK) — ver a seção "TESTE CONCORRENTE (manual)" ao final.
-- ===========================================================================

BEGIN;

DO $$
DECLARE
    v_bar  barbearias.id%type;
    v_prof profissionais.id%type;
    v_srv  servicos.id%type;
    v_cli  clientes.id%type;
    v_inicio timestamptz;
    v_fim    timestamptz;
    c_total int := 0;
    c_ok    int := 0;
BEGIN
    -- ------------------------------------------------------------------
    -- SETUP (dados técnicos, apenas para o teste)
    -- ------------------------------------------------------------------
    INSERT INTO public.barbearias (nome, telefone, slug, timezone)
    VALUES ('Barbearia Teste Mig002', '(41) 99999-0000', 'barbearia-teste-mig002', 'America/Sao_Paulo')
    RETURNING id INTO v_bar;

    -- Segunda a sábado (1..6) abertos 08:00-18:00; domingo (0) fechado.
    -- Importante: o trigger valida o HORÁRIO antes do BLOQUEIO, então é preciso
    -- que o dia do teste esteja aberto para o cenário de bloqueio ser atingido.
    INSERT INTO public.horarios_funcionamento
        (barbearia_id, dia_semana, hora_abertura, hora_fechamento, fechado)
    VALUES
        (v_bar, 0, '08:00', '18:00', true),
        (v_bar, 1, '08:00', '18:00', false),
        (v_bar, 2, '08:00', '18:00', false),
        (v_bar, 3, '08:00', '18:00', false),
        (v_bar, 4, '08:00', '18:00', false),
        (v_bar, 5, '08:00', '18:00', false),
        (v_bar, 6, '08:00', '18:00', false);

    INSERT INTO public.profissionais (barbearia_id, nome, cargo, ativo)
    VALUES (v_bar, 'Barbeiro Teste', 'barbeiro', true)
    RETURNING id INTO v_prof;

    INSERT INTO public.servicos (barbearia_id, nome, preco, duracao_minutos, ativo)
    VALUES (v_bar, 'Corte Teste', 40.00, 30, true)
    RETURNING id INTO v_srv;

    INSERT INTO public.clientes (barbearia_id, nome, telefone, ativo)
    VALUES (v_bar, 'Cliente Teste', '41999990000', true)
    RETURNING id INTO v_cli;

    -- ------------------------------------------------------------------
    -- 1) VÁLIDO: segunda 09:00-09:30, aberto, sem bloqueio -> aceito
    -- ------------------------------------------------------------------
    v_inicio := timestamptz '2026-09-07 09:00:00 -03:00'; -- segunda-feira
    v_fim    := v_inicio + interval '30 minutes';
    BEGIN
        INSERT INTO public.agendamentos
            (barbearia_id, cliente_id, barbeiro_id, servico_id,
             data_hora_inicio, data_hora_fim, status)
        VALUES
            (v_bar, v_cli, v_prof, v_srv, v_inicio, v_fim, 'pendente');
        c_ok := c_ok + 1;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION '1.VÁLIDO falhou: %', SQLERRM;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 2) FORA do horário: segunda 19:00-19:30 (fecha 18:00) -> rejeitado
    -- ------------------------------------------------------------------
    v_inicio := timestamptz '2026-09-07 19:00:00 -03:00';
    v_fim    := v_inicio + interval '30 minutes';
    BEGIN
        INSERT INTO public.agendamentos
            (barbearia_id, cliente_id, barbeiro_id, servico_id,
             data_hora_inicio, data_hora_fim, status)
        VALUES
            (v_bar, v_cli, v_prof, v_srv, v_inicio, v_fim, 'pendente');
        RAISE EXCEPTION '2.FORA DO HORÁRIO foi aceito (deveria rejeitar)';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE '%fora do funcionamento%' THEN
                c_ok := c_ok + 1;
            ELSIF SQLERRM NOT LIKE '%2.FORA DO HORÁRIO foi aceito%' THEN
                RAISE EXCEPTION '2.FORA DO HORÁRIO: erro inesperado: %', SQLERRM;
            ELSE
                RAISE;
            END IF;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 3) DIA FECHADO: domingo -> rejeitado
    -- ------------------------------------------------------------------
    v_inicio := timestamptz '2026-09-06 10:00:00 -03:00'; -- domingo
    v_fim    := v_inicio + interval '30 minutes';
    BEGIN
        INSERT INTO public.agendamentos
            (barbearia_id, cliente_id, barbeiro_id, servico_id,
             data_hora_inicio, data_hora_fim, status)
        VALUES
            (v_bar, v_cli, v_prof, v_srv, v_inicio, v_fim, 'pendente');
        RAISE EXCEPTION '3.DIA FECHADO foi aceito (deveria rejeitar)';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE '%fechada neste dia%' THEN
                c_ok := c_ok + 1;
            ELSIF SQLERRM NOT LIKE '%3.DIA FECHADO foi aceito%' THEN
                RAISE EXCEPTION '3.DIA FECHADO: erro inesperado: %', SQLERRM;
            ELSE
                RAISE;
            END IF;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 4) BLOQUEIO GERAL (barbeiro_id IS NULL) -> rejeitado
    -- ------------------------------------------------------------------
    INSERT INTO public.bloqueios_agenda
        (barbearia_id, barbeiro_id, inicio, fim, motivo)
    VALUES
        (v_bar, NULL,
         timestamptz '2026-09-08 09:00:00 -03:00',
         timestamptz '2026-09-08 11:00:00 -03:00',
         'Bloqueio geral de teste');
    v_inicio := timestamptz '2026-09-08 10:00:00 -03:00'; -- terça, dentro do geral
    v_fim    := v_inicio + interval '30 minutes';
    BEGIN
        INSERT INTO public.agendamentos
            (barbearia_id, cliente_id, barbeiro_id, servico_id,
             data_hora_inicio, data_hora_fim, status)
        VALUES
            (v_bar, v_cli, v_prof, v_srv, v_inicio, v_fim, 'pendente');
        RAISE EXCEPTION '4.BLOQUEIO GERAL foi aceito (deveria rejeitar)';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE '%bloqueado para este barbeiro%' THEN
                c_ok := c_ok + 1;
            ELSIF SQLERRM NOT LIKE '%4.BLOQUEIO GERAL foi aceito%' THEN
                RAISE EXCEPTION '4.BLOQUEIO GERAL: erro inesperado: %', SQLERRM;
            ELSE
                RAISE;
            END IF;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 5) BLOQUEIO ESPECÍFICO do barbeiro -> rejeitado
    -- ------------------------------------------------------------------
    INSERT INTO public.bloqueios_agenda
        (barbearia_id, barbeiro_id, inicio, fim, motivo)
    VALUES
        (v_bar, v_prof,
         timestamptz '2026-09-09 14:00:00 -03:00',
         timestamptz '2026-09-09 15:00:00 -03:00',
         'Bloqueio específico de teste');
    v_inicio := timestamptz '2026-09-09 14:30:00 -03:00'; -- quarta, dentro do específico
    v_fim    := v_inicio + interval '30 minutes';
    BEGIN
        INSERT INTO public.agendamentos
            (barbearia_id, cliente_id, barbeiro_id, servico_id,
             data_hora_inicio, data_hora_fim, status)
        VALUES
            (v_bar, v_cli, v_prof, v_srv, v_inicio, v_fim, 'pendente');
        RAISE EXCEPTION '5.BLOQUEIO ESPECÍFICO foi aceito (deveria rejeitar)';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE '%bloqueado para este barbeiro%' THEN
                c_ok := c_ok + 1;
            ELSIF SQLERRM NOT LIKE '%5.BLOQUEIO ESPECÍFICO foi aceito%' THEN
                RAISE EXCEPTION '5.BLOQUEIO ESPECÍFICO: erro inesperado: %', SQLERRM;
            ELSE
                RAISE;
            END IF;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 6) status 'cancelado' sobre bloqueio -> aceito (exceção correta)
    -- ------------------------------------------------------------------
    v_inicio := timestamptz '2026-09-09 14:45:00 -03:00';
    v_fim    := v_inicio + interval '30 minutes';
    BEGIN
        INSERT INTO public.agendamentos
            (barbearia_id, cliente_id, barbeiro_id, servico_id,
             data_hora_inicio, data_hora_fim, status)
        VALUES
            (v_bar, v_cli, v_prof, v_srv, v_inicio, v_fim, 'cancelado');
        c_ok := c_ok + 1;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION '6.CANCELADO sobre bloqueio falhou: %', SQLERRM;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- RESULTADO
    -- ------------------------------------------------------------------
    IF c_ok <> c_total THEN
        RAISE EXCEPTION 'FALHA: apenas %/% asserções passaram', c_ok, c_total;
    END IF;

    RAISE NOTICE 'SUCESSO: %/% asserções passaram (ROLLBACK será executado em seguida; nada será persistido)', c_ok, c_total;
END $$;

ROLLBACK;


-- ===========================================================================
-- TESTE CONCORRENTE (manual — requer DOIS clientes SQL simultâneos)
-- ===========================================================================
--
-- A serialização é feita com pg_advisory_xact_lock por barbearia em AMBOS os
-- triggers (agendamentos e bloqueios_agenda). Para validar na prática o
-- fechamento da corrida "verificar → inserir":
--
-- Sessão A (adiciona um bloqueio geral):
--   BEGIN;
--   INSERT INTO public.bloqueios_agenda
--       (barbearia_id, barbeiro_id, inicio, fim, motivo)
--   VALUES (<id>, NULL, '2026-09-08 09:00 -03', '2026-09-08 11:00 -03', 'geral');
--   SELECT pg_sleep(10);          -- segura o advisory lock por 10s
--   COMMIT;
--
-- Sessão B (tenta confirmar agendamento no mesmo intervalo, logo em seguida):
--   BEGIN;
--   INSERT INTO public.agendamentos
--       (barbearia_id, cliente_id, barbeiro_id, servico_id,
--        data_hora_inicio, data_hora_fim, status)
--   VALUES (<id>, <cli>, <prof>, <srv>,
--           '2026-09-08 10:00 -03', '2026-09-08 10:30 -03', 'pendente');
--
-- Resultado esperado: a sessão B BLOQUEIA atrás do advisory lock da sessão A e,
-- assim que A commita, o trigger de B revalida e LANÇA
--   'Este horário está bloqueado para este barbeiro.'
-- (revertendo o INSERT) — ou seja, o agendamento nunca é confirmado num
-- intervalo que o bloqueio geral cobre. Sem a serialização, ambas as sessões
-- passariam pela verificação e ambos os commits seriam aceitos.
-- ===========================================================================
