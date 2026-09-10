-- ===========================================================================
-- TESTE — Migration 006 (barbeiro pode CADASTRAR clientes, servidor confiável)
--
-- Executar no PostgreSQL local (ou no Supabase SQL Editor) DEPOIS de aplicar
--   database/migrations/006_barbeiro_criar_cliente.sql
--
-- Este script é AUTOCONTIDO e SEGURO:
--   * usa UMA TRANSAÇÃO EXPLÍCITA (BEGIN ... ROLLBACK);
--   * cria barbearias/horários/serviços/barbeiros TÉCNICOS;
--   * simula o usuário logado via set_config('request.jwt.claims', ...),
--     como na seção 13 do rls.sql (auth.uid() lê o 'sub' do JWT);
--   * valida os cenários abaixo e executa ROLLBACK ao final (nada persiste);
--   * se todas as asserções passarem, imprime 'SUCESSO: NN/NN'.
--
-- Cenários cobertos (12 asserções):
--   1.  BARBEIRO cria cliente VÁLIDO            -> barbearia = a própria,
--       ativo = true, sem depender de poder administrativo;
--   2.  BARBEIRO tenta criar ativo = false      -> SERVIDOR FORÇA ativo = true
--       (barbeiro não tem poder administrativo);
--   3.  ADMIN cria cliente ativo = false        -> PERMITIDO (controle do
--       admin preservado); ativo continua false;
--   4.  ADMIN cria cliente válido (com e-mail)  -> ok (regressão admin);
--   5.  USUÁRIO SEM VÍNCULO a profissional      -> rejeitado;
--   6.  PROFISSIONAL INATIVO                    -> rejeitado;
--   7.  NOME vazio                              -> rejeitado ('nome do cliente
--       é obrigatório');
--   8.  TELEFONE vazio                          -> rejeitado ('telefone do
--       cliente é obrigatório');
--   9.  E-MAIL malformado                       -> rejeitado ('e-mail inválido');
--   10. ISOLAMENTO: barbeiro da barbearia B cria -> registra na PRÓPRIA B
--       (nunca em A);
--   11. cliente criado pelo barbeiro é usado num AGENDAMENTO (regressão M004);
--   12. listar_clientes_da_barbearia devolve SÓ os da própria barbearia
--       (incl. recém-criados) e NADA de outra barbearia.
--
-- A inexistência de INSERT direto em clientes para authenticated é verificada
-- à parte (grants) — ver seção "VERIFICAÇÃO: INSERT DIRETO" ao final.
-- ===========================================================================

BEGIN;

DO $$
DECLARE
    v_bar          barbearias.id%type;
    v_bar2         barbearias.id%type;
    v_admin        profissionais.id%type;
    v_prof_a       profissionais.id%type;
    v_prof_b       profissionais.id%type;
    v_prof_inativo profissionais.id%type;
    v_srv30        servicos.id%type;
    v_cli_novo     clientes.id%type;
    v_cliente      public.clientes;
    v_ag           public.agendamentos;
    v_inicio       timestamptz;
    v_n            int;
    c_total        int := 0;
    c_ok           int := 0;

    -- Identidades fictícias do Supabase Auth (a partir do 'sub' do JWT).
    j_admin    constant text := '00000000-0000-0000-0000-0000000000b1';
    j_prof_a   constant text := '00000000-0000-0000-0000-0000000000b2';
    j_prof_b   constant text := '00000000-0000-0000-0000-0000000000b3';
    j_inativo  constant text := '00000000-0000-0000-0000-0000000000b4';
    j_solto    constant text := '00000000-0000-0000-0000-0000000000b5';
BEGIN
    -- ------------------------------------------------------------------
    -- SETUP (dados técnicos, apenas para o teste)
    -- ------------------------------------------------------------------
    INSERT INTO public.barbearias (nome, telefone, slug, timezone)
    VALUES ('Barbearia Teste Mig006 A', '(41) 99999-0100', 'barbearia-teste-mig006-a', 'America/Sao_Paulo')
    RETURNING id INTO v_bar;

    -- Segunda a sábado abertos (necessário ao cenário 11).
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

    INSERT INTO auth.users (id) VALUES
        (j_admin::uuid),
        (j_prof_a::uuid),
        (j_prof_b::uuid),
        (j_inativo::uuid);

    INSERT INTO public.profissionais (barbearia_id, nome, cargo, ativo, auth_user_id)
    VALUES (v_bar, 'Admin Teste 006', 'admin', true, j_admin::uuid)
    RETURNING id INTO v_admin;

    INSERT INTO public.profissionais (barbearia_id, nome, cargo, ativo, auth_user_id)
    VALUES (v_bar, 'Barbeiro A Teste 006', 'barbeiro', true, j_prof_a::uuid)
    RETURNING id INTO v_prof_a;

    INSERT INTO public.profissionais (barbearia_id, nome, cargo, ativo, auth_user_id)
    VALUES (v_bar, 'Barbeiro Inativo Teste 006', 'barbeiro', false, j_inativo::uuid)
    RETURNING id INTO v_prof_inativo;

    INSERT INTO public.servicos (barbearia_id, nome, preco, duracao_minutos, ativo)
    VALUES (v_bar, 'Corte Teste 006 30min', 40.00, 30, true)
    RETURNING id INTO v_srv30;

    -- Barbearia B (dados alheios — o barbeiro de B cria SÓ na própria B).
    INSERT INTO public.barbearias (nome, telefone, slug, timezone)
    VALUES ('Barbearia Teste Mig006 B', '(41) 98888-0100', 'barbearia-teste-mig006-b', 'America/Sao_Paulo')
    RETURNING id INTO v_bar2;

    INSERT INTO public.profissionais (barbearia_id, nome, cargo, ativo, auth_user_id)
    VALUES (v_bar2, 'Barbeiro B Teste 006', 'barbeiro', true, j_prof_b::uuid)
    RETURNING id INTO v_prof_b;

    -- ------------------------------------------------------------------
    -- 1) BARBEIRO A cria cliente VÁLIDO -> própria barbearia, ativo = true
    -- ------------------------------------------------------------------
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated","iat":1710000000,"exp":1710003600}', j_prof_a), true);
    BEGIN
        SELECT * INTO v_cliente FROM public.criar_cliente('Cliente do Barbeiro', '41999990101', 'cliente@teste.com', 'regular');

        IF v_cliente.id IS NULL
           OR v_cliente.barbearia_id <> v_bar
           OR v_cliente.ativo <> true
           OR v_cliente.nome <> 'Cliente do Barbeiro'
           OR v_cliente.email <> 'cliente@teste.com' THEN
            RAISE EXCEPTION '1.VÁLIDO: dados incorretos (barbearia=%, ativo=%, nome=%)',
                v_cliente.barbearia_id, v_cliente.ativo, v_cliente.nome;
        END IF;
        v_cli_novo := v_cliente.id;
        c_ok := c_ok + 1;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION '1.VÁLIDO falhou: %', SQLERRM;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 2) BARBEIRO tenta ativo = false -> SERVIDOR FORÇA true
    -- ------------------------------------------------------------------
    BEGIN
        SELECT * INTO v_cliente FROM public.criar_cliente('Cliente Forçado Ativo', '41999990102', NULL, NULL, false);

        IF v_cliente.ativo <> true OR v_cliente.barbearia_id <> v_bar THEN
            RAISE EXCEPTION '2.ATIVO FORÇADO: ativo=% (esperado true)', v_cliente.ativo;
        END IF;
        c_ok := c_ok + 1;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION '2.ATIVO FORÇADO falhou: %', SQLERRM;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 3) ADMIN cria ativo = false -> PERMITIDO (controle preservado)
    -- ------------------------------------------------------------------
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated","iat":1710000000,"exp":1710003600}', j_admin), true);
    BEGIN
        SELECT * INTO v_cliente FROM public.criar_cliente('Cliente Inativo do Admin', '41999990103', NULL, NULL, false);

        IF v_cliente.ativo <> false OR v_cliente.barbearia_id <> v_bar THEN
            RAISE EXCEPTION '3.ADMIN INATIVO: ativo=% (esperado false)', v_cliente.ativo;
        END IF;
        c_ok := c_ok + 1;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION '3.ADMIN INATIVO falhou: %', SQLERRM;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 4) ADMIN cria VÁLIDO (sem e-mail/obs) -> regressão do fluxo admin
    -- ------------------------------------------------------------------
    BEGIN
        SELECT * INTO v_cliente FROM public.criar_cliente('Cliente do Admin', '41999990104');

        IF v_cliente.ativo <> true OR v_cliente.barbearia_id <> v_bar THEN
            RAISE EXCEPTION '4.ADMIN VÁLIDO: ativo=%', v_cliente.ativo;
        END IF;
        c_ok := c_ok + 1;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION '4.ADMIN VÁLIDO falhou: %', SQLERRM;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 5) USUÁRIO SEM VÍNCULO A profissional -> rejeitado
    -- ------------------------------------------------------------------
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated","iat":1710000000,"exp":1710003600}', j_solto), true);
    BEGIN
        BEGIN
            PERFORM public.criar_cliente('Sem Vinculo', '41999990105');
            RAISE EXCEPTION '5.SEM VÍNCULO foi aceito (deveria rejeitar)';
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLERRM LIKE '%somente um profissional ativo%' THEN
                    c_ok := c_ok + 1;
                ELSIF SQLERRM NOT LIKE '%5.SEM VÍNCULO foi aceito%' THEN
                    RAISE EXCEPTION '5.SEM VÍNCULO: erro inesperado: %', SQLERRM;
                ELSE
                    RAISE;
                END IF;
        END;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 6) PROFISSIONAL INATIVO -> rejeitado
    -- ------------------------------------------------------------------
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated","iat":1710000000,"exp":1710003600}', j_inativo), true);
    BEGIN
        BEGIN
            PERFORM public.criar_cliente('Barbeiro Inativo', '41999990106');
            RAISE EXCEPTION '6.INATIVO foi aceito (deveria rejeitar)';
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLERRM LIKE '%somente um profissional ativo%' THEN
                    c_ok := c_ok + 1;
                ELSIF SQLERRM NOT LIKE '%6.INATIVO foi aceito%' THEN
                    RAISE EXCEPTION '6.INATIVO: erro inesperado: %', SQLERRM;
                ELSE
                    RAISE;
                END IF;
        END;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 7) NOME vazio -> rejeitado
    -- ------------------------------------------------------------------
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated","iat":1710000000,"exp":1710003600}', j_prof_a), true);
    BEGIN
        BEGIN
            PERFORM public.criar_cliente('   ', '41999990107');
            RAISE EXCEPTION '7.NOME VAZIO foi aceito (deveria rejeitar)';
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLERRM LIKE '%nome do cliente é obrigatório%' THEN
                    c_ok := c_ok + 1;
                ELSIF SQLERRM NOT LIKE '%7.NOME VAZIO foi aceito%' THEN
                    RAISE EXCEPTION '7.NOME VAZIO: erro inesperado: %', SQLERRM;
                ELSE
                    RAISE;
                END IF;
        END;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 8) TELEFONE vazio -> rejeitado
    -- ------------------------------------------------------------------
    BEGIN
        BEGIN
            PERFORM public.criar_cliente('Sem Telefone', '  ');
            RAISE EXCEPTION '8.TELEFONE VAZIO foi aceito (deveria rejeitar)';
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLERRM LIKE '%telefone do cliente é obrigatório%' THEN
                    c_ok := c_ok + 1;
                ELSIF SQLERRM NOT LIKE '%8.TELEFONE VAZIO foi aceito%' THEN
                    RAISE EXCEPTION '8.TELEFONE VAZIO: erro inesperado: %', SQLERRM;
                ELSE
                    RAISE;
                END IF;
        END;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 9) E-MAIL malformado -> rejeitado
    -- ------------------------------------------------------------------
    BEGIN
        BEGIN
            PERFORM public.criar_cliente('Email Ruim', '41999990109', 'nao-e-email');
            RAISE EXCEPTION '9.E-MAIL RUIM foi aceito (deveria rejeitar)';
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLERRM LIKE '%e-mail inválido%' THEN
                    c_ok := c_ok + 1;
                ELSIF SQLERRM NOT LIKE '%9.E-MAIL RUIM foi aceito%' THEN
                    RAISE EXCEPTION '9.E-MAIL RUIM: erro inesperado: %', SQLERRM;
                ELSE
                    RAISE;
                END IF;
        END;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 10) ISOLAMENTO: barbeiro da barbearia B cria -> registra na PRÓPRIA B
    -- ------------------------------------------------------------------
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated","iat":1710000000,"exp":1710003600}', j_prof_b), true);
    BEGIN
        SELECT * INTO v_cliente FROM public.criar_cliente('Cliente da B', '41999990110');

        IF v_cliente.barbearia_id <> v_bar2 THEN
            RAISE EXCEPTION '10.ISOLAMENTO: criado na barbearia % (esperado %)', v_cliente.barbearia_id, v_bar2;
        END IF;
        c_ok := c_ok + 1;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION '10.ISOLAMENTO falhou: %', SQLERRM;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 11) cliente criado pelo barbeiro é usado num AGENDAMENTO (M004)
    -- ------------------------------------------------------------------
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated","iat":1710000000,"exp":1710003600}', j_prof_a), true);
    v_inicio := timestamptz '2026-09-14 14:00:00 -03:00'; -- segunda-feira
    BEGIN
        SELECT * INTO v_ag FROM public.barbeiro_criar_agendamento(v_srv30, v_cli_novo, v_inicio);

        IF v_ag.id IS NULL
           OR v_ag.status <> 'pendente'
           OR v_ag.barbeiro_id <> v_prof_a
           OR v_ag.cliente_id <> v_cli_novo THEN
            RAISE EXCEPTION '11.AGENDAMENTO: dados incorretos (status=%)', v_ag.status;
        END IF;
        c_ok := c_ok + 1;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION '11.AGENDAMENTO falhou: %', SQLERRM;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 12) LEITURA: listar_clientes_da_barbearia devolve SÓ a própria
    -- ------------------------------------------------------------------
    BEGIN
        SELECT count(*) INTO v_n FROM public.listar_clientes_da_barbearia() WHERE barbearia_id = v_bar;
        IF v_n <> (SELECT count(*) FROM public.clientes WHERE barbearia_id = v_bar) THEN
            RAISE EXCEPTION '12.LEITURA: devolveu % clientes da A (esperado %)', v_n,
                (SELECT count(*) FROM public.clientes WHERE barbearia_id = v_bar);
        END IF;

        SELECT count(*) INTO v_n FROM public.listar_clientes_da_barbearia() WHERE barbearia_id = v_bar2;
        IF v_n <> 0 THEN
            RAISE EXCEPTION '12.LEITURA: vazou % clientes da barbearia B', v_n;
        END IF;
        c_ok := c_ok + 1;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION '12.LEITURA falhou: %', SQLERRM;
    END;
    c_total := c_total + 1;

    IF c_ok <> c_total THEN
        RAISE EXCEPTION 'RESULTADO: %/% asserções passaram', c_ok, c_total;
    END IF;

    RAISE NOTICE 'SUCESSO: %/%', c_ok, c_total;
END;
$$;

ROLLBACK;

-- ===========================================================================
-- VERIFICAÇÃO: INSERT DIRETO em clientes por authenticated (manual)
--   A migration 006 executa: REVOKE INSERT ON public.clientes FROM authenticated;
--   Como autenticado não há mais privilégio de INSERT (nem policy nova), um
--   INSERT direto via PostgREST/SQL deve falhar com 'permission denied for
--   table clientes'. A única via de criação é a RPC public.criar_cliente.
-- ===========================================================================