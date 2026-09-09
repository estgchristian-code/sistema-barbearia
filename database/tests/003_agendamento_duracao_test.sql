-- ===========================================================================
-- TESTE — Migration 003 (duração do agendamento derivada do serviço)
--
-- Executar no PostgreSQL local (ou no Supabase SQL Editor) DEPOIS de aplicar
--   database/migrations/003_agendamento_duracao.sql
--
-- Este script é AUTOCONTIDO e SEGURO:
--   * usa UMA TRANSAÇÃO EXPLÍCITA (BEGIN ... ROLLBACK), sem depender do
--     autocommit nem do ROLLBACK implícito de DO block;
--   * cria barbearias/horários/serviços/barbeiros/clientes TÉCNICOS;
--   * valida os cenários abaixo e executa ROLLBACK ao final (nada persiste);
--   * se todas as asserções passarem, imprime 'SUCESSO: NN/NN';
--   * se alguma falhar, lança exceção (e a transação é revertida pelo ROLLBACK);
--   * o banco fica limpo após QUALQUER execução (sucesso ou falha).
--
-- Cenários cobertos (regra: data_hora_fim = inicio + servicos.duracao_minutos):
--   1. serviço de 30 min + início 14:00 + fim enviado 14:30    -> aceito, fim 14:30;
--   2. serviço de 30 min + fim enviado 15:00                    -> aceito, fim DERIVADO 14:30;
--   3. alterar SOMENTE o fim para valor arbitrário              -> fim continua 14:30;
--   4. alterar servico_id (30 -> 45 min)                        -> fim recalculado 14:45;
--   5. alterar data_hora_inicio (para 15:00)                    -> fim recalculado 15:45;
--   6. serviço INEXISTENTE / de OUTRA barbearia                 -> rejeitado;
--   7. regressão: horário de funcionamento (fora do horário)    -> rejeitado;
--   8. regressão: bloqueio geral (barbeiro_id IS NULL)          -> rejeitado.
--
-- Total: 9 asserções.
-- ===========================================================================

BEGIN;

DO $$
DECLARE
    v_bar        barbearias.id%type;
    v_bar2       barbearias.id%type;
    v_prof_a     profissionais.id%type;
    v_prof_b     profissionais.id%type;
    v_srv30      servicos.id%type;
    v_srv45      servicos.id%type;
    v_srv_outra  servicos.id%type;
    v_cli        clientes.id%type;
    v_id1        agendamentos.id%type;
    v_id2        agendamentos.id%type;
    v_inicio     timestamptz;
    v_inicio2    timestamptz;
    v_fim_verif  timestamptz;
    c_total      int := 0;
    c_ok         int := 0;
BEGIN
    -- ------------------------------------------------------------------
    -- SETUP (dados técnicos, apenas para o teste)
    -- ------------------------------------------------------------------
    INSERT INTO public.barbearias (nome, telefone, slug, timezone)
    VALUES ('Barbearia Teste Mig003', '(41) 99999-0000', 'barbearia-teste-mig003', 'America/Sao_Paulo')
    RETURNING id INTO v_bar;

    -- Segunda a sábado (1..6) abertos 08:00-18:00; domingo (0) fechado.
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
    VALUES (v_bar, 'Barbeiro A Teste', 'barbeiro', true)
    RETURNING id INTO v_prof_a;

    INSERT INTO public.profissionais (barbearia_id, nome, cargo, ativo)
    VALUES (v_bar, 'Barbeiro B Teste', 'barbeiro', true)
    RETURNING id INTO v_prof_b;

    INSERT INTO public.servicos (barbearia_id, nome, preco, duracao_minutos, ativo)
    VALUES (v_bar, 'Corte Teste 30min', 40.00, 30, true)
    RETURNING id INTO v_srv30;

    INSERT INTO public.servicos (barbearia_id, nome, preco, duracao_minutos, ativo)
    VALUES (v_bar, 'Corte + Barba 45min', 70.00, 45, true)
    RETURNING id INTO v_srv45;

    INSERT INTO public.clientes (barbearia_id, nome, telefone, ativo)
    VALUES (v_bar, 'Cliente Teste', '41999990000', true)
    RETURNING id INTO v_cli;

    -- Segunda barbearia (para o teste de serviço de OUTRA barbearia).
    INSERT INTO public.barbearias (nome, telefone, slug, timezone)
    VALUES ('Barbearia Outra Teste', '(41) 98888-0000', 'barbearia-outra-mig003', 'America/Sao_Paulo')
    RETURNING id INTO v_bar2;

    INSERT INTO public.servicos (barbearia_id, nome, preco, duracao_minutos, ativo)
    VALUES (v_bar2, 'Corte Outsider', 50.00, 20, true)
    RETURNING id INTO v_srv_outra;

    -- ------------------------------------------------------------------
    -- 1) INSERT VÁLIDO: 14:00 + fim enviado 14:30 (30 min) -> aceito, fim 14:30
    -- ------------------------------------------------------------------
    v_inicio := timestamptz '2026-09-14 14:00:00 -03:00'; -- segunda-feira
    BEGIN
        INSERT INTO public.agendamentos
            (barbearia_id, cliente_id, barbeiro_id, servico_id,
             data_hora_inicio, data_hora_fim, status)
        VALUES
            (v_bar, v_cli, v_prof_a, v_srv30, v_inicio,
             v_inicio + interval '30 minutes', 'pendente')
        RETURNING id INTO v_id1;

        SELECT a.data_hora_fim INTO v_fim_verif
          FROM public.agendamentos a
         WHERE a.id = v_id1;

        IF v_fim_verif <> v_inicio + interval '30 minutes' THEN
            RAISE EXCEPTION '1.VÁLIDO: fim incorreto -> % (esperado 14:30)', v_fim_verif;
        END IF;
        c_ok := c_ok + 1;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION '1.VÁLIDO falhou: %', SQLERRM;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 2) FIM ARBITRÁRIO no INSERT: fim enviado 15:00 -> DERIVADO 14:30
    -- ------------------------------------------------------------------
    BEGIN
        INSERT INTO public.agendamentos
            (barbearia_id, cliente_id, barbeiro_id, servico_id,
             data_hora_inicio, data_hora_fim, status)
        VALUES
            (v_bar, v_cli, v_prof_b, v_srv30, v_inicio,
             timestamptz '2026-09-14 15:00:00 -03:00', 'pendente')
        RETURNING id INTO v_id2;

        SELECT a.data_hora_fim INTO v_fim_verif
          FROM public.agendamentos a
         WHERE a.id = v_id2;

        IF v_fim_verif <> v_inicio + interval '30 minutes' THEN
            RAISE EXCEPTION '2.FIM ARBITRÁRIO: fim incorreto -> % (esperado 14:30)', v_fim_verif;
        END IF;
        c_ok := c_ok + 1;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION '2.FIM ARBITRÁRIO falhou: %', SQLERRM;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 3) UPDATE SOMENTE do fim (16:00) -> continua 14:30
    -- ------------------------------------------------------------------
    BEGIN
        UPDATE public.agendamentos a
           SET data_hora_fim = timestamptz '2026-09-14 16:00:00 -03:00'
         WHERE a.id = v_id1;

        SELECT a.data_hora_fim INTO v_fim_verif
          FROM public.agendamentos a
         WHERE a.id = v_id1;

        IF v_fim_verif <> v_inicio + interval '30 minutes' THEN
            RAISE EXCEPTION '3.UPDATE SÓ FIM: fim incorreto -> % (esperado 14:30)', v_fim_verif;
        END IF;
        c_ok := c_ok + 1;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION '3.UPDATE SÓ FIM falhou: %', SQLERRM;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 4) UPDATE do servico_id (30 -> 45 min) -> fim recalculado 14:45
    -- ------------------------------------------------------------------
    BEGIN
        UPDATE public.agendamentos a
           SET servico_id = v_srv45
         WHERE a.id = v_id1;

        SELECT a.data_hora_fim INTO v_fim_verif
          FROM public.agendamentos a
         WHERE a.id = v_id1;

        IF v_fim_verif <> v_inicio + interval '45 minutes' THEN
            RAISE EXCEPTION '4.UPDATE SERVIÇO: fim incorreto -> % (esperado 14:45)', v_fim_verif;
        END IF;
        c_ok := c_ok + 1;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION '4.UPDATE SERVIÇO falhou: %', SQLERRM;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 5) UPDATE do data_hora_inicio (para 15:00) -> fim recalculado 15:45
    -- ------------------------------------------------------------------
    v_inicio2 := timestamptz '2026-09-14 15:00:00 -03:00';
    BEGIN
        UPDATE public.agendamentos a
           SET data_hora_inicio = v_inicio2
         WHERE a.id = v_id1;

        SELECT a.data_hora_fim INTO v_fim_verif
          FROM public.agendamentos a
         WHERE a.id = v_id1;

        IF v_fim_verif <> v_inicio2 + interval '45 minutes' THEN
            RAISE EXCEPTION '5.UPDATE INÍCIO: fim incorreto -> % (esperado 15:45)', v_fim_verif;
        END IF;
        c_ok := c_ok + 1;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION '5.UPDATE INÍCIO falhou: %', SQLERRM;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 6a) SERVIÇO INEXISTENTE -> rejeitado
    -- ------------------------------------------------------------------
    BEGIN
        INSERT INTO public.agendamentos
            (barbearia_id, cliente_id, barbeiro_id, servico_id,
             data_hora_inicio, data_hora_fim, status)
        VALUES
            (v_bar, v_cli, v_prof_a, 999999,
             timestamptz '2026-09-14 16:00:00 -03:00',
             timestamptz '2026-09-14 16:30:00 -03:00', 'pendente');
        RAISE EXCEPTION '6a.SERVIÇO INEXISTENTE foi aceito (deveria rejeitar)';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE '%serviço inválido%' THEN
                c_ok := c_ok + 1;
            ELSIF SQLERRM NOT LIKE '%6a.SERVIÇO INEXISTENTE foi aceito%' THEN
                RAISE EXCEPTION '6a.SERVIÇO INEXISTENTE: erro inesperado: %', SQLERRM;
            ELSE
                RAISE;
            END IF;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 6b) SERVIÇO DE OUTRA BARBEARIA -> rejeitado
    -- ------------------------------------------------------------------
    BEGIN
        INSERT INTO public.agendamentos
            (barbearia_id, cliente_id, barbeiro_id, servico_id,
             data_hora_inicio, data_hora_fim, status)
        VALUES
            (v_bar, v_cli, v_prof_a, v_srv_outra,
             timestamptz '2026-09-14 16:00:00 -03:00',
             timestamptz '2026-09-14 16:30:00 -03:00', 'pendente');
        RAISE EXCEPTION '6b.SERVIÇO DE OUTRA BARBEARIA foi aceito (deveria rejeitar)';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE '%serviço inválido%' THEN
                c_ok := c_ok + 1;
            ELSIF SQLERRM NOT LIKE '%6b.SERVIÇO DE OUTRA BARBEARIA foi aceito%' THEN
                RAISE EXCEPTION '6b.SERVIÇO DE OUTRA BARBEARIA: erro inesperado: %', SQLERRM;
            ELSE
                RAISE;
            END IF;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 7) REGRESSÃO: FORA do horário (19:00, fecha 18:00) -> rejeitado
    -- ------------------------------------------------------------------
    BEGIN
        INSERT INTO public.agendamentos
            (barbearia_id, cliente_id, barbeiro_id, servico_id,
             data_hora_inicio, data_hora_fim, status)
        VALUES
            (v_bar, v_cli, v_prof_b, v_srv30,
             timestamptz '2026-09-14 19:00:00 -03:00',
             timestamptz '2026-09-14 19:30:00 -03:00', 'pendente');
        RAISE EXCEPTION '7.FORA DO HORÁRIO foi aceito (deveria rejeitar)';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE '%fora do funcionamento%' THEN
                c_ok := c_ok + 1;
            ELSIF SQLERRM NOT LIKE '%7.FORA DO HORÁRIO foi aceito%' THEN
                RAISE EXCEPTION '7.FORA DO HORÁRIO: erro inesperado: %', SQLERRM;
            ELSE
                RAISE;
            END IF;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 8) REGRESSÃO: BLOQUEIO GERAL (barbeiro_id IS NULL) -> rejeitado
    -- ------------------------------------------------------------------
    INSERT INTO public.bloqueios_agenda
        (barbearia_id, barbeiro_id, inicio, fim, motivo)
    VALUES
        (v_bar, NULL,
         timestamptz '2026-09-15 09:00:00 -03:00',
         timestamptz '2026-09-15 11:00:00 -03:00',
         'Bloqueio geral de teste');
    BEGIN
        INSERT INTO public.agendamentos
            (barbearia_id, cliente_id, barbeiro_id, servico_id,
             data_hora_inicio, data_hora_fim, status)
        VALUES
            (v_bar, v_cli, v_prof_a, v_srv30,
             timestamptz '2026-09-15 10:00:00 -03:00',
             timestamptz '2026-09-15 10:30:00 -03:00', 'pendente');
        RAISE EXCEPTION '8.BLOQUEIO GERAL foi aceito (deveria rejeitar)';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE '%bloqueado para este barbeiro%' THEN
                c_ok := c_ok + 1;
            ELSIF SQLERRM NOT LIKE '%8.BLOQUEIO GERAL foi aceito%' THEN
                RAISE EXCEPTION '8.BLOQUEIO GERAL: erro inesperado: %', SQLERRM;
            ELSE
                RAISE;
            END IF;
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