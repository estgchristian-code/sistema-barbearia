-- ===========================================================================
-- TESTE — Migration 007 (barbeiro pode EDITAAR clientes — somente os 4 campos)
--
-- Executar no PostgreSQL local (ou no Supabase SQL Editor) DEPOIS de aplicar
--   database/migrations/007_barbeiro_editar_cliente.sql
--
-- Este script é AUTOCONTIDO e SEGURO:
--   * usa UMA TRANSAÇÃO EXPLÍCITA (BEGIN ... ROLLBACK);
--   * cria barbearias/horários/barbeiros CLIENTES TÉCNICOS;
--   * simula o usuário logado via set_config('request.jwt.claims', ...),
--     como na seção 13 do rls.sql (auth.uid() lê o 'sub' do JWT);
--   * valida os cenários abaixo e executa ROLLBACK ao final (nada persiste);
--   * se todas as asserções passarem, imprime 'SUCESSO: NN/NN'.
--
-- Cenários cobertos (12 asserções):
--   1.  BARBEIRO A edita cliente VÁLIDO            -> nome/telefone/e-mail/obs
--       atualizados; ativo PRESERVADO; created_at PRESERVADO; updated_at
--       atualizado (trigger); barbearia = própria;
--   2.  ATIVO PRESERVADO: barbeiro edita cliente INATIVO (criado pelo admin)
--       -> ativo continua false; apenas os 4 campos mudam;
--   3.  CLIENTE DE OUTRA BARBEARIA (B) editado pelo barbeiro A -> REJEITADO
--       ('cliente não encontrado ou de outra barbearia') e dado INALTERADO;
--   4.  USUÁRIO SEM VÍNCULO a profissional (cargo incorreto) -> rejeitado;
--   5.  PROFISSIONAL INATIVO                         -> rejeitado;
--   6.  NOME vazio                                   -> rejeitado;
--   7.  TELEFONE vazio                               -> rejeitado;
--   8.  E-MAIL malformado                            -> rejeitado;
--   9.  ADMIN edita via RPC (regressão admin)        -> ok; ativo/created_at
--       preservados;
--   10. ISOLAMENTO: barbeiro da barbearia B edita cliente da PRÓPRIA B -> ok;
--   11. ISOLAMENTO (bidirecional): barbeiro da B tenta editar cliente da A
--       -> REJEITADO;
--   12. LEITURA após edições: listar_clientes_da_barbearia devolve SÓ os da
--       própria barbearia (0 de outra) e o total da própria.
--
-- A inexistência de policy de UPDATE para o barbeiro e a não-existência de
-- novos grants são verificadas à parte (grants/RLS) — ver NOTA final.
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
    v_cli_a_ativo  clientes.id%type;
    v_cli_a_ina    clientes.id%type;
    v_cli_b        clientes.id%type;
    v_cliente      public.clientes;
    v_nome         text;
    v_tel          text;
    v_n            int;
    c_total        int := 0;
    c_ok           int := 0;
    c_created_a    constant timestamptz := '2026-08-01 10:00:00+00';
    c_created_ina  constant timestamptz := '2026-08-02 10:00:00+00';
    c_created_b    constant timestamptz := '2026-08-03 10:00:00+00';

    -- Identidades fictícias do Supabase Auth (a partir do 'sub' do JWT).
    j_admin    constant text := '00000000-0000-0000-0000-0000000000c1';
    j_prof_a   constant text := '00000000-0000-0000-0000-0000000000c2';
    j_prof_b   constant text := '00000000-0000-0000-0000-0000000000c3';
    j_inativo  constant text := '00000000-0000-0000-0000-0000000000c4';
    j_solto    constant text := '00000000-0000-0000-0000-0000000000c5';
BEGIN
    -- ------------------------------------------------------------------
    -- SETUP (dados técnicos, apenas para o teste)
    -- ------------------------------------------------------------------
    INSERT INTO public.barbearias (nome, telefone, slug, timezone)
    VALUES ('Barbearia Teste Mig007 A', '(41) 99999-0200', 'barbearia-teste-mig007-a', 'America/Sao_Paulo')
    RETURNING id INTO v_bar;

    INSERT INTO auth.users (id) VALUES
        (j_admin::uuid),
        (j_prof_a::uuid),
        (j_prof_b::uuid),
        (j_inativo::uuid);

    INSERT INTO public.profissionais (barbearia_id, nome, cargo, ativo, auth_user_id)
    VALUES (v_bar, 'Admin Teste 007', 'admin', true, j_admin::uuid)
    RETURNING id INTO v_admin;

    INSERT INTO public.profissionais (barbearia_id, nome, cargo, ativo, auth_user_id)
    VALUES (v_bar, 'Barbeiro A Teste 007', 'barbeiro', true, j_prof_a::uuid)
    RETURNING id INTO v_prof_a;

    INSERT INTO public.profissionais (barbearia_id, nome, cargo, ativo, auth_user_id)
    VALUES (v_bar, 'Barbeiro Inativo Teste 007', 'barbeiro', false, j_inativo::uuid)
    RETURNING id INTO v_prof_inativo;

    -- Barbearia B (dados alheios).
    INSERT INTO public.barbearias (nome, telefone, slug, timezone)
    VALUES ('Barbearia Teste Mig007 B', '(41) 98888-0200', 'barbearia-teste-mig007-b', 'America/Sao_Paulo')
    RETURNING id INTO v_bar2;

    INSERT INTO public.profissionais (barbearia_id, nome, cargo, ativo, auth_user_id)
    VALUES (v_bar2, 'Barbeiro B Teste 007', 'barbeiro', true, j_prof_b::uuid)
    RETURNING id INTO v_prof_b;

    -- Clientes técnicos (INSERT direto de setup, com created_at no passado
    -- para permitir assertar que NA NADA muda os timestamps originais).
    INSERT INTO public.clientes (barbearia_id, nome, telefone, email, observacoes, ativo, created_at)
    VALUES (v_bar, 'Cliente Ativo A', '41999990001', 'cliente-a@teste.com', 'obs-a', true, c_created_a)
    RETURNING id INTO v_cli_a_ativo;

    INSERT INTO public.clientes (barbearia_id, nome, telefone, email, observacoes, ativo, created_at)
    VALUES (v_bar, 'Cliente Inativo A', '41999990002', NULL, NULL, false, c_created_ina)
    RETURNING id INTO v_cli_a_ina;

    INSERT INTO public.clientes (barbearia_id, nome, telefone, email, observacoes, ativo, created_at)
    VALUES (v_bar2, 'Cliente da B', '41999990003', 'cliente-b@teste.com', 'obs-b', true, c_created_b)
    RETURNING id INTO v_cli_b;

    -- ------------------------------------------------------------------
    -- 1) BARBEIRO A edita cliente VÁLIDO -> 4 campos; ativo/created_at intactos
    -- ------------------------------------------------------------------
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated","iat":1710000000,"exp":1710003600}', j_prof_a), true);
    BEGIN
        SELECT * INTO v_cliente FROM public.editar_cliente(
            v_cli_a_ativo, 'Nome Editado A', '41999990992', 'editado@teste.com', 'obs ok');

        IF v_cliente.id <> v_cli_a_ativo
           OR v_cliente.barbearia_id <> v_bar
           OR v_cliente.nome <> 'Nome Editado A'
           OR v_cliente.telefone <> '41999990992'
           OR v_cliente.email <> 'editado@teste.com'
           OR v_cliente.observacoes <> 'obs ok'
           OR v_cliente.ativo <> true                       -- ativo NUNCA tocado
           OR v_cliente.created_at <> c_created_a           -- created_at NUNCA tocado
           OR v_cliente.updated_at IS NULL
           OR v_cliente.updated_at <= c_created_a           -- trigger rodou (updated_at)
        THEN
            RAISE EXCEPTION '1.VÁLIDO: dados incorretos (ativo=%, created_at=%, nome=%)',
                v_cliente.ativo, v_cliente.created_at, v_cliente.nome;
        END IF;

        -- Efetivamente persistido no banco.
        SELECT nome INTO v_nome FROM public.clientes WHERE id = v_cli_a_ativo;
        IF v_nome <> 'Nome Editado A' THEN
            RAISE EXCEPTION '1.VÁLIDO: não persistido (nome=%)', v_nome;
        END IF;
        c_ok := c_ok + 1;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION '1.VÁLIDO falhou: %', SQLERRM;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 2) ATIVO PRESERVADO: barbeiro edita cliente INATIVO -> ativo segue false
    -- ------------------------------------------------------------------
    BEGIN
        SELECT * INTO v_cliente FROM public.editar_cliente(
            v_cli_a_ina, 'Cliente Inativo Editado', '41999990993', NULL, NULL);

        IF v_cliente.ativo <> false                           -- PRINCIPAL: intacto
           OR v_cliente.nome <> 'Cliente Inativo Editado'
           OR v_cliente.created_at <> c_created_ina
        THEN
            RAISE EXCEPTION '2.ATIVO: ativo=% (esperado false)', v_cliente.ativo;
        END IF;
        c_ok := c_ok + 1;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION '2.ATIVO falhou: %', SQLERRM;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 3) CLIENTE DE OUTRA BARBEARIA (B) -> REJEITADO e dado INALTERADO
    -- ------------------------------------------------------------------
    BEGIN
        BEGIN
            PERFORM public.editar_cliente(v_cli_b, 'Hack Nome', '41999990000');
            RAISE EXCEPTION '3.OUTRA BARBEARIA foi aceito (deveria rejeitar)';
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLERRM LIKE '%não encontrado ou de outra barbearia%' THEN
                    SELECT nome, telefone INTO v_nome, v_tel FROM public.clientes WHERE id = v_cli_b;
                    IF v_nome = 'Hack Nome' OR v_tel = '41999990000' THEN
                        RAISE EXCEPTION '3.OUTRA BARBEARIA: dado foi alterado (nome=%, tel=%)', v_nome, v_tel;
                    END IF;
                    c_ok := c_ok + 1;
                ELSIF SQLERRM NOT LIKE '%3.OUTRA BARBEARIA foi aceito%' THEN
                    RAISE EXCEPTION '3.OUTRA BARBEARIA: erro inesperado: %', SQLERRM;
                ELSE
                    RAISE;
                END IF;
        END;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 4) USUÁRIO SEM VÍNCULO (cargo incorreto) -> rejeitado
    -- ------------------------------------------------------------------
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated","iat":1710000000,"exp":1710003600}', j_solto), true);
    BEGIN
        BEGIN
            PERFORM public.editar_cliente(v_cli_a_ativo, 'Hack Sem Vinculo', '41999990000');
            RAISE EXCEPTION '4.SEM VÍNCULO foi aceito (deveria rejeitar)';
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLERRM LIKE '%somente um profissional ativo%' THEN
                    c_ok := c_ok + 1;
                ELSIF SQLERRM NOT LIKE '%4.SEM VÍNCULO foi aceito%' THEN
                    RAISE EXCEPTION '4.SEM VÍNCULO: erro inesperado: %', SQLERRM;
                ELSE
                    RAISE;
                END IF;
        END;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 5) PROFISSIONAL INATIVO -> rejeitado
    -- ------------------------------------------------------------------
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated","iat":1710000000,"exp":1710003600}', j_inativo), true);
    BEGIN
        BEGIN
            PERFORM public.editar_cliente(v_cli_a_ativo, 'Hack Inativo', '41999990000');
            RAISE EXCEPTION '5.INATIVO foi aceito (deveria rejeitar)';
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLERRM LIKE '%somente um profissional ativo%' THEN
                    c_ok := c_ok + 1;
                ELSIF SQLERRM NOT LIKE '%5.INATIVO foi aceito%' THEN
                    RAISE EXCEPTION '5.INATIVO: erro inesperado: %', SQLERRM;
                ELSE
                    RAISE;
                END IF;
        END;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 6) NOME vazio -> rejeitado
    -- ------------------------------------------------------------------
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated","iat":1710000000,"exp":1710003600}', j_prof_a), true);
    BEGIN
        BEGIN
            PERFORM public.editar_cliente(v_cli_a_ativo, '   ', '41999990000');
            RAISE EXCEPTION '6.NOME VAZIO foi aceito (deveria rejeitar)';
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLERRM LIKE '%nome do cliente é obrigatório%' THEN
                    c_ok := c_ok + 1;
                ELSIF SQLERRM NOT LIKE '%6.NOME VAZIO foi aceito%' THEN
                    RAISE EXCEPTION '6.NOME VAZIO: erro inesperado: %', SQLERRM;
                ELSE
                    RAISE;
                END IF;
        END;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 7) TELEFONE vazio -> rejeitado
    -- ------------------------------------------------------------------
    BEGIN
        BEGIN
            PERFORM public.editar_cliente(v_cli_a_ativo, 'Sem Telefone', '  ');
            RAISE EXCEPTION '7.TELEFONE VAZIO foi aceito (deveria rejeitar)';
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLERRM LIKE '%telefone do cliente é obrigatório%' THEN
                    c_ok := c_ok + 1;
                ELSIF SQLERRM NOT LIKE '%7.TELEFONE VAZIO foi aceito%' THEN
                    RAISE EXCEPTION '7.TELEFONE VAZIO: erro inesperado: %', SQLERRM;
                ELSE
                    RAISE;
                END IF;
        END;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 8) E-MAIL malformado -> rejeitado
    -- ------------------------------------------------------------------
    BEGIN
        BEGIN
            PERFORM public.editar_cliente(v_cli_a_ativo, 'Email Ruim', '41999990000', 'nao-e-email');
            RAISE EXCEPTION '8.E-MAIL RUIM foi aceito (deveria rejeitar)';
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLERRM LIKE '%e-mail inválido%' THEN
                    c_ok := c_ok + 1;
                ELSIF SQLERRM NOT LIKE '%8.E-MAIL RUIM foi aceito%' THEN
                    RAISE EXCEPTION '8.E-MAIL RUIM: erro inesperado: %', SQLERRM;
                ELSE
                    RAISE;
                END IF;
        END;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 9) ADMIN edita via RPC (regressão admin) -> ativo/created_at preservados
    -- ------------------------------------------------------------------
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated","iat":1710000000,"exp":1710003600}', j_admin), true);
    BEGIN
        SELECT * INTO v_cliente FROM public.editar_cliente(
            v_cli_a_ina, 'Editado pelo Admin', '41999990994', 'admin@teste.com', NULL);

        IF v_cliente.nome <> 'Editado pelo Admin'
           OR v_cliente.ativo <> false
           OR v_cliente.created_at <> c_created_ina
        THEN
            RAISE EXCEPTION '9.ADMIN: nome=%, ativo=%', v_cliente.nome, v_cliente.ativo;
        END IF;
        c_ok := c_ok + 1;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION '9.ADMIN falhou: %', SQLERRM;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 10) ISOLAMENTO: barbeiro da B edita cliente da PRÓPRIA B -> ok
    -- ------------------------------------------------------------------
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated","iat":1710000000,"exp":1710003600}', j_prof_b), true);
    BEGIN
        SELECT * INTO v_cliente FROM public.editar_cliente(
            v_cli_b, 'Cliente da B Editado', '41999990995', NULL, 'obs-b-nova');

        IF v_cliente.barbearia_id <> v_bar2
           OR v_cliente.nome <> 'Cliente da B Editado'
           OR v_cliente.ativo <> true
           OR v_cliente.created_at <> c_created_b
        THEN
            RAISE EXCEPTION '10.ISOLAMENTO: barbearia=%, ativo=%', v_cliente.barbearia_id, v_cliente.ativo;
        END IF;
        c_ok := c_ok + 1;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION '10.ISOLAMENTO falhou: %', SQLERRM;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 11) ISOLAMENTO (bidirecional): barbeiro da B tenta editar cliente da A
    -- ------------------------------------------------------------------
    BEGIN
        BEGIN
            PERFORM public.editar_cliente(v_cli_a_ativo, 'Hack A por B', '41999990000');
            RAISE EXCEPTION '11.ISOLAMENTO foi aceito (deveria rejeitar)';
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLERRM LIKE '%não encontrado ou de outra barbearia%' THEN
                    SELECT nome INTO v_nome FROM public.clientes WHERE id = v_cli_a_ativo;
                    IF v_nome = 'Hack A por B' THEN
                        RAISE EXCEPTION '11.ISOLAMENTO: cliente da A foi alterado (nome=%)', v_nome;
                    END IF;
                    c_ok := c_ok + 1;
                ELSIF SQLERRM NOT LIKE '%11.ISOLAMENTO foi aceito%' THEN
                    RAISE EXCEPTION '11.ISOLAMENTO: erro inesperado: %', SQLERRM;
                ELSE
                    RAISE;
                END IF;
        END;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 12) LEITURA: listar_clientes_da_barbearia devolve SÓ a própria
    -- ------------------------------------------------------------------
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated","iat":1710000000,"exp":1710003600}', j_prof_a), true);
    BEGIN
        SELECT count(*) INTO v_n FROM public.listar_clientes_da_barbearia()
         WHERE barbearia_id = v_bar;
        IF v_n <> (SELECT count(*) FROM public.clientes WHERE barbearia_id = v_bar) THEN
            RAISE EXCEPTION '12.LEITURA: devolveu % clientes da A (esperado %)', v_n,
                (SELECT count(*) FROM public.clientes WHERE barbearia_id = v_bar);
        END IF;

        SELECT count(*) INTO v_n FROM public.listar_clientes_da_barbearia()
         WHERE barbearia_id = v_bar2;
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
-- NOTA (verificação manual / grants + RLS):
--   * a migration 007 NÃO cria policy de UPDATE para o barbeiro —
--     clientes_write_admin continua exclusiva do admin; portanto um UPDATE
--     direto em clientes feito pelo barbeiro afeta 0 linhas (RLS);
--   * a única via de escrita do barbeiro é a RPC public.editar_cliente,
--     que NÃO aceita p_ativo/p_barbearia_id (barbearia derivada de
--     auth.uid()) e grava SOMENTE nome/telefone/e-mail/observacoes;
--   * REVOKE de PUBLIC/anon + GRANT EXECUTE somente a authenticated;
--   * confirmar: SELECT has_table_privilege('authenticated','clientes','UPDATE')
--     (deve continuar true, sem policy nova — a proteção é do RLS, não do grant).
-- ===========================================================================