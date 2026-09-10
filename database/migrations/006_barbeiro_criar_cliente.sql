-- ===========================================================================
-- MIGRATION 006 — Barbeiro pode CADASTRAR clientes (servidor confiável)
--
-- Problema resolvido:
--   Antes, só o admin criava clientes (policy clientes_write_admin exige
--   usuario_e_admin_da_barbearia). O barbeiro podia listar/uso no agendamento,
--   mas SEM cadastrar.
--
-- Regra de negócio aprovada:
--   * ADMIN  : cria, edita e ativa/desativa clientes (inalterado).
--   * BARBEIRO: CADASTRA novos clientes e os usa em agendamentos; NÃO edita,
--     NÃO desativa e NÃO possui outras permissões administrativas sobre
--     clientes.
--
-- Solução adotada (segura, mantém Admin/RLS):
--   1) Nova RPC public.criar_cliente(...):
--        * NÃO aceita p_barbeiro_id nem p_barbearia_id — a barbearia é
--          SEMPRE DERIVADA do token JWT (auth.uid()) no banco, nunca do
--          request;
--        * aceita admin OU barbeiro ativo da própria barbearia;
--        * para BARBEIRO força ativo = true (sem poder administrativo de
--          criar cliente inativo); admin mantém o controle de ativo;
--        * validação server-side mínima: nome/telefone obrigatórios e
--          e-mail no formato (réplica do chk_clientes_email);
--        * só insere — nunca UPDATE/DELETE (barbeiro não pode editar nem
--          desativar).
--   2) Nova RPC de LEITURA public.listar_clientes_da_barbearia():
--        * devolve os clientes (campos completos) da PRÓPRIA barbearia do
--          profissional autenticado (admin e barbeiro com a mesma visão);
--        * evita ampliar a policy clientes_select_propria — o barbeiro deixa
--          de depender de "já ter agendamento" para ver a lista (necessário
--          para o cliente recém-criado aparecer na página).
--   3) REVOKE INSERT ON public.clientes FROM authenticated:
--        * remove a via de INSERT DIRETO na tabela clientes. A CRIAÇÃO passa
--          a existir SOMENTE pela RPC acima (admin também usa a RPC). UPDATE
--          e DELETE continuam concedidos (admin usa via clientes_write_admin).
--   4) Grants mínimos: REVOKE de PUBLIC/anon + GRANT EXECUTE apenas a
--      authenticated. NENHUMA policy de escrita nova para barbeiro.
--
-- Inalterado:
--   * RLS permanece habilitado; mecanismo de enforcement é a função
--     SECURITY DEFINER (search_path = '') + subsistema de grants/policies.
--   * agendamentos e o fluxo público (Edge Function que localiza/cria
--     cliente com service_role) não são afetados.
--   * os helper RLS exigem profissional ATIVO e NÃO excluído (M005).
--
-- Idempotente e seguro para reexecução.
-- ===========================================================================

-- -----------------------------------------------------------------------
-- 1) RPC — criar cliente (admin E barbeiro ativos da própria barbearia)
-- -----------------------------------------------------------------------
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
  -- Barbearia SEMPRE derivada do profissional autenticado (auth.uid()).
  -- NULL quando não há profissional ativo/não excluído (M005) vinculado.
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

  -- Validação server-side mínima (réplica das regras do painel/da tabela).
  IF trim(coalesce(p_nome, '')) = '' THEN
    RAISE EXCEPTION 'nome do cliente é obrigatório';
  END IF;
  IF trim(coalesce(p_telefone, '')) = '' THEN
    RAISE EXCEPTION 'telefone do cliente é obrigatório';
  END IF;
  IF p_email IS NOT NULL AND p_email !~* '^[^@\s]+@[^@\s]+$' THEN
    RAISE EXCEPTION 'e-mail inválido';
  END IF;

  INSERT INTO public.clientes (barbearia_id, nome, telefone, email, observacoes, ativo)
  VALUES (
    v_barbearia,
    trim(p_nome),
    trim(p_telefone),
    nullif(trim(coalesce(p_email, '')), ''),
    nullif(trim(coalesce(p_observacoes, '')), ''),
    p_ativo
  )
  RETURNING * INTO v_cliente;

  RETURN v_cliente;
END;
$$;

-- -----------------------------------------------------------------------
-- 2) RPC de LEITURA — clientes (campos completos) da própria barbearia
-- -----------------------------------------------------------------------
-- A policy clientes_select_propria limita o barbeiro a clientes com quem já
-- tem agendamento — o recém-criado não apareceria. Esta RPC (SECURITY
-- DEFINER, sem ampliar policies/RLS) devolve os clientes da PRÓPRIA
-- barbearia do profissional autenticado, com a MESMA visão do admin.
-- Nenhuma coluna é exposta além das da própria tabela clientes.
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

-- -----------------------------------------------------------------------
-- 3) Privilégios mínimos (somente authenticated, sem acesso a PUBLIC/anon)
-- -----------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.criar_cliente(text, text, text, text, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.listar_clientes_da_barbearia() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.criar_cliente(text, text, text, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.listar_clientes_da_barbearia() TO authenticated;

-- -----------------------------------------------------------------------
-- 4) Sem INSERT direto em clientes: criação passa SOMENTE pela RPC acima.
--    UPDATE/DELETE continuam para o admin (policy clientes_write_admin).
-- -----------------------------------------------------------------------
REVOKE INSERT ON public.clientes FROM authenticated;