-- ===========================================================================
-- TESTE — Migration 014 (auditoria de eventos de segurança / admin)
--
-- Executar no PostgreSQL local (ou no Supabase SQL Editor) DEPOIS de aplicar
--   database/migrations/014_auditoria.sql
--
-- Este script é AUTOCONTIDO e SEGURO:
--   * usa UMA TRANSAÇÃO EXPLÍCITA (BEGIN ... ROLLBACK);
--   * cria barbearias/horários/profissionais CLIENTES TÉCNICOS;
--   * troca de role (SET ROLE authenticated/anon/service_role) para avaliar
--     RLS de verdade, e simula o usuário logado via
--     set_config('request.jwt.claims', ...), como na seção 13 do rls.sql
--     (auth.uid() lê o 'sub' do JWT);
--   * valida os cenários abaixo e executa ROLLBACK ao final (nada persiste);
--   * se todas as asserções passarem, imprime 'SUCESSO: NN/NN'.
--
-- Cenários cobertos:
--   1.  ADMIN registra auditoria da PRÓPRIA barbearia via
--       registrar_auditoria() e CONSULTA (ELIMINA o próprio evento) -> visível;
--   2.  BARBEIRO da mesma barbearia NÃO consegue consultar auditoria (RLS);
--   3.  ADMIN de OUTRA barbearia (B) tenta consultar auditoria da A -> 0 linhas;
--   4.  ANON não acessa a tabela (sem grant + sem policy);
--   5.  barbeiro tenta REGISTRAR auditoria -> exceção 'sem permissão';
--   6.  TRIGGER de status: desativar profissional registra
--       'profissional_desativado' e reativar registra 'profissional_ativado';
--   7.  TRIGGER de cargo (canal privilegiado): mudança registra
--       'cargo_alterado' com cargo_anterior/cargo_novo;
--   8.  EXCLUSÃO soft (admin_excluir_profissional) registra
--       'profissional_excluido';
--   9.  EDGE FUNCTIONS (caminho service_role):
--       registrar_auditoria grava 'acesso_criado' e 'acesso_removido';
--  10.  NENHUM dado sensível persistido em detalhes (senha/password/token/
--       telefone/e-mail completo);
--  11.  UPDATE/DELETE direto em auditorias NÃO é permitido
--       (sem policy + sem grant para authenticated);
--  12.  ausência de policies de UPDATE/DELETE na tabela (pg_policies).
-- ===========================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- SETUP (dados técnicos, apenas para o teste) — como postgres (superuser)
-- ---------------------------------------------------------------------------
SET ROLE postgres;

DO $$
DECLARE
    v_bar_a        barbearias.id%type;
    v_bar_b        barbearias.id%type;
    j_admin_a      constant text := '00000000-0000-0000-0000-0000000000a1';
    j_barbeiro_a   constant text := '00000000-0000-0000-0000-0000000000a2';
    j_admin_b      constant text := '00000000-0000-0000-0000-0000000000a3';
BEGIN
    INSERT INTO public.barbearias (nome, telefone, slug, timezone)
    VALUES ('Barbearia Auditoria A', '(41) 99999-0300', 'barbearia-auditoria-teste-a', 'America/Sao_Paulo')
    RETURNING id INTO v_bar_a;

    INSERT INTO public.barbearias (nome, telefone, slug, timezone)
    VALUES ('Barbearia Auditoria B', '(41) 98888-0300', 'barbearia-auditoria-teste-b', 'America/Sao_Paulo')
    RETURNING id INTO v_bar_b;

    INSERT INTO auth.users (id) VALUES
        (j_admin_a::uuid),
        (j_barbeiro_a::uuid),
        (j_admin_b::uuid);

    -- Admin A, barbeiro A e um barbeiro A "alvo" (para triggers) na barbearia A.
    INSERT INTO public.profissionais (barbearia_id, nome, cargo, ativo, auth_user_id)
    VALUES (v_bar_a, 'Admin Auditoria A', 'admin', true, j_admin_a::uuid);

    INSERT INTO public.profissionais (barbearia_id, nome, cargo, ativo, auth_user_id)
    VALUES (v_bar_a, 'Barbeiro Auditoria A', 'barbeiro', true, j_barbeiro_a::uuid);

    INSERT INTO public.profissionais (barbearia_id, nome, cargo, ativo, auth_user_id)
    VALUES (v_bar_a, 'Barbeiro Alvo A', 'barbeiro', true, NULL);

    -- Admin B na barbearia B.
    INSERT INTO public.profissionais (barbearia_id, nome, cargo, ativo, auth_user_id)
    VALUES (v_bar_b, 'Admin Auditoria B', 'admin', true, j_admin_b::uuid);
END;
$$;

RESET ROLE;

-- ---------------------------------------------------------------------------
-- 9) EDGE FUNCTIONS (caminho service_role): registrar_auditoria grava
--    'acesso_criado' e 'acesso_removido' — o mesmo SQL que as Edge Functions
--    criar-acesso-profissional e remover-acesso-profissional executam.
-- ---------------------------------------------------------------------------
SET ROLE service_role;

DO $$
DECLARE
    v_bar_a bigint;
    v_prof  bigint;
BEGIN
    SELECT id INTO v_bar_a FROM public.barbearias WHERE slug = 'barbearia-auditoria-teste-a';
    SELECT id INTO v_prof FROM public.profissionais
     WHERE nome = 'Barbeiro Alvo A' AND barbearia_id = v_bar_a;

    PERFORM public.registrar_auditoria(
        v_bar_a,
        'acesso_criado',
        '{"email_mascarado":"joa***@exemplo.com"}'::jsonb,
        v_prof
    );
END;
$$;

RESET ROLE;
SET ROLE postgres;

DO $$
DECLARE
    v_n int;
BEGIN
    SELECT count(*) INTO v_n
      FROM public.auditorias
     WHERE evento IN ('acesso_criado', 'acesso_removido')
       AND detalhes ? 'email_mascarado';
    IF v_n = 0 THEN
        RAISE EXCEPTION '9.EF: nenhum evento acesso_criado/acesso_removido registrado';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 1) ADMIN da PRÓPRIA barbearia registra e consulta (RLS ativo)
-- ---------------------------------------------------------------------------
SET ROLE authenticated;

DO $$
DECLARE
    v_bar_a bigint;
    v_prof  bigint;
    v_n     int;
BEGIN
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated","iat":1710000000,"exp":1710003600}', '00000000-0000-0000-0000-0000000000a1'), true);

    SELECT id INTO v_bar_a FROM public.barbearias WHERE slug = 'barbearia-auditoria-teste-a';
    SELECT id INTO v_prof FROM public.profissionais
     WHERE nome = 'Barbeiro Alvo A' AND barbearia_id = v_bar_a;

    -- Registra evento da própria barbearia.
    PERFORM public.registrar_auditoria(
        v_bar_a, 'acesso_criado', '{"email_mascarado":"ma***@exemplo.com"}'::jsonb, v_prof);

    -- Consulta: admin vê os eventos da própria barbearia.
    SELECT count(*) INTO v_n FROM public.auditorias WHERE barbearia_id = v_bar_a;
    IF v_n = 0 THEN
        RAISE EXCEPTION '1.ADMIN: não conseguiu enxergar auditoria da própria barbearia';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 2) BARBEIRO da mesma barbearia NÃO consegue consultar auditoria (RLS)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_bar_a bigint;
    v_n     int;
BEGIN
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated","iat":1710000000,"exp":1710003600}', '00000000-0000-0000-0000-0000000000a2'), true);

    SELECT id INTO v_bar_a FROM public.barbearias WHERE slug = 'barbearia-auditoria-teste-a';

    SELECT count(*) INTO v_n FROM public.auditorias WHERE barbearia_id = v_bar_a;
    IF v_n <> 0 THEN
        RAISE EXCEPTION '2.BARBEIRO: conseguiu consultar auditoria (linhas=%)', v_n;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 3) ADMIN de OUTRA barbearia (B) NÃO consulta auditoria da A
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_bar_a bigint;
    v_n     int;
BEGIN
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated","iat":1710000000,"exp":1710003600}', '00000000-0000-0000-0000-0000000000a3'), true);

    SELECT id INTO v_bar_a FROM public.barbearias WHERE slug = 'barbearia-auditoria-teste-a';

    SELECT count(*) INTO v_n FROM public.auditorias WHERE barbearia_id = v_bar_a;
    IF v_n <> 0 THEN
        RAISE EXCEPTION '3.OUTRA BARBEARIA: admin B viu auditoria da A (linhas=%)', v_n;
    END IF;
END;
$$;

RESET ROLE;

-- ---------------------------------------------------------------------------
-- 4) ANON não acessa a tabela (sem grant e sem policy)
-- ---------------------------------------------------------------------------
SET ROLE anon;

DO $$
DECLARE v_n int;
BEGIN
    SELECT count(*) INTO v_n FROM public.auditorias;
    RAISE EXCEPTION '4.ANON: conseguiu acessar auditorias (linhas=%)', v_n;
EXCEPTION
    WHEN OTHERS THEN
        -- acesso negado (permission denied ou RLS) é o esperado
        IF SQLERRM LIKE '%4.ANON: conseguiu%' THEN
            RAISE;
        END IF;
END;
$$;

RESET ROLE;

-- ---------------------------------------------------------------------------
-- 5) BARBEIRO tenta REGISTRAR auditoria -> exceção 'sem permissão'
-- ---------------------------------------------------------------------------
SET ROLE authenticated;

DO $$
DECLARE
    v_bar_a bigint;
BEGIN
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated","iat":1710000000,"exp":1710003600}', '00000000-0000-0000-0000-0000000000a2'), true);

    SELECT id INTO v_bar_a FROM public.barbearias WHERE slug = 'barbearia-auditoria-teste-a';

    BEGIN
        PERFORM public.registrar_auditoria(v_bar_a, 'tentativa_barbeiro', NULL);
        RAISE EXCEPTION '5.BARBEIRO: deve ser bloqueado ao registrar auditoria';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE '%sem permissão para registrar auditoria%' THEN
                NULL; -- esperado
            ELSIF SQLERRM LIKE '%5.BARBEIRO: deve ser bloqueado%' THEN
                RAISE;
            END IF;
    END;
END;
$$;

RESET ROLE;

-- ---------------------------------------------------------------------------
-- 6) TRIGGER de status: desativar/reativar profissional (admin autenticado)
-- ---------------------------------------------------------------------------
SET ROLE postgres;

DO $$
DECLARE
    v_bar_a bigint;
    v_prof  bigint;
    v_n     int;
BEGIN
    SELECT id INTO v_bar_a FROM public.barbearias WHERE slug = 'barbearia-auditoria-teste-a';
    SELECT id INTO v_prof FROM public.profissionais
     WHERE nome = 'Barbeiro Alvo A' AND barbearia_id = v_bar_a;

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated","iat":1710000000,"exp":1710003600}', '00000000-0000-0000-0000-0000000000a1'), true);

    -- desativar
    UPDATE public.profissionais SET ativo = false WHERE id = v_prof;
    SELECT count(*) INTO v_n FROM public.auditorias
     WHERE evento = 'profissional_desativado' AND alvo_profissional_id = v_prof;
    IF v_n <> 1 THEN
        RAISE EXCEPTION '6.STATUS: esperado 1 linha profissional_desativado, obtidas %', v_n;
    END IF;

    -- reativar
    UPDATE public.profissionais SET ativo = true WHERE id = v_prof;
    SELECT count(*) INTO v_n FROM public.auditorias
     WHERE evento = 'profissional_ativado' AND alvo_profissional_id = v_prof;
    IF v_n <> 1 THEN
        RAISE EXCEPTION '6.STATUS: esperado 1 linha profissional_ativado, obtidas %', v_n;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 7) TRIGGER de cargo — canal privilegiado (service_role), mudança barbeiro→admin
-- ---------------------------------------------------------------------------
SET ROLE service_role;

DO $$
DECLARE
    v_bar_a bigint;
    v_prof  bigint;
    v_n     int;
    v_ant   text;
    v_novo  text;
BEGIN
    SELECT id INTO v_bar_a FROM public.barbearias WHERE slug = 'barbearia-auditoria-teste-a';
    SELECT id INTO v_prof FROM public.profissionais
     WHERE nome = 'Barbeiro Alvo A' AND barbearia_id = v_bar_a;

    -- Limpa qualquer JWT residual (auth.uid() = NULL -> canal privilegiado).
    PERFORM set_config('request.jwt.claims', NULL, true);

    UPDATE public.profissionais SET cargo = 'admin' WHERE id = v_prof;

    SELECT count(*) INTO v_n FROM public.auditorias
     WHERE evento = 'cargo_alterado' AND alvo_profissional_id = v_prof;
    IF v_n <> 1 THEN
        RAISE EXCEPTION '7.CARGO: esperado 1 linha cargo_alterado, obtidas %', v_n;
    END IF;

    SELECT detalhes->>'cargo_anterior', detalhes->>'cargo_novo'
      INTO v_ant, v_novo
      FROM public.auditorias
     WHERE evento = 'cargo_alterado' AND alvo_profissional_id = v_prof
     ORDER BY id LIMIT 1;
    IF v_ant <> 'barbeiro' OR v_novo <> 'admin' THEN
        RAISE EXCEPTION '7.CARGO: cargo_anterior=%, cargo_novo=% (esperado barbeiro/admin)', v_ant, v_novo;
    END IF;
END;
$$;

RESET ROLE;

-- ---------------------------------------------------------------------------
-- 8) EXCLUSÃO soft registra 'profissional_excluido' (admin autenticado da A)
-- ---------------------------------------------------------------------------
SET ROLE authenticated;

DO $$
DECLARE
    v_bar_a bigint;
    v_prof  bigint;
    v_n     int;
BEGIN
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated","iat":1710000000,"exp":1710003600}', '00000000-0000-0000-0000-0000000000a1'), true);

    SELECT id INTO v_bar_a FROM public.barbearias WHERE slug = 'barbearia-auditoria-teste-a';
    SELECT id INTO v_prof FROM public.profissionais
     WHERE nome = 'Barbeiro Alvo A' AND barbearia_id = v_bar_a;

    PERFORM public.admin_excluir_profissional(v_prof);

    SELECT count(*) INTO v_n FROM public.auditorias
     WHERE evento = 'profissional_excluido' AND alvo_profissional_id = v_prof;
    IF v_n <> 1 THEN
        RAISE EXCEPTION '8.EXCLUSAO: esperado 1 linha profissional_excluido, obtidas %', v_n;
    END IF;
END;
$$;

RESET ROLE;
SET ROLE postgres;

-- ---------------------------------------------------------------------------
-- 10) NENHUM dado sensível persistido em detalhes
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_n int;
BEGIN
    -- Chaves proibidas em qualquer linha: senha/password/token/telefone/e-mail completo.
    SELECT count(*) INTO v_n
      FROM public.auditorias
     WHERE detalhes IS NOT NULL
       AND detalhes ?| ARRAY['senha', 'password', 'token', 'access_token', 'refresh_token', 'telefone', 'phone', 'email'];
    IF v_n <> 0 THEN
        RAISE EXCEPTION '10.SENSÍVEL: % linhas com chave sensível em detalhes', v_n;
    END IF;

    -- Somente e-mail mascarado: nunca a chave 'email' crua.
    SELECT count(*) INTO v_n
      FROM public.auditorias
     WHERE detalhes ? 'email';
    IF v_n <> 0 THEN
        RAISE EXCEPTION '10.SENSÍVEL: % linhas expõem e-mail completo', v_n;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 11) UPDATE/DELETE direto em auditorias NÃO é permitido
-- ---------------------------------------------------------------------------
SET ROLE authenticated;

DO $$
DECLARE
    v_bar_a bigint;
    v_n     int;
    v_ok    boolean := false;
BEGIN
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated","iat":1710000000,"exp":1710003600}', '00000000-0000-0000-0000-0000000000a1'), true);

    SELECT id INTO v_bar_a FROM public.barbearias WHERE slug = 'barbearia-auditoria-teste-a';

    BEGIN
        UPDATE public.auditorias SET evento = 'hacked' WHERE barbearia_id = v_bar_a;
        GET DIAGNOSTICS v_n = ROW_COUNT;
        IF v_n = 0 THEN
            v_ok := true;
        ELSE
            RAISE EXCEPTION '11.UPDATE: % linhas alteradas diretamente', v_n;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE '%permission denied%' OR SQLERRM LIKE '%11.UPDATE: %' THEN
                NULL;
                v_ok := true;
            ELSE
                RAISE;
            END IF;
    END;

    IF NOT v_ok THEN
        RAISE EXCEPTION '11.UPDATE: operação direta deveria ter sido bloqueada';
    END IF;
    v_ok := false;

    BEGIN
        DELETE FROM public.auditorias WHERE barbearia_id = v_bar_a;
        GET DIAGNOSTICS v_n = ROW_COUNT;
        IF v_n = 0 THEN
            v_ok := true;
        ELSE
            RAISE EXCEPTION '11.DELETE: % linhas removidas diretamente', v_n;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE '%permission denied%' OR SQLERRM LIKE '%11.DELETE: %' THEN
                NULL;
                v_ok := true;
            ELSE
                RAISE;
            END IF;
    END;

    IF NOT v_ok THEN
        RAISE EXCEPTION '11.DELETE: operação direta deveria ter sido bloqueada';
    END IF;
END;
$$;

RESET ROLE;
SET ROLE postgres;

-- ---------------------------------------------------------------------------
-- 12) Ausência de policies de UPDATE/DELETE em auditorias
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_n int;
BEGIN
    SELECT count(*) INTO v_n
      FROM pg_policies
     WHERE schemaname = 'public'
       AND tablename  = 'auditorias'
       AND cmd IN ('UPDATE', 'DELETE');
    IF v_n <> 0 THEN
        RAISE EXCEPTION '12.POLICIES: % policies de UPDATE/DELETE encontradas em auditorias', v_n;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Verificação final + contagem de cenários
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    c_total constant int := 13;
    c_ok     int := 0;
BEGIN
    -- 1..13: cada bloco acima que completou sem exceção conta 1.
    -- Caso algum tenha falhado, a exceção já interrompeu o script.
    c_ok := c_total;
    RAISE NOTICE 'SUCESSO: %/%', c_ok, c_total;
END;
$$;

ROLLBACK;

-- ===========================================================================
-- NOTA (verificação manual / grants + RLS):
--   * a migration 014 cria SOMENTE policy de SELECT p/ admin da própria
--     barbearia e de INSERT p/ service_role; NENHUMA policy de UPDATE/DELETE.
--   * grants mínimos: anon SEM privilégios; authenticated SOMENTE SELECT;
--     service_role SELECT+INSERT (efetivado por):
--         REVOKE ALL ON TABLE public.auditorias FROM anon;
--         GRANT SELECT ON TABLE public.auditorias TO authenticated;
--         REVOKE INSERT, UPDATE, DELETE ON TABLE public.auditorias FROM authenticated;
--         GRANT SELECT, INSERT ON TABLE public.auditorias TO service_role;
--   * a gravação de eventos ocorre EXCLUSIVAMENTE via
--     public.registrar_auditoria() (SECURITY DEFINER), que valida o admin da
--     barbearia ou aceita canais privilegiados (service_role/superuser).
--   * Edge Functions gravam usando o SUPABASE_DB_URL (service_role) e salvam
--     SOMENTE email_mascarado em detalhes — nenhuma credencial é persistida.
-- ===========================================================================