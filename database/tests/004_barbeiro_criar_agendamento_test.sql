-- ===========================================================================
-- TESTE — Migration 004 (barbeiro cria agendamento SOMENTE para si mesmo)
--
-- Executar no PostgreSQL local (ou no Supabase SQL Editor) DEPOIS de aplicar
--   database/migrations/004_barbeiro_criar_agendamento.sql
--
-- Este script é AUTOCONTIDO e SEGURO:
--   * usa UMA TRANSAÇÃO EXPLÍCITA (BEGIN ... ROLLBACK), sem depender do
--     autocommit nem do ROLLBACK implícito de DO block;
--   * cria barbearias/horários/serviços/barbeiros/clientes TÉCNICOS;
--   * simula o usuário logado via set_config('request.jwt.claims', ...)
--     (a mesma técnica documentada na seção 13 do rls.sql): auth.uid()
--     lê o 'sub' do token JWT e as funções derivam o profissional;
--   * valida os cenários abaixo e executa ROLLBACK ao final (nada persiste);
--   * se todas as asserções passarem, imprime 'SUCESSO: NN/NN';
--   * se alguma falhar, lança exceção (e a transação é revertida pelo ROLLBACK);
--   * o banco fica limpo após QUALQUER execução (sucesso ou falha).
--
-- Cenários cobertos (13 asserções):
--   1.  barbeiro CRIANDO UM AGENDAMENTO VÁLIDO      -> status 'pendente';
--       barbeiro_id = o próprio; barbearia_id = a própria; fim derivado (M1);
--   2.  duração automática com OUTRO serviço (45 min) -> fim = início + 45 min;
--   3.  OUTRO barbeiro autenticado (prof_b) cria     -> barbeiro_id = prof_b
--       (a RPC SEMPRE usa o autenticado; não existe p_barbeiro_id);
--   4.  USUÁRIO COM CARGO INCORRETO (admin)          -> rejeitado;
--   5.  PROFISSIONAL INATIVO                         -> rejeitado;
--   6.  CLIENTE DE OUTRA BARBEARIA                   -> rejeitado;
--   7.  SERVIÇO DE OUTRA BARBEARIA                   -> rejeitado;
--   8.  SERVIÇO INATIVO (mesma barbearia)            -> rejeitado;
--   9.  CLIENTE INATIVO (mesma barbearia)            -> rejeitado;
--   10. FORA DO HORÁRIO (validação A1 preservada)    -> rejeitado;
--   11. SOBRE BLOQUEIO (validação A1 preservada)     -> rejeitado;
--   12. ADMIN continua criando via admin_criar_agendamento (regressão);
--   13. leitura segura de clientes devolve SÓ os da própria barbearia.
--
-- A inexistência de INSERT direto é verificada à parte (grants/policies) —
-- ver seção "VERIFICAÇÃO: INSERT DIRETO" ao final, executada manualmente.
-- ===========================================================================

BEGIN;

DO $$
DECLARE
    v_bar           barbearias.id%type;
    v_bar2          barbearias.id%type;
    v_admin         profissionais.id%type;
    v_prof_a        profissionais.id%type;
    v_prof_b        profissionais.id%type;
    v_prof_inativo  profissionais.id%type;
    v_srv30         servicos.id%type;
    v_srv45         servicos.id%type;
    v_srv_inativo   servicos.id%type;
    v_srvB          servicos.id%type;
    v_cli_a         clientes.id%type;
    v_cli_inativo   clientes.id%type;
    v_cli_b         clientes.id%type;
    v_ag            public.agendamentos;
    v_inicio        timestamptz;
    v_n             int;
    c_total         int := 0;
    c_ok            int := 0;

    -- Identidades fictícias do Supabase Auth (a partir do 'sub' do JWT).
    j_admin    constant text := '00000000-0000-0000-0000-0000000000a1';
    j_prof_a   constant text := '00000000-0000-0000-0000-0000000000a2';
    j_prof_b   constant text := '00000000-0000-0000-0000-0000000000a3';
    j_inativo  constant text := '00000000-0000-0000-0000-0000000000a4';
BEGIN
    -- ------------------------------------------------------------------
    -- SETUP (dados técnicos, apenas para o teste)
    -- ------------------------------------------------------------------
    INSERT INTO public.barbearias (nome, telefone, slug, timezone)
    VALUES ('Barbearia Teste Mig004', '(41) 99999-0000', 'barbearia-teste-mig004', 'America/Sao_Paulo')
    RETURNING id INTO v_bar;

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

    -- Identidades no Supabase Auth (a FK profissionais.auth_user_id exige).
    INSERT INTO auth.users (id) VALUES
        (j_admin::uuid),
        (j_prof_a::uuid),
        (j_prof_b::uuid),
        (j_inativo::uuid);

    INSERT INTO public.profissionais (barbearia_id, nome, cargo, ativo, auth_user_id)
    VALUES (v_bar, 'Admin Teste', 'admin', true, j_admin::uuid)
    RETURNING id INTO v_admin;

    INSERT INTO public.profissionais (barbearia_id, nome, cargo, ativo, auth_user_id)
    VALUES (v_bar, 'Barbeiro A Teste', 'barbeiro', true, j_prof_a::uuid)
    RETURNING id INTO v_prof_a;

    INSERT INTO public.profissionais (barbearia_id, nome, cargo, ativo, auth_user_id)
    VALUES (v_bar, 'Barbeiro B Teste', 'barbeiro', true, j_prof_b::uuid)
    RETURNING id INTO v_prof_b;

    INSERT INTO public.profissionais (barbearia_id, nome, cargo, ativo, auth_user_id)
    VALUES (v_bar, 'Barbeiro Inativo Teste', 'barbeiro', false, j_inativo::uuid)
    RETURNING id INTO v_prof_inativo;

    INSERT INTO public.servicos (barbearia_id, nome, preco, duracao_minutos, ativo)
    VALUES (v_bar, 'Corte Teste 30min', 40.00, 30, true)
    RETURNING id INTO v_srv30;

    INSERT INTO public.servicos (barbearia_id, nome, preco, duracao_minutos, ativo)
    VALUES (v_bar, 'Corte + Barba 45min', 70.00, 45, true)
    RETURNING id INTO v_srv45;

    INSERT INTO public.servicos (barbearia_id, nome, preco, duracao_minutos, ativo)
    VALUES (v_bar, 'Corte Inativo', 10.00, 15, false)
    RETURNING id INTO v_srv_inativo;

    INSERT INTO public.clientes (barbearia_id, nome, telefone, ativo)
    VALUES (v_bar, 'Cliente A Teste', '41999990001', true)
    RETURNING id INTO v_cli_a;

    INSERT INTO public.clientes (barbearia_id, nome, telefone, ativo)
    VALUES (v_bar, 'Cliente Inativo Teste', '41999990002', false)
    RETURNING id INTO v_cli_inativo;

    -- Barbearia B (dados alheios — não podem ser usados pelo barbeiro de A).
    INSERT INTO public.barbearias (nome, telefone, slug, timezone)
    VALUES ('Barbearia B Teste', '(41) 98888-0000', 'barbearia-b-mig004', 'America/Sao_Paulo')
    RETURNING id INTO v_bar2;

    INSERT INTO public.servicos (barbearia_id, nome, preco, duracao_minutos, ativo)
    VALUES (v_bar2, 'Corte B', 50.00, 20, true)
    RETURNING id INTO v_srvB;

    INSERT INTO public.clientes (barbearia_id, nome, telefone, ativo)
    VALUES (v_bar2, 'Cliente B Teste', '41988880000', true)
    RETURNING id INTO v_cli_b;

    -- ------------------------------------------------------------------
    -- 1) BARBEIRO A cria VÁLIDO: status pendente, barbeiro_id = prof_a,
    --    barbearia_id = A, fim derivado (M1) = início + 30 min
    -- ------------------------------------------------------------------
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated","iat":1710000000,"exp":1710003600}', j_prof_a), true);
    v_inicio := timestamptz '2026-09-14 14:00:00 -03:00'; -- segunda-feira
    BEGIN
        SELECT * INTO v_ag FROM public.barbeiro_criar_agendamento(v_srv30, v_cli_a, v_inicio, 'obs 1');

        IF v_ag.id IS NULL
           OR v_ag.status <> 'pendente'
           OR v_ag.barbeiro_id <> v_prof_a
           OR v_ag.barbearia_id <> v_bar
           OR v_ag.data_hora_fim <> v_inicio + interval '30 minutes' THEN
            RAISE EXCEPTION '1.VÁLIDO: dados incorretos (barbeiro=%, status=%, fim=%)',
                v_ag.barbeiro_id, v_ag.status, v_ag.data_hora_fim;
        END IF;
        c_ok := c_ok + 1;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION '1.VÁLIDO falhou: %', SQLERRM;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 2) DURAÇÃO AUTOMÁTICA (M1) com OUTRO serviço -> fim = início + 45 min
    -- ------------------------------------------------------------------
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated","iat":1710000000,"exp":1710003600}', j_prof_a), true);
    v_inicio := timestamptz '2026-09-14 16:00:00 -03:00';
    BEGIN
        SELECT * INTO v_ag FROM public.barbeiro_criar_agendamento(v_srv45, v_cli_a, v_inicio);

        IF v_ag.data_hora_fim <> v_inicio + interval '45 minutes' THEN
            RAISE EXCEPTION '2.DURAÇÃO: fim incorreto -> % (esperado 16:45)', v_ag.data_hora_fim;
        END IF;
        c_ok := c_ok + 1;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION '2.DURAÇÃO falhou: %', SQLERRM;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 3) OUTRO BARBEIRO autenticado (prof_b) -> barbeiro_id SEMPRE = prof_b
    --    (a RPC não recebe p_barbeiro_id; usa o autenticado)
    -- ------------------------------------------------------------------
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated","iat":1710000000,"exp":1710003600}', j_prof_b), true);
    v_inicio := timestamptz '2026-09-14 09:00:00 -03:00';
    BEGIN
        SELECT * INTO v_ag FROM public.barbeiro_criar_agendamento(v_srv30, v_cli_a, v_inicio);

        IF v_ag.barbeiro_id <> v_prof_b THEN
            RAISE EXCEPTION '3.OUTRO BARBEIRO: barbeiro_id deveria ser % (era %)', v_prof_b, v_ag.barbeiro_id;
        END IF;
        c_ok := c_ok + 1;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION '3.OUTRO BARBEIRO falhou: %', SQLERRM;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 4) CARGO INCORRETO (admin tentando usar a RPC do barbeiro) -> rejeitado
    -- ------------------------------------------------------------------
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated","iat":1710000000,"exp":1710003600}', j_admin), true);
    v_inicio := timestamptz '2026-09-14 10:00:00 -03:00';
    BEGIN
        BEGIN
            PERFORM public.barbeiro_criar_agendamento(v_srv30, v_cli_a, v_inicio);
            RAISE EXCEPTION '4.CARGO INCORRETO foi aceito (deveria rejeitar)';
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLERRM LIKE '%somente um barbeiro ativo%' THEN
                    c_ok := c_ok + 1;
                ELSIF SQLERRM NOT LIKE '%4.CARGO INCORRETO foi aceito%' THEN
                    RAISE EXCEPTION '4.CARGO INCORRETO: erro inesperado: %', SQLERRM;
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
    v_inicio := timestamptz '2026-09-14 10:00:00 -03:00';
    BEGIN
        BEGIN
            PERFORM public.barbeiro_criar_agendamento(v_srv30, v_cli_a, v_inicio);
            RAISE EXCEPTION '5.INATIVO foi aceito (deveria rejeitar)';
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLERRM LIKE '%somente um barbeiro ativo%' THEN
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
    -- 6) CLIENTE DE OUTRA BARBEARIA -> rejeitado
    -- ------------------------------------------------------------------
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated","iat":1710000000,"exp":1710003600}', j_prof_a), true);
    v_inicio := timestamptz '2026-09-14 10:00:00 -03:00';
    BEGIN
        BEGIN
            PERFORM public.barbeiro_criar_agendamento(v_srv30, v_cli_b, v_inicio);
            RAISE EXCEPTION '6.CLIENTE OUTRA BARBEARIA foi aceito (deveria rejeitar)';
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLERRM LIKE '%cliente inválido%' THEN
                    c_ok := c_ok + 1;
                ELSIF SQLERRM NOT LIKE '%6.CLIENTE OUTRA BARBEARIA foi aceito%' THEN
                    RAISE EXCEPTION '6.CLIENTE OUTRA BARBEARIA: erro inesperado: %', SQLERRM;
                ELSE
                    RAISE;
                END IF;
        END;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 7) SERVIÇO DE OUTRA BARBEARIA -> rejeitado
    -- ------------------------------------------------------------------
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated","iat":1710000000,"exp":1710003600}', j_prof_a), true);
    v_inicio := timestamptz '2026-09-14 10:00:00 -03:00';
    BEGIN
        BEGIN
            PERFORM public.barbeiro_criar_agendamento(v_srvB, v_cli_a, v_inicio);
            RAISE EXCEPTION '7.SERVIÇO OUTRA BARBEARIA foi aceito (deveria rejeitar)';
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLERRM LIKE '%serviço inválido%' THEN
                    c_ok := c_ok + 1;
                ELSIF SQLERRM NOT LIKE '%7.SERVIÇO OUTRA BARBEARIA foi aceito%' THEN
                    RAISE EXCEPTION '7.SERVIÇO OUTRA BARBEARIA: erro inesperado: %', SQLERRM;
                ELSE
                    RAISE;
                END IF;
        END;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 8) SERVIÇO INATIVO (mesma barbearia) -> rejeitado
    -- ------------------------------------------------------------------
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated","iat":1710000000,"exp":1710003600}', j_prof_a), true);
    v_inicio := timestamptz '2026-09-14 10:00:00 -03:00';
    BEGIN
        BEGIN
            PERFORM public.barbeiro_criar_agendamento(v_srv_inativo, v_cli_a, v_inicio);
            RAISE EXCEPTION '8.SERVIÇO INATIVO foi aceito (deveria rejeitar)';
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLERRM LIKE '%serviço inválido%' THEN
                    c_ok := c_ok + 1;
                ELSIF SQLERRM NOT LIKE '%8.SERVIÇO INATIVO foi aceito%' THEN
                    RAISE EXCEPTION '8.SERVIÇO INATIVO: erro inesperado: %', SQLERRM;
                ELSE
                    RAISE;
                END IF;
        END;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 9) CLIENTE INATIVO (mesma barbearia) -> rejeitado
    -- ------------------------------------------------------------------
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated","iat":1710000000,"exp":1710003600}', j_prof_a), true);
    v_inicio := timestamptz '2026-09-14 10:00:00 -03:00';
    BEGIN
        BEGIN
            PERFORM public.barbeiro_criar_agendamento(v_srv30, v_cli_inativo, v_inicio);
            RAISE EXCEPTION '9.CLIENTE INATIVO foi aceito (deveria rejeitar)';
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLERRM LIKE '%cliente inválido%' THEN
                    c_ok := c_ok + 1;
                ELSIF SQLERRM NOT LIKE '%9.CLIENTE INATIVO foi aceito%' THEN
                    RAISE EXCEPTION '9.CLIENTE INATIVO: erro inesperado: %', SQLERRM;
                ELSE
                    RAISE;
                END IF;
        END;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 10) FORA DO HORÁRIO (validação A1 preservada) -> rejeitado
    -- ------------------------------------------------------------------
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated","iat":1710000000,"exp":1710003600}', j_prof_a), true);
    v_inicio := timestamptz '2026-09-14 19:00:00 -03:00'; -- além das 18h
    BEGIN
        BEGIN
            PERFORM public.barbeiro_criar_agendamento(v_srv30, v_cli_a, v_inicio);
            RAISE EXCEPTION '10.FORA DO HORÁRIO foi aceito (deveria rejeitar)';
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLERRM LIKE '%fora do funcionamento%' THEN
                    c_ok := c_ok + 1;
                ELSIF SQLERRM NOT LIKE '%10.FORA DO HORÁRIO foi aceito%' THEN
                    RAISE EXCEPTION '10.FORA DO HORÁRIO: erro inesperado: %', SQLERRM;
                ELSE
                    RAISE;
                END IF;
        END;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 11) SOBRE BLOQUEIO GERAL (validação A1 preservada) -> rejeitado
    -- ------------------------------------------------------------------
    INSERT INTO public.bloqueios_agenda
        (barbearia_id, barbeiro_id, inicio, fim, motivo)
    VALUES
        (v_bar, NULL,
         timestamptz '2026-09-15 09:00:00 -03:00',
         timestamptz '2026-09-15 11:00:00 -03:00',
         'Bloqueio geral de teste');
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated","iat":1710000000,"exp":1710003600}', j_prof_a), true);
    v_inicio := timestamptz '2026-09-15 10:00:00 -03:00'; -- terça, dentro do bloqueio
    BEGIN
        BEGIN
            PERFORM public.barbeiro_criar_agendamento(v_srv30, v_cli_a, v_inicio);
            RAISE EXCEPTION '11.BLOQUEIO foi aceito (deveria rejeitar)';
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLERRM LIKE '%bloqueado para este barbeiro%' THEN
                    c_ok := c_ok + 1;
                ELSIF SQLERRM NOT LIKE '%11.BLOQUEIO foi aceito%' THEN
                    RAISE EXCEPTION '11.BLOQUEIO: erro inesperado: %', SQLERRM;
                ELSE
                    RAISE;
                END IF;
        END;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 12) REGRESSÃO: ADMIN continua criando via admin_criar_agendamento
    --     (fim arbitrário enviado é sobrescrito pela M1)
    -- ------------------------------------------------------------------
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated","iat":1710000000,"exp":1710003600}', j_admin), true);
    v_inicio := timestamptz '2026-09-14 11:00:00 -03:00';
    BEGIN
        SELECT * INTO v_ag FROM public.admin_criar_agendamento(
                   v_bar, v_prof_a, v_srv30, v_cli_a,
                   v_inicio, v_inicio + interval '1 hour', NULL, NULL);

        IF v_ag.status <> 'pendente'
           OR v_ag.data_hora_fim <> v_inicio + interval '30 minutes' THEN
            RAISE EXCEPTION '12.ADMIN: status ou fim incorretos (fim=%)', v_ag.data_hora_fim;
        END IF;
        c_ok := c_ok + 1;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION '12.ADMIN falhou: %', SQLERRM;
    END;
    c_total := c_total + 1;

    -- ------------------------------------------------------------------
    -- 13) LEITURA SEGURA de clientes: SÓ os ativos da própria barbearia
    -- ------------------------------------------------------------------
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated","iat":1710000000,"exp":1710003600}', j_prof_a), true);
    BEGIN
        SELECT count(*) INTO v_n
          FROM public.listar_clientes_para_agendamento()
         WHERE id = v_cli_a;
        IF v_n <> 1 THEN
            RAISE EXCEPTION '13.LEITURA: cliente da própria barbearia ausente';
        END IF;

        SELECT count(*) INTO v_n
          FROM public.listar_clientes_para_agendamento()
         WHERE id = v_cli_b OR id = v_cli_inativo;
        IF v_n <> 0 THEN
            RAISE EXCEPTION '13.LEITURA: expôs cliente de outra barbearia/inativo';
        END IF;
        c_ok := c_ok + 1;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION '13.LEITURA falhou: %', SQLERRM;
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
-- VERIFICAÇÃO MANUAL: INSERT DIRETO NÃO DISPONÍVEL (executar ao final)
-- ===========================================================================
--
-- O barbeiro/usuário autenticado NÃO pode fazer INSERT/UPDATE/DELETE direto
-- em public.agendamentos (sem GRANT de escrita + sem policy de escrita).
-- Para confirmar no ambiente:
--
-- 1) Privilégio de INSERT do role authenticated:
--    select has_table_privilege('authenticated', 'public.agendamentos', 'INSERT')
--      as pode_insert_direto;    -- deve retornar false
--
-- 2) Policies de escrita no agendamentos:
--    select count(*) from pg_policies
--     where schemaname = 'public' and tablename = 'agendamentos'
--       and cmd in ('INSERT','UPDATE','DELETE');  -- deve retornar 0
--
-- 3) Tentativa funcional (exige um profissional com auth_user_id válido):
--    begin;
--    set local role authenticated;
--    set local request.jwt.claims = '{"sub":"<uuid-profissional>","role":"authenticated"}';
--    insert into public.agendamentos (
--        barbearia_id, cliente_id, barbeiro_id, servico_id,
--        data_hora_inicio, data_hora_fim, status)
--    values (1, 1, 1, 1, now(), now() + interval '30 minutes', 'pendente');
--      --> erro esperado: "permission denied for table agendamentos"
--    rollback;
-- ===========================================================================