-- =====================================================================
-- SISTEMA DE GESTÃO DE BARBEARIAS — POLICIES RLS
-- Plataforma: Supabase (PostgreSQL)
-- Como executar (POSTERIORMENTE): Supabase Dashboard > SQL Editor.
--
-- AVISO:
--   * Este arquivo NÃO deve ser executado antes da validação da equipe.
--   * O schema já habilitou RLS nas 7 tabelas; este arquivo apenas define
--     as policies (e os privilégios mínimos) necessárias para operar.
--   * Nada aqui é aplicado automaticamente. Nada aqui é executado agora.
--   * Nesta etapa o papel anon NÃO recebe nenhum acesso: o agendamento
--     público será feito por meio de servidor (Edge Function), conforme
--     seção 12.
--
-- REGRA CENTRAL DE SEGURANÇA:
--   * Nunca confiar em barbearia_id enviado pelo frontend.
--   * Para autenticados, a barbearia é SEMPRE derivada de
--       profissionais.auth_user_id = auth.uid()
--     e então  profissionais.barbearia_id.
--   * Nenhuma policy usa USING (true) / WITH CHECK (true).
--   * Toda ESCREITA em agendamentos passa por funções RPC (SECURITY
--     DEFINER) que validam cargo, barbearia e transição de status.
--     Ver seções 9 (RPCs) e 11 (grants mínimos).
-- =====================================================================

-- =====================================================================
-- 1. FUNÇÕES AUXILIARES (SECURITY DEFINER)
-- =====================================================================
-- POR QUE SECURITY DEFINER É NECESSÁRIO AQUI:
--   As policies consultam "profissionais" para identificar o usuário
--   autenticado (auth.uid()). Se essa consulta fosse feita dentro da
--   própria policy, ela ficaria sujeita ao RLS de profissionais — e a
--   policy de profissionais também dependeria de consultar profissionais,
--   gerando RECURSÃO (ou resultado vazio por causa da própria proteção).
--
--   Para quebrar esse ciclo, as funções abaixo rodam como dono (postgres)
--   e retornam SOMENTE identificação (id/barbearia/booleanos) — não
--   expõem dados de negócio. Não há escalada de privilégio de dados.
--
--   Medidas de segurança (todas as funções deste arquivo):
--     * security definer + set search_path = '': o caminho de busca fica
--       vazio, então NENHUMA tabela/objeto é resolvido por convenção — todo
--       nome precisa ser explicitamente qualificado (public.profissionais,
--       public.agendamentos, auth.uid()). Isso bloqueia substituição de
--       schema via search_path do chamador (defesa contra hijacking).
--     * revoke execute ... from public, anon  +  grant execute SOMENTE
--       para a role authenticated (ou role específica quando indicado).
--     * auth.uid() é lido do token JWT (GUC), nunca de parâmetros.
--     * Os argumentos são tipados (bigint / text / timestamp with time
--       zone) e os retornos qualificados (public.agendamentos), então o
--       PostgreSQL rejeita valores fora do esquema esperado.

-- (a) id do profissional ativo do usuário logado
--     deleted_at IS NULL: profissional excluído (soft delete) NUNCA opera,
--     mesmo se ativo for reativado por engano.
CREATE OR REPLACE FUNCTION public.profissional_autenticado_id()
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT p.id
  FROM public.profissionais p
  WHERE p.auth_user_id = auth.uid()
    AND p.ativo = true
    AND p.deleted_at IS NULL
  LIMIT 1;
$$;

-- (b) barbearia do usuário logado (nunca vem da requisição)
CREATE OR REPLACE FUNCTION public.barbearia_profissional_autenticado()
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT p.barbearia_id
  FROM public.profissionais p
  WHERE p.auth_user_id = auth.uid()
    AND p.ativo = true
    AND p.deleted_at IS NULL
  LIMIT 1;
$$;

-- (c) o usuário logado pertence à barbearia informada?
CREATE OR REPLACE FUNCTION public.usuario_pertence_a_barbearia(p_barbearia bigint)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profissionais p
    WHERE p.auth_user_id = auth.uid()
      AND p.barbearia_id = p_barbearia
      AND p.ativo = true
      AND p.deleted_at IS NULL
  );
$$;

-- (d) o usuário logado é admin da barbearia informada?
CREATE OR REPLACE FUNCTION public.usuario_e_admin_da_barbearia(p_barbearia bigint)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profissionais p
    WHERE p.auth_user_id = auth.uid()
      AND p.cargo = 'admin'
      AND p.barbearia_id = p_barbearia
      AND p.ativo = true
      AND p.deleted_at IS NULL
  );
$$;

-- (e) o usuário logado é um barbeiro ATIVO (cargo = 'barbeiro')?
--     Chamada pela RPC destinada ao barbeiro para impedir que um admin
--     (que também é um profissional ativo) a utilize indevidamente.
CREATE OR REPLACE FUNCTION public.usuario_e_barbeiro_autenticado()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profissionais p
    WHERE p.auth_user_id = auth.uid()
      AND p.cargo = 'barbeiro'
      AND p.ativo = true
      AND p.deleted_at IS NULL
  );
$$;

REVOKE ALL ON FUNCTION public.profissional_autenticado_id() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.barbearia_profissional_autenticado() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.usuario_pertence_a_barbearia(bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.usuario_e_admin_da_barbearia(bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.usuario_e_barbeiro_autenticado() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.profissional_autenticado_id() TO authenticated;
GRANT EXECUTE ON FUNCTION public.barbearia_profissional_autenticado() TO authenticated;
GRANT EXECUTE ON FUNCTION public.usuario_pertence_a_barbearia(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.usuario_e_admin_da_barbearia(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.usuario_e_barbeiro_autenticado() TO authenticated;

-- (f) governança de cargo — trigger usado por trg_profissionais_proteger_cargo.
--     F7.1: um UPDATE comum (admin da própria barbearia) NÃO pode alterar a
--     coluna cargo; o admin não pode se auto-demover e nenhuma alteração pode
--     deixar a barbearia sem admin. Só operações que NÃO alteram cargo seguem
--     normalmente (nome/telefone/ativo/auth_user_id/deleted_at).
CREATE OR REPLACE FUNCTION public.trf_profissionais_proteger_cargo()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  -- Sem mudança de cargo: fluxo normal (criação de acesso, ativação/desativação
  -- via admin, soft delete) não é afetado.
  IF NEW.cargo IS NOT DISTINCT FROM OLD.cargo THEN
    RETURN NEW;
  END IF;

  -- 1) Nenhum usuário de aplicação (profissional autenticado — admin ou
  --    barbeiro da própria barbearia) pode mudar cargo num UPDATE direto.
  IF public.usuario_pertence_a_barbearia(NEW.barbearia_id) THEN
    RAISE EXCEPTION 'alteração de cargo é uma operação restrita';
  END IF;

  -- 2) Defesa em profundidade para canais privilegiados (service_role/
  --    superuser, em que auth.uid() é nulo): nunca deixar a barbearia sem
  --    nenhum admin ATIVO quando um admin é rebaixado para barbeiro.
  IF OLD.cargo = 'admin' AND NEW.cargo = 'barbeiro' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.profissionais p
       WHERE p.barbearia_id = OLD.barbearia_id
         AND p.cargo = 'admin'
         AND p.ativo = true
         AND p.deleted_at IS NULL
         AND p.id <> OLD.id
    ) THEN
      RAISE EXCEPTION 'não é possível rebaixar o único administrador da barbearia';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.trf_profissionais_proteger_cargo() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.trf_profissionais_proteger_cargo() TO authenticated;

-- Trigger de governança de cargo (F7.1): cria junto da função. Aplica-se a
-- UPDATE que altere profissionais.cargo; INSERT não dispara (novo profissional
-- nasce 'barbeiro'). Também pode ser instalado isoladamente via
-- database/migrations/013_protect_profissionais_cargo.sql.
DROP TRIGGER IF EXISTS trg_profissionais_proteger_cargo ON public.profissionais;

CREATE TRIGGER trg_profissionais_proteger_cargo
    BEFORE UPDATE OF cargo ON public.profissionais
    FOR EACH ROW EXECUTE FUNCTION public.trf_profissionais_proteger_cargo();

-- =====================================================================
-- 2. REGRA DE TRANSIÇÃO DE STATUS (central, usada pelas funções)
-- =====================================================================
-- A tabela guarda apenas o status ATUAL. O PostgreSQL não conhece o
-- status ANTERIOR apenas olhando a linha (uma policy de UPDATE enxerga
-- só o estado pós-escrita). Para impedir transições inválidas é preciso
-- conhecer o status anterior — por isso a validação acontece DENTRO da
-- função (que pode comparar o NEW e o OLD da linha).
--
-- Transições permitidas (tabela do plano):
--   pendente  -> confirmado | cancelado
--   confirmado-> concluido  | cancelado
--   (qualquer outra transição é recusada com exceção)
--
-- Como a EXCLUSÃO não passa por esta função e o status também não pode
-- "voltar", a tabela vira um registro de eventos:
--   cancelado não pode voltar; concluido não pode voltar; nunca se atualiza
--   um agendamento já finalizado.
CREATE OR REPLACE FUNCTION public.transicao_status_valida(novo text, atual text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT (atual, novo) IN (
    ('pendente'  , 'confirmado'),
    ('pendente'  , 'cancelado'),
    ('confirmado', 'concluido'),
    ('confirmado', 'cancelado')
  );
$$;

-- =====================================================================
-- 3. DROP POLICY IF EXISTS (execução segura/idempotente)
-- =====================================================================
DROP POLICY IF EXISTS "barbearias_select_propria"          ON public.barbearias;
DROP POLICY IF EXISTS "barbearias_update_admin"            ON public.barbearias;

DROP POLICY IF EXISTS "profissionais_select_propria"       ON public.profissionais;
DROP POLICY IF EXISTS "profissionais_write_admin"          ON public.profissionais;
DROP POLICY IF EXISTS "profissionais_insert_admin"         ON public.profissionais;
DROP POLICY IF EXISTS "profissionais_update_admin"         ON public.profissionais;

DROP POLICY IF EXISTS "servicos_select_propria"            ON public.servicos;
DROP POLICY IF EXISTS "servicos_write_admin"               ON public.servicos;
DROP POLICY IF EXISTS "servicos_insert_admin"              ON public.servicos;
DROP POLICY IF EXISTS "servicos_update_admin"              ON public.servicos;

DROP POLICY IF EXISTS "clientes_select_propria"            ON public.clientes;
DROP POLICY IF EXISTS "clientes_write_admin"               ON public.clientes;
DROP POLICY IF EXISTS "clientes_update_admin"              ON public.clientes;

DROP POLICY IF EXISTS "agendamentos_select_propria"        ON public.agendamentos;
DROP POLICY IF EXISTS "agendamentos_insert_admin"          ON public.agendamentos;
DROP POLICY IF EXISTS "agendamentos_update_admin"          ON public.agendamentos;
DROP POLICY IF EXISTS "agendamentos_update_status_barbeiro" ON public.agendamentos;
DROP POLICY IF EXISTS "agendamentos_delete_admin"          ON public.agendamentos;

DROP POLICY IF EXISTS "horarios_select_propria"            ON public.horarios_funcionamento;
DROP POLICY IF EXISTS "horarios_write_admin"               ON public.horarios_funcionamento;

DROP POLICY IF EXISTS "bloqueios_select_propria"           ON public.bloqueios_agenda;
DROP POLICY IF EXISTS "bloqueios_write_admin"              ON public.bloqueios_agenda;

-- =====================================================================
-- 4. POLICIES — barbearias
-- =====================================================================
CREATE POLICY "barbearias_select_propria"
  ON public.barbearias
  FOR SELECT TO authenticated
  USING (public.usuario_pertence_a_barbearia(id));

CREATE POLICY "barbearias_update_admin"
  ON public.barbearias
  FOR UPDATE TO authenticated
  USING (public.usuario_e_admin_da_barbearia(id))
  WITH CHECK (public.usuario_e_admin_da_barbearia(id));

-- =====================================================================
-- 5. POLICIES — profissionais
-- =====================================================================
CREATE POLICY "profissionais_select_propria"
  ON public.profissionais
  FOR SELECT TO authenticated
  USING (public.usuario_pertence_a_barbearia(barbearia_id));

-- Escrita do admin: SOMENTE INSERT e UPDATE. NÃO existe policy de DELETE:
-- a exclusão de profissional é exclusiva da RPC admin_excluir_profissional
-- (soft delete via deleted_at/ativo) e o RLS nega DELETE por padrão.
CREATE POLICY "profissionais_insert_admin"
  ON public.profissionais
  FOR INSERT TO authenticated
  WITH CHECK (public.usuario_e_admin_da_barbearia(barbearia_id));

CREATE POLICY "profissionais_update_admin"
  ON public.profissionais
  FOR UPDATE TO authenticated
  USING (public.usuario_e_admin_da_barbearia(barbearia_id))
  WITH CHECK (public.usuario_e_admin_da_barbearia(barbearia_id));

-- =====================================================================
-- 6. POLICIES — servicos
-- =====================================================================
CREATE POLICY "servicos_select_propria"
  ON public.servicos
  FOR SELECT TO authenticated
  USING (public.usuario_pertence_a_barbearia(barbearia_id));

-- Escrita do admin: SOMENTE INSERT e UPDATE (sem DELETE).
CREATE POLICY "servicos_insert_admin"
  ON public.servicos
  FOR INSERT TO authenticated
  WITH CHECK (public.usuario_e_admin_da_barbearia(barbearia_id));

CREATE POLICY "servicos_update_admin"
  ON public.servicos
  FOR UPDATE TO authenticated
  USING (public.usuario_e_admin_da_barbearia(barbearia_id))
  WITH CHECK (public.usuario_e_admin_da_barbearia(barbearia_id));

-- =====================================================================
-- 7. POLICIES — clientes
-- =====================================================================
CREATE POLICY "clientes_select_propria"
  ON public.clientes
  FOR SELECT TO authenticated
  USING (
    public.usuario_e_admin_da_barbearia(barbearia_id)
    OR (
      public.barbearia_profissional_autenticado() = barbearia_id
      AND EXISTS (
        SELECT 1 FROM public.agendamentos a
        WHERE a.cliente_id = clientes.id
          AND a.barbeiro_id = public.profissional_autenticado_id()
      )
    )
  );

-- Escrita do admin: SOMENTE UPDATE (sem INSERT — criação é via RPC
-- criar_cliente; sem DELETE — não existe exclusão física no produto, o
-- cliente é desativado via UPDATE ativo = false).
CREATE POLICY "clientes_update_admin"
  ON public.clientes
  FOR UPDATE TO authenticated
  USING (public.usuario_e_admin_da_barbearia(barbearia_id))
  WITH CHECK (public.usuario_e_admin_da_barbearia(barbearia_id));

-- =====================================================================
-- 8. POLICIES — agendamentos
-- =====================================================================
-- IMPORTANTE: NÃO existe policy de UPDATE nem de INSERT/DELETE direto
-- para "authenticated" em agendamentos. Toda escrita em agendamentos passa
-- pelas funções RPC da seção 9 (que controlam cargo + colunas + transição
-- de status). Mantemos apenas a policy de LEITURA abaixo.

-- Leitura: admin vê TODOS da própria barbearia; barbeiro vê SÓ os seus.
CREATE POLICY "agendamentos_select_propria"
  ON public.agendamentos
  FOR SELECT TO authenticated
  USING (
    public.usuario_e_admin_da_barbearia(barbearia_id)
    OR barbeiro_id = public.profissional_autenticado_id()
  );

-- (Sem policies de INSERT/UPDATE/DELETE de agendamentos para não abrir
--  um caminho direto que contorne as funções RPC.)

-- =====================================================================
-- 9. FUNÇÕES RPC — ESCRITA EM agendamentos
-- =====================================================================
-- POR QUE FUNÇÕES SÃO NECESSÁRIAS AQUI:
--   * Não existe, no PostgreSQL, uma forma de RLS dizer "só pode atualizar
--     estas colunas". RLS enxerga a linha inteira (USING/WITH CHECK) e não
--     distingue coluna. A restrição de coluna é feita por GRANT ou por
--     camada acima (função).
--   * Já demonstramos que GRANT de tabela inteira dá todas as colunas ao
--     barbeiro. GRANT por coluna também não funciona: basta conceder
--     QUALQUER UPDATE de tabela e o barbeiro escreve qualquer coluna;
--     conceder apenas colunas ao barbeiro impede o admin de fazer UPDATE
--     completo — e não dá para dar "todas" a um role e "algumas" a outro.
--   * A transição de status só é validável conhecendo o status ANTERIOR
--     (OLD), que uma policy não enxerga.
--   * Conclusão: a escrita em agendamentos passa a ocorrer APENAS por
--     funções SQL (RPC) com security definer. Dentro delas validamos:
--       - quem está chamando (cargo/barbearia derivados de auth.uid());
--       - QUAIS colunas são escritas (o conjunto é FIXO por função);
--       - a transição de status (OLD vs NEW).
--     Sem QUALQUER GRANT de INSERT/UPDATE/DELETE de tabela para os roles,
--     ninguém contorna a função por fora.

-- ------------------------------------------------------------------
-- 9.1 ADMIN — atualizar agendamento (todas as colunas operáveis)
-- ------------------------------------------------------------------
-- O admin só mexe em agendamentos da PRÓPRIA barbearia. Recebemos os
-- valores operáveis (barbeiro, serviço, cliente, horários, status,
-- observações). O id e a barbearia nunca são sobreescritos pelo cliente.
-- Confirma-se que o agendamento pertence à barbearia do admin e que a
-- transição de status é válida. Retorna os dados atualizados.
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

-- ------------------------------------------------------------------
-- 9.2 ADMIN — criar agendamento
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_criar_agendamento(
  p_barbearia_id bigint,
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
  -- Só pode criar se o próprio admin pertence à barbearia informada.
  IF NOT public.usuario_e_admin_da_barbearia(p_barbearia_id) THEN
    RAISE EXCEPTION 'somente admin da própria barbearia pode criar agendamento';
  END IF;

  -- Novo agendamento começa SÓ como 'pendente' (não admite outros status
  -- no momento da criação; para confirmar/alterar usa admin_atualizar).
  IF p_status IS NOT NULL AND p_status <> 'pendente' THEN
    RAISE EXCEPTION 'novo agendamento deve iniciar com status pendente';
  END IF;

  -- Barbeiro deve existir, ser da mesma barbearia, ativo e NÃO excluído
  -- (a linha excluída permanece para o histórico, mas não recebe novos
  -- agendamentos — o guard impede o contorno via RPC).
  IF NOT EXISTS (
    SELECT 1 FROM public.profissionais p
     WHERE p.id = p_barbeiro_id
       AND p.barbearia_id = p_barbearia_id
       AND p.cargo = 'barbeiro'
       AND p.ativo = true
       AND p.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'barbeiro inválido ou indisponível';
  END IF;

  INSERT INTO public.agendamentos (
    barbearia_id, barbeiro_id, servico_id, cliente_id,
    data_hora_inicio, data_hora_fim, status, observacoes
  ) VALUES (
    p_barbearia_id, p_barbeiro_id, p_servico_id, p_cliente_id,
    p_data_hora_inicio, p_data_hora_fim,
    COALESCE(p_status, 'pendente'), p_observacoes
  )
  RETURNING * INTO v_agendamento;

  RETURN v_agendamento;
END;
$$;

-- ------------------------------------------------------------------
-- 9.3 ADMIN — excluir agendamento
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_excluir_agendamento(p_agendamento_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  DELETE FROM public.agendamentos a
   WHERE a.id = p_agendamento_id
     AND public.usuario_e_admin_da_barbearia(a.barbearia_id);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'agendamento não encontrado ou pertence a outra barbearia';
  END IF;
END;
$$;

-- ------------------------------------------------------------------
-- 9.3.B ADMIN — excluir profissional (soft delete, NUNCA DELETE físico)
-- ------------------------------------------------------------------
-- Excluir = marcar deleted_at = now() + ativo = false. A linha permanece
-- para preservar o histórico (FKs RESTRICT de agendamentos/bloqueios). A
-- remoção do acesso (Supabase Auth) é feita em etapa separada, do servidor
-- (Edge Function remover-acesso-profissional). O id/barbearia do alvo NUNCA
-- vêm do payload: a barbearia é derivada do REGISTRO do profissional.
CREATE OR REPLACE FUNCTION public.admin_excluir_profissional(p_profissional_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_barbearia        bigint;
  v_cargo            text;
  v_id_autenticado   bigint;
BEGIN
  SELECT p.barbearia_id, p.cargo
    INTO v_barbearia, v_cargo
    FROM public.profissionais p
   WHERE p.id = p_profissional_id;

  IF v_barbearia IS NULL THEN
    RAISE EXCEPTION 'profissional não encontrado';
  END IF;

  -- Somente Admin da MESMA barbearia do profissional alvo.
  IF NOT public.usuario_e_admin_da_barbearia(v_barbearia) THEN
    RAISE EXCEPTION 'somente admin da própria barbearia pode excluir profissional';
  END IF;

  -- O admin não pode excluir o próprio cadastro (ficaria sem acesso).
  v_id_autenticado := public.profissional_autenticado_id();
  IF v_id_autenticado = p_profissional_id THEN
    RAISE EXCEPTION 'você não pode excluir o próprio cadastro';
  END IF;

  -- Não pode excluir o ÚNICO admin ativo (não excluído) da barbearia.
  IF v_cargo = 'admin' AND NOT EXISTS (
    SELECT 1 FROM public.profissionais p
     WHERE p.barbearia_id = v_barbearia
       AND p.cargo = 'admin'
       AND p.ativo = true
       AND p.deleted_at IS NULL
       AND p.id <> p_profissional_id
  ) THEN
    RAISE EXCEPTION 'não é possível excluir o único administrador da barbearia';
  END IF;

  UPDATE public.profissionais
     SET deleted_at = now(),
         ativo      = false,
         updated_at = now()
   WHERE id = p_profissional_id
     AND deleted_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'profissional não encontrado ou já excluído';
  END IF;
END;
$$;

-- ------------------------------------------------------------------
-- 9.4 BARBEIRO — atualizar SOMENTE status/observacoes dos PRÓPRIOS
-- ------------------------------------------------------------------
-- Esta é a única forma de um barbeiro alterar um agendamento. Ela:
--   1. exige que o usuário autenticado tenha cargo = 'barbeiro' (o admin,
--      mesmo sendo um profissional ativo, NÃO pode usar esta RPC);
--   2. só aceita agendamentos em que barbeiro_id = o próprio barbeiro;
--   3. só escreve NAS colunas status e observacoes (fixo no comando);
--   4. valida a transição com base no status anterior (OLD);
--   5. rejeita qualquer tentativa de tocar id/barbearia/cliente/barbeiro/
--      servico/horários/created_at/updated_at (colunas fora do SET/batch).
CREATE OR REPLACE FUNCTION public.barbeiro_atualizar_status(
  p_agendamento_id bigint,
  p_novo_status text,
  p_novas_observacoes text DEFAULT NULL
)
RETURNS public.agendamentos
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id      bigint := public.profissional_autenticado_id();
  v_agendamento public.agendamentos;
BEGIN
  IF v_id IS NULL OR NOT public.usuario_e_barbeiro_autenticado() THEN
    RAISE EXCEPTION 'somente um barbeiro ativo pode alterar o status de agendamentos';
  END IF;

  UPDATE public.agendamentos a
     SET status      = p_novo_status,
         observacoes = COALESCE(p_novas_observacoes, a.observacoes)
   WHERE a.id = p_agendamento_id
     AND a.barbeiro_id = v_id                     -- SÓ os próprios
     AND (
       p_novo_status = a.status                   -- ex.: só atualizar obs.
       OR public.transicao_status_valida(p_novo_status, a.status)
     )
  RETURNING * INTO v_agendamento;

  IF v_agendamento.id IS NULL THEN
    RAISE EXCEPTION 'agendamento não encontrado, não pertence a este barbeiro ou transição de status inválida';
  END IF;

  RETURN v_agendamento;
END;
$$;

-- ------------------------------------------------------------------
-- 9.4.B BARBEIRO — criar agendamento (SOMENTE para si mesmo)
-- ------------------------------------------------------------------
-- Extensão do fluxo 9.4: o barbeiro pode criar manualmente um agendamento
-- no painel, mas APENAS para si mesmo e dentro da própria barbearia. Por
-- isso esta RPC:
--   1. NÃO aceita p_barbeiro_id nem p_barbearia_id: ambos são derivados
--      do token JWT (auth.uid()) via professional_autenticado_id() e
--      barbearia_profissional_autenticado() — o barbeiro NUNCA consegue
--      criar para outro profissional;
--   2. exige cargo 'barbeiro' ativo (usuario_e_barbeiro_autenticado());
--      o admin continua usando admin_criar_agendamento;
--   3. força status inicial 'pendente' (mesma regra do admin);
--   4. valida explicitamente cliente e serviço ATIVOS da própria
--      barbearia (as FKs compostas reforçam, mas o erro fica amigável);
--   5. insere SEMPRE com barbeiro_id/barbearia_id internos (nunca do
--      cliente).
-- As autoridades já existentes continuam valendo no INSERT (nada é
-- desligado):
--   * M1 (trg_agendamentos_derivar_duracao) deriva data_hora_fim do
--     serviço;
--   * A1/M1 (trg_agendamentos_validar_bloqueios) valida horário/bloqueio;
--   * ux_agendamentos_sem_conflito impede sobreposição do MESMO barbeiro.
-- Continua SEM policy/GRANT de INSERT direto em agendamentos.
CREATE OR REPLACE FUNCTION public.barbeiro_criar_agendamento(
  p_servico_id bigint,
  p_cliente_id bigint,
  p_data_hora_inicio timestamp with time zone,
  p_observacoes text DEFAULT NULL
)
RETURNS public.agendamentos
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_barbeiro   bigint;
  v_barbearia  bigint;
  v_agendamento public.agendamentos;
BEGIN
  v_barbeiro  := public.profissional_autenticado_id();
  v_barbearia := public.barbearia_profissional_autenticado();

  IF v_barbeiro IS NULL OR NOT public.usuario_e_barbeiro_autenticado() THEN
    RAISE EXCEPTION 'somente um barbeiro ativo pode criar agendamentos';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.clientes c
     WHERE c.id = p_cliente_id
       AND c.barbearia_id = v_barbearia
       AND c.ativo = true
  ) THEN
    RAISE EXCEPTION 'cliente inválido ou de outra barbearia';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.servicos s
     WHERE s.id = p_servico_id
       AND s.barbearia_id = v_barbearia
       AND s.ativo = true
  ) THEN
    RAISE EXCEPTION 'serviço inválido ou de outra barbearia';
  END IF;

  -- data_hora_fim é DERIVADO pela M1; o placeholder abaixo é sobrescrito.
  INSERT INTO public.agendamentos (
    barbearia_id, cliente_id, barbeiro_id, servico_id,
    data_hora_inicio, data_hora_fim, status, observacoes
  ) VALUES (
    v_barbearia, p_cliente_id, v_barbeiro, p_servico_id,
    p_data_hora_inicio, p_data_hora_inicio + interval '1 minute',
    'pendente', p_observacoes
  )
  RETURNING * INTO v_agendamento;

  RETURN v_agendamento;
END;
$$;

-- ------------------------------------------------------------------
-- 9.4.C BARBEIRO — leitura segura dos clientes para criar agendamento
-- ------------------------------------------------------------------
-- Pela policy atual (clientes_select_propria), um barbeiro só enxerga
-- clientes com quem JÁ tem agendamento — a lista ficaria vazia (ou
-- incompleta) ao montar o modal de criação. Esta RPC de leitura
-- (SECURITY DEFINER, sem ampliar policies/RLS) devolve APENAS os campos
-- necessários (id, nome, telefone, ativo) dos clientes ATIVOS da PRÓPRIA
-- barbearia do profissional autenticado. Nada além disso é exposto.
CREATE OR REPLACE FUNCTION public.listar_clientes_para_agendamento()
RETURNS TABLE (id bigint, nome text, telefone text, ativo boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF public.profissional_autenticado_id() IS NULL THEN
    RAISE EXCEPTION 'somente um profissional ativo da barbearia pode listar clientes';
  END IF;

  RETURN QUERY
    SELECT c.id, c.nome, c.telefone, c.ativo
      FROM public.clientes c
     WHERE c.barbearia_id = public.barbearia_profissional_autenticado()
       AND c.ativo = true
     ORDER BY c.nome;
END;
$$;

-- ------------------------------------------------------------------
-- 9.4.D CADASTRO de clientes — RPC public.criar_cliente (M006)
-- ------------------------------------------------------------------
-- Regra aprovada: barbeiro CADASTRA novos clientes e os usa em
-- agendamentos; NÃO edita, NÃO desativa e NÃO recebe outras permissões
-- administrativas. Admin mantém criar/editar/ativar/desativar.
--
-- Esta é a ÚNICA via de criação em clientes (REVOKE INSERT na seção 11):
--   * p_barbearia_id/p_barbeiro_id NUNCA são aceitos — a barbearia é
--     DERIVADA do auth.uid() no banco;
--   * aceita admin OU barbeiro ativo (e não excluído — M005) da própria
--     barbearia;
--   * para barbeiro, força ativo = true (sem poder administrativo);
--   * validação server-side mínima (nome/telefone/e-mail).
CREATE OR REPLACE FUNCTION public.criar_cliente(
  p_nome text,
  p_telefone text,
  p_email text DEFAULT NULL,
  p_observacoes text DEFAULT NULL,
  p_ativo boolean DEFAULT true
)
RETURNS public.clientes
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_barbearia bigint;
  v_cliente   public.clientes;
  v_admin     boolean;
BEGIN
  v_barbearia := public.barbearia_profissional_autenticado();

  IF v_barbearia IS NULL THEN
    RAISE EXCEPTION 'somente um profissional ativo da barbearia pode cadastrar clientes';
  END IF;

  v_admin := public.usuario_e_admin_da_barbearia(v_barbearia);
  IF NOT v_admin AND NOT public.usuario_e_barbeiro_autenticado() THEN
    RAISE EXCEPTION 'somente um profissional ativo da barbearia pode cadastrar clientes';
  END IF;

  -- Barbeiro NÃO possui poder administrativo: não pode criar cliente inativo.
  IF NOT v_admin THEN
    p_ativo := true;
  END IF;

  -- Normalizar telefone (somente dígitos) antes de gravar (M011).
  p_telefone := public.normalizar_telefone(p_telefone);

  -- Validação server-side mínima (réplica das regras do painel/da tabela).
  IF trim(coalesce(p_nome, '')) = '' THEN
    RAISE EXCEPTION 'nome do cliente é obrigatório';
  END IF;
  IF p_telefone IS NULL OR p_telefone = '' THEN
    RAISE EXCEPTION 'telefone do cliente é obrigatório';
  END IF;
  IF p_email IS NOT NULL AND p_email !~* '^[^@\s]+@[^@\s]+$' THEN
    RAISE EXCEPTION 'e-mail inválido';
  END IF;

  INSERT INTO public.clientes (barbearia_id, nome, telefone, email, observacoes, ativo)
  VALUES (
    v_barbearia,
    trim(p_nome),
    p_telefone,
    nullif(trim(coalesce(p_email, '')), ''),
    nullif(trim(coalesce(p_observacoes, '')), ''),
    p_ativo
  )
  RETURNING * INTO v_cliente;

  RETURN v_cliente;
END;
$$;

-- ------------------------------------------------------------------
-- 9.4.E LEITURA (M006) — clientes (campos completos) da própria barbearia
-- ------------------------------------------------------------------
-- A policy clientes_select_propria limita o barbeiro a clientes com quem já
-- tem agendamento — o recém-criado não apareceria. Esta RPC (SECURITY
-- DEFINER, sem ampliar policies/RLS) devolve os clientes da PRÓPRIA
-- barbearia do profissional autenticado, com a MESMA visão do admin.
CREATE OR REPLACE FUNCTION public.listar_clientes_da_barbearia()
RETURNS TABLE (
  id           bigint,
  barbearia_id bigint,
  nome         text,
  telefone     text,
  email        text,
  observacoes  text,
  ativo        boolean,
  created_at   timestamp with time zone,
  updated_at   timestamp with time zone
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF public.profissional_autenticado_id() IS NULL THEN
    RAISE EXCEPTION 'somente um profissional ativo da barbearia pode listar clientes';
  END IF;

  RETURN QUERY
    SELECT c.id, c.barbearia_id, c.nome, c.telefone, c.email, c.observacoes,
           c.ativo, c.created_at, c.updated_at
      FROM public.clientes c
     WHERE c.barbearia_id = public.barbearia_profissional_autenticado()
     ORDER BY c.nome;
END;
$$;

-- ------------------------------------------------------------------
-- 9.4.F EDIÇÃO de clientes pelo barbeiro — RPC public.editar_cliente
--      (migration 007)
-- ------------------------------------------------------------------
-- Regra aprovada:
--   * ADMIN   : cria, edita e ativa/desativa clientes (INALTERADO — segue
--     pelo UPDATE direto via policy clientes_update_admin).
--   * BARBEIRO: cria (RPC 9.4.D) e EDITA APENAS nome, telefone, e-mail e
--     observações de clientes da PRÓPRIA barbearia; NÃO ativa/desativa.
--
-- A RPC:
--   * NÃO aceita p_ativo nem p_barbearia_id — a barbearia é SEMPRE
--     derivada do auth.uid() (profissionais.auth_user_id), nunca do request;
--   * aceita profissional ativo (admin OU barbeiro) da própria barbearia;
--     sem vínculo / inativo / excluído (M005) => rejeitado;
--   * UPDATE SOMENTE nas 4 colunas permitidas; ativo e created_at jamais
--     são tocados; updated_at é mantido pelo trg_clientes_updated_at;
--   * WHERE com a barbearia derivada rejeita cliente de outra barbearia;
--   * validação server-side mínima (nome/telefone obrigatórios, e-mail no
--     formato), réplica das validações do painel.
-- Segurança: SECURITY DEFINER + SET search_path='' + REVOKE de
-- PUBLIC/anon + GRANT EXECUTE só a authenticated. NENHUMA policy de UPDATE
-- para barbeiro e NENHUM grant de tabela novo (só o admin tem policy de
-- escrita) — a RPC é a ÚNICA via de edição do barbeiro.
CREATE OR REPLACE FUNCTION public.editar_cliente(
  p_cliente_id bigint,
  p_nome text,
  p_telefone text,
  p_email text DEFAULT NULL,
  p_observacoes text DEFAULT NULL
)
RETURNS public.clientes
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_barbearia bigint;
  v_cliente   public.clientes;
BEGIN
  v_barbearia := public.barbearia_profissional_autenticado();

  IF v_barbearia IS NULL THEN
    RAISE EXCEPTION 'somente um profissional ativo da barbearia pode editar clientes';
  END IF;

  IF NOT public.usuario_e_admin_da_barbearia(v_barbearia)
     AND NOT public.usuario_e_barbeiro_autenticado() THEN
    RAISE EXCEPTION 'somente um profissional ativo da barbearia pode editar clientes';
  END IF;

  -- Normalizar telefone (somente dígitos) antes de gravar (M011).
  p_telefone := public.normalizar_telefone(p_telefone);

  IF trim(coalesce(p_nome, '')) = '' THEN
    RAISE EXCEPTION 'nome do cliente é obrigatório';
  END IF;
  IF p_telefone IS NULL OR p_telefone = '' THEN
    RAISE EXCEPTION 'telefone do cliente é obrigatório';
  END IF;
  IF p_email IS NOT NULL AND p_email !~* '^[^@\s]+@[^@\s]+$' THEN
    RAISE EXCEPTION 'e-mail inválido';
  END IF;

  UPDATE public.clientes
     SET nome        = trim(p_nome),
         telefone    = p_telefone,
         email       = nullif(trim(coalesce(p_email, '')), ''),
         observacoes = nullif(trim(coalesce(p_observacoes, '')), '')
   WHERE id = p_cliente_id
     AND barbearia_id = v_barbearia
  RETURNING * INTO v_cliente;

  IF v_cliente.id IS NULL THEN
    RAISE EXCEPTION 'cliente não encontrado ou de outra barbearia';
  END IF;

  RETURN v_cliente;
END;
$$;

-- ------------------------------------------------------------------
-- 9.4.G NORMALIZAÇÃO DE TELEFONE em clientes (M011)
-- ------------------------------------------------------------------
-- Garante, NO BANCO, que todo telefone armazenado em public.clientes
-- fique em formato canônico (somente dígitos). Cobre todas as vias de
-- escrita:
--   * RPC público criar-agendamento (grava canônico, já normaliza);
--   * RPC criar_cliente / editar_cliente (M006/M007, normalizam também);
--   * UPDATE direto do admin via policy clientes_update_admin.
-- O trigger é a ÚLTIMA barreira de consistência (BEFORE INSERT/UPDATE).
-- NÃO cria UNIQUE: dados legados podem conter duplicatas e telefone pode
-- ser compartilhado (família).
CREATE OR REPLACE FUNCTION public.normalizar_telefone(p_telefone text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $$
DECLARE
  v_d text;
BEGIN
  IF p_telefone IS NULL THEN
    RETURN NULL;
  END IF;

  v_d := regexp_replace(p_telefone, '[^0-9]', '', 'g');

  IF length(v_d) > 11 AND v_d LIKE '55%' THEN
    v_d := right(v_d, length(v_d) - 2);
  END IF;

  IF length(v_d) > 11 THEN
    v_d := right(v_d, 11);
  END IF;

  RETURN v_d;
END;
$$;

CREATE OR REPLACE FUNCTION public.normalizar_telefone_clientes()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  NEW.telefone := public.normalizar_telefone(NEW.telefone);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_clientes_normalizar_telefone ON public.clientes;
CREATE TRIGGER trg_clientes_normalizar_telefone
    BEFORE INSERT OR UPDATE OF telefone
    ON public.clientes
    FOR EACH ROW EXECUTE FUNCTION public.normalizar_telefone_clientes();

REVOKE ALL ON FUNCTION public.normalizar_telefone(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.normalizar_telefone_clientes() FROM PUBLIC, anon;

-- ------------------------------------------------------------------
-- 9.5 AUTORIDADE DE BLOQUEIOS E HORÁRIO (server-side, elimina corrida)
-- ------------------------------------------------------------------
-- Garante, NO BANCO, que um agendamento nunca seja confirmado em intervalo
-- que viole:
--   1. bloqueio geral da barbearia (barbeiro_id IS NULL);
--   2. bloqueio específico do barbeiro;
--   3. horário de funcionamento (com o fuso local da barbearia).
--
-- A validação roda no trigger BEFORE INSERT/UPDATE do próprio agendamento,
-- portanto cobre TODAS as vias de escrita (Edge Function pública, RPC
-- admin_criar_agendamento, admin_atualizar_agendamento e qualquer futuro
-- INSERT/UPDATE) — não depende de validação do frontend.
--
-- Para eliminar a corrida "verificar → inserir", usa-se um advisory lock
-- xact por barbearia, também adquirido por um trigger em bloqueios_agenda.
-- Assim, criar/editar um bloqueio é mutuamente exclusivo com a validação de
-- um agendamento concorrente: ou o bloqueio commita antes (e o agendamento é
-- barrado) ou o agendamento commita antes (e o bloqueio vale dali em diante).
-- Linhas com status = 'cancelado' são ignoradas (não ocupam horário — mesmo
-- critério de ux_agendamentos_sem_conflito). RLS/grants NÃO são alterados.
--
-- (Migração correspondente para banco já existente:
--  database/migrations/002_agendamento_bloqueio_validation.sql)

-- Função de validação (SECURITY DEFINER, roda como dono / sem search_path).
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
    IF NEW.status = 'cancelado' THEN
        RETURN NEW;
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended('barbearia_agenda:' || NEW.barbearia_id::text, 0)
    );

    SELECT b.timezone INTO v_tz
      FROM public.barbearias b
     WHERE b.id = NEW.barbearia_id;
    IF v_tz IS NULL OR v_tz = '' THEN
        v_tz := 'America/Sao_Paulo';
    END IF;

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

DROP TRIGGER IF EXISTS trg_agendamentos_validar_bloqueios ON public.agendamentos;
CREATE TRIGGER trg_agendamentos_validar_bloqueios
    BEFORE INSERT OR UPDATE OF
        barbearia_id, barbeiro_id, data_hora_inicio, data_hora_fim, status
    ON public.agendamentos
    FOR EACH ROW EXECUTE FUNCTION public.validar_agendamento_bloqueios();

-- =====================================================================
-- 9.6 AUTORIDADE DE DURAÇÃO — data_hora_fim DERIVADO do serviço
-- =====================================================================
-- Garante, NO BANCO, que a duração de um agendamento seja SEMPRE:
--
--     data_hora_fim = data_hora_inicio + servicos.duracao_minutos
--
-- O trigger é BEFORE e dispara em:
--   * INSERT;
--   * UPDATE OF servico_id, data_hora_inicio, data_hora_fim
--     (incluir data_hora_fim no UPDATE OF é OBRIGATÓRIO para impedir que
--      alguém altere SOMENTE o fim e escape da derivação).
--
-- Por ser alfabeticamente anterior a trg_agendamentos_validar_bloqueios
-- (derivar_... < validar_...), roda ANTES dele, garantindo que a validação
-- de bloqueios/horário de funcionamento sempre enxergue o FIM DERIVADO.
--
-- Cobre TODAS as vias de escrita em agendamentos:
--   * Edge Function pública (criar-agendamento, via service-role);
--   * RPC administrativa admin_criar_agendamento / admin_atualizar_agendamento;
--   * qualquer INSERT/UPDATE futuro.
--
-- NÃO altera RLS, nem grants e NÃO abre nenhuma permissão nova.
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

DROP TRIGGER IF EXISTS trg_agendamentos_derivar_duracao ON public.agendamentos;
CREATE TRIGGER trg_agendamentos_derivar_duracao
    BEFORE INSERT OR UPDATE OF
        servico_id, data_hora_inicio, data_hora_fim
    ON public.agendamentos
    FOR EACH ROW EXECUTE FUNCTION public.derivar_duracao_agendamento();

-- Função de serialização de bloqueios (mesmo advisory lock por barbearia).
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

REVOKE ALL ON FUNCTION public.validar_agendamento_bloqueios() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.serializar_bloqueio_barbearia() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.derivar_duracao_agendamento() FROM PUBLIC, anon;

-- Grants de execução: somente authenticated (sem acesso para anon/public).
REVOKE ALL ON FUNCTION public.transicao_status_valida(text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_atualizar_agendamento(bigint, bigint, bigint, bigint, timestamp with time zone, timestamp with time zone, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_criar_agendamento(bigint, bigint, bigint, bigint, timestamp with time zone, timestamp with time zone, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_excluir_agendamento(bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_excluir_profissional(bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.barbeiro_atualizar_status(bigint, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.barbeiro_criar_agendamento(bigint, bigint, timestamp with time zone, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.listar_clientes_para_agendamento() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.transicao_status_valida(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_atualizar_agendamento(bigint, bigint, bigint, bigint, timestamp with time zone, timestamp with time zone, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_criar_agendamento(bigint, bigint, bigint, bigint, timestamp with time zone, timestamp with time zone, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_excluir_agendamento(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_excluir_profissional(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.barbeiro_atualizar_status(bigint, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.barbeiro_criar_agendamento(bigint, bigint, timestamp with time zone, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.listar_clientes_para_agendamento() TO authenticated;
REVOKE ALL ON FUNCTION public.criar_cliente(text, text, text, text, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.listar_clientes_da_barbearia() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.editar_cliente(bigint, text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.criar_cliente(text, text, text, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.listar_clientes_da_barbearia() TO authenticated;
GRANT EXECUTE ON FUNCTION public.editar_cliente(bigint, text, text, text, text) TO authenticated;

-- =====================================================================
-- 10. POLICIES — horarios_funcionamento e bloqueios_agenda
-- =====================================================================
CREATE POLICY "horarios_select_propria"
  ON public.horarios_funcionamento
  FOR SELECT TO authenticated
  USING (public.usuario_pertence_a_barbearia(barbearia_id));

CREATE POLICY "horarios_write_admin"
  ON public.horarios_funcionamento
  FOR ALL TO authenticated
  USING (public.usuario_e_admin_da_barbearia(barbearia_id))
  WITH CHECK (public.usuario_e_admin_da_barbearia(barbearia_id));

CREATE POLICY "bloqueios_select_propria"
  ON public.bloqueios_agenda
  FOR SELECT TO authenticated
  USING (public.usuario_pertence_a_barbearia(barbearia_id));

CREATE POLICY "bloqueios_write_admin"
  ON public.bloqueios_agenda
  FOR ALL TO authenticated
  USING (public.usuario_e_admin_da_barbearia(barbearia_id))
  WITH CHECK (public.usuario_e_admin_da_barbearia(barbearia_id));

-- =====================================================================
-- 11. GRANTS — PRIVILÉGIOS MÍNIMOS
-- =====================================================================
-- RLS e privilégios SQL são camadas DIFERENTES:
--   * RLS decide QUAIS LINHAS cada role enxerga;
--   * GRANT decide QUAIS COMANDOS/COLUNAS a role pode tentar.
--
-- PARA agendamentos (ponto crítico):
--   NENHUM GRANT de INSERT/UPDATE/DELETE (nem de tabela, nem de coluna)
--   é concedido a quaisquer roles. Sem privilégio de escrita, o PostgreSQL
--   recusa
--   qualquer INSERT/UPDATE/DELETE direto ("permission denied for table"),
--   inclusive de colunas. Assim o barbeiro NÃO tem como gravar
--   id/barbearia_id/cliente_id/barbeiro_id/servico_id/data_hora_*/
--   created_at/updated_at: ele nem consegue executar UPDATE algum.
--   A única via de escrita é RPC (seção 9), que internamente reescreve
--   somente as colunas permitidas (status/observacoes para o barbeiro) e
--   valida cargo/barbearia/transição.
--
-- As funções RPC rodam com security definer (dono), por isso conseguem
-- escrever sem depender de GRANT — mas o chamador, sem GRANT de TABELA,
-- jamais contorna a função diretamente.

GRANT USAGE ON SCHEMA public TO authenticated;

-- SEQUENCES: NENHUM privilégio de sequence para authenticated (F4). As
-- colunas id usam BIGINT GENERATED BY DEFAULT AS IDENTITY: o nextval é
-- invocado internamente pelo executor, sem exigir USAGE/SELECT na sequence.
-- Manter o GRANT anterior (USAGE,SELECT ON ALL SEQUENCES) expunha last_value
-- e permitia queimar IDs — revogado na migration 010.

-- Leitura: todas as tabelas de negócio (linhas limitadas por RLS).
GRANT SELECT ON public.barbearias, public.profissionais, public.servicos,
  public.clientes, public.agendamentos,
  public.horarios_funcionamento, public.bloqueios_agenda TO authenticated;

-- Escrita nas demais tabelas (fora de agendamentos e fora da CRIAÇÃO de
-- clientes):
--   * profissionais/servicos: admin usa INSERT/UPDATE (linhas restritas por
--     RLS via políticas explícitas profissionais_*_admin / servicos_*_admin).
--     SEM DELETE: a exclusão é SOMENTE via RPC admin_excluir_profissional
--     (soft delete preserva o histórico).
--   * clientes: SEM INSERT direto (a criação — admin OU barbeiro — passa
--     SOMENTE pela RPC public.criar_cliente). UPDATE apenas para o admin via
--     policy clientes_update_admin; SEM DELETE (não existe exclusão física,
--     cliente é desativado via UPDATE ativo = false).
--   * barbearias: admin edita a própria (UPDATE); ninguém cria/exclui
--     barbearia pela API.
--   * agendamentos: NÃO ENTRA AQUI (fica sem INSERT/UPDATE/DELETE para
--     não dar ao barbeiro um caminho de escrita de qualquer coluna).
--   * horarios_funcionamento e bloqueios_agenda: mantêm INSERT/UPDATE/DELETE
--     (a UI os gerencia diretamente — ex.: excluir um bloqueio da agenda).
GRANT INSERT, UPDATE ON public.profissionais, public.servicos TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.horarios_funcionamento, public.bloqueios_agenda TO authenticated;
GRANT UPDATE ON public.clientes TO authenticated;
GRANT UPDATE ON public.barbearias TO authenticated;

-- =====================================================================
-- 12. FLUXO PÚBLICO (ADIADO — via Edge Function numa etapa futura)
-- =====================================================================
-- MOTIVO DA DECISÃO:
--   * agendamentos.cliente_id é NOT NULL com FK composta para clientes:
--     o fluxo público precisa LOCALIZAR ou CRIAR o cliente ANTES de
--     inserir o agendamento.
--   * uma policy anon de INSERT em clientes abriria a base para poluição.
--   * portanto NÃO há, nesta etapa, policy/GRANT para anon em clientes
--     nem em agendamentos.
--
-- DECISÃO DE ARQUITETURA:
--   O agendamento público será criado por uma Supabase Edge Function com
--   role service_role (ignora RLS). Ela será responsável por:
--     1. validar os dados de entrada (forma/conteúdo);
--     2. LOCALIZAR o cliente por telefone/e-mail OU CRIAR o registro em
--        public.clientes (mesma barbearia, ativo);
--     3. validar que a barbearia existe e está ativa;
--     4. validar que o serviço pertence à MESMA barbearia e está ativo;
--     5. validar que o profissional pertence à mesma barbearia e está ativo;
--     6. validar o horário: futuro, dentro do horário de funcionamento e
--        sem conflito com bloqueios_agenda;
--     7. CRIAR o agendamento com status 'pendente' — o conflito de
--        intervalo é garantido pela constraint ux_agendamentos_sem_conflito,
--        não pela aplicação.
--
--   O anon (site público) NÃO possuirá SELECT/INSERT/UPDATE/DELETE direto;
--   a comunicação é exclusivamente via HTTP à Edge Function.

-- =====================================================================
-- 13. MATRIZ DE TESTES (comentada — executar no SQL Editor depois)
-- =====================================================================
-- Pré-requisitos:
--   * 2 barbearias (A e B) com dados;
--   * profissionais preenchidos com auth_user_id do Supabase Auth;
--   * 1 admin (barbearia A), 1 barbeiro (barbearia A), 1 usuário (B).
--
-- Simulação de papel no SQL Editor:
--   set role authenticated;
--   select set_config('request.jwt.claims',
--     '{"sub":"<auth_user_id>","role":"authenticated",
--       "iat":1710000000,"exp":1710003600}', true);  -- trocar sub conforme teste
--
-- ATENÇÃO: ajustar ids conforme dados reais criados manualmente.
--
-- ------------------------------------------------------------------
-- A) ANON — nenhum acesso nesta etapa
-- ------------------------------------------------------------------
-- select * from public.agendamentos;                                  -- negado
-- insert into public.agendamentos (...) values (...);                 -- negado
-- select public.admin_criar_agendamento(...);                         -- sem EXECUTE

-- ------------------------------------------------------------------
-- B) ADMIN — barbearia A
-- ------------------------------------------------------------------
-- select * from public.agendamentos;                    -- só barbearia A
-- select public.admin_atualizar_agendamento(id, b, s, c, ini, fim,
--        'confirmado', 'obs');                                     -- OK
-- select public.admin_atualizar_agendamento(id, ..., 'pendente', ...)
--   quando atual = 'confirmado';                       -- erro (transição)
-- select public.admin_criar_agendamento(...);                      -- OK
-- select public.admin_excluir_agendamento(id);                     -- OK
-- UPDATE direto:  update public.agendamentos set ...               -- negado
--   (não há GRANT de UPDATE para a tabela + sem policy de UPDATE)
-- leitura/escrita de agendamento da barbearia B -> 0 linhas/negado

-- ------------------------------------------------------------------
-- C) BARBEIRO — barbearia A
-- ------------------------------------------------------------------
-- select * from public.agendamentos;  -> somente os PRÓPRIOS
-- select public.barbeiro_atualizar_status(id, 'confirmado');
--   -> OK (próprio, pendente->confirmado)
-- select public.barbeiro_atualizar_status(id, 'concluido');
--   -> OK (próprio, confirmado->concluido)
-- select public.barbeiro_atualizar_status(id, 'pendente');
--   -> erro (transição inválida: concluido->pendente)
-- select public.barbeiro_atualizar_status(id, 'concluido') de um
--   agendamento de OUTRO barbeiro -> erro (nenhuma linha atende)
-- UPDATE direto:  update public.agendamentos
--        set data_hora_inicio = ... ;                 -- negado
--   atribuindo cliente_id/barbeiro_id/servico_id/data_hora_*   -> negado
--   (sem GRANT de UPDATE de tabela: "permission denied for table
--    agendamentos"; o PostgreSQL recusa a escrita de qualquer coluna)
-- select public.admin_atualizar_agendamento(...) -> erro se o barbeiro
--   tentar (função checa cargo admin; RAISE EXCEPTION)
-- NÃO existe função que permita ao barbeiro escrever id/cliente/
--   barbeiro/servico/horários.

-- ------------------------------------------------------------------
-- D) USUÁRIO BARBEARIA B
-- ------------------------------------------------------------------
-- select * de qualquer tabela -> somente dados da barbearia B
-- select * from agendamentos -> somente os próprios
-- tenta alterar dados da barbearia A -> 0 linhas / negado

-- FIM: reset role;
-- =====================================================================
