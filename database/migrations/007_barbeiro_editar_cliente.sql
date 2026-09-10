-- ===========================================================================
-- MIGRATION 007 — Barbeiro pode EDITAAR clientes (servidor confiável)
--
-- Regra de negócio aprovada:
--   * ADMIN  : cria, edita e ativa/desativa clientes (INALTERADO).
--   * BARBEIRO: cria (M006) e EDITA APENAS nome, telefone, e-mail e
--     observações de clientes da própria barbearia; NÃO ativa/desativa
--     (campo ativo é exclusivo do admin).
--
-- Solução adotada (segura, mantém Admin/RLS):
--   1) Nova RPC public.editar_cliente(...):
--        * NÃO aceita p_ativo nem p_barbearia_id — a barbearia é SEMPRE
--          DERIVADA do token JWT (auth.uid()) no banco, nunca do request;
--        * aceita profissional ativo (admin OU barbeiro) da PRÓPRIA
--          barbearia (usuário sem vínculo, inativo ou excluído — M005 —
--          é rejeitado);
--        * UPDATE SOMENTE em nome, telefone, e-mail e observações;
--        * ativo e created_at JAMAIS são tocados; updated_at é atualizado
--          pelo trigger trg_clientes_updated_at (exists na schema base);
--        * rejeita cliente de outra barbearia ('cliente não encontrado ou
--          de outra barbearia') graças ao WHERE com a barbearia derivada;
--        * validação server-side mínima: nome/telefone obrigatórios e
--          e-mail no formato (réplica do chk_clientes_email).
--   2) Grants mínimos: REVOKE de PUBLIC/anon + GRANT EXECUTE apenas a
--      authenticated.
--
-- NÃO altera RLS e NÃO concede nada de novo:
--   * NENHUMA policy de UPDATE para barbeiro (clientes_write_admin continua
--     exclusiva do admin) — o barbeiro NÃO tem caminho direto na tabela;
--     a RPC editar_cliente é a ÚNICA via de edição dele;
--   * nenhum GRANT de tabela novo (UPDATE/DELETE continuam como na M006);
--   * RLS permanece habilitado; isolamento por barbearia é reforçado no
--     WHERE da RPC + derivado de auth.uid().
--
-- Idempotente e seguro para reexecução.
-- ===========================================================================

-- -----------------------------------------------------------------------
-- 1) RPC — editar cliente (admin E barbeiro ativos da própria barbearia)
-- -----------------------------------------------------------------------
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
  -- Barbearia SEMPRE derivada do profissional autenticado (auth.uid()).
  -- NULL quando não há profissional ativo/não excluído (M005) vinculado.
  v_barbearia := public.barbearia_profissional_autenticado();

  IF v_barbearia IS NULL THEN
    RAISE EXCEPTION 'somente um profissional ativo da barbearia pode editar clientes';
  END IF;

  -- Admin e barbeiro ativos podem editar os 4 campos; o campo ativo NÃO
  -- é aceito nem atualizado por esta função (exclusivo do admin via
  -- clientes_write_admin).
  IF NOT public.usuario_e_admin_da_barbearia(v_barbearia)
     AND NOT public.usuario_e_barbeiro_autenticado() THEN
    RAISE EXCEPTION 'somente um profissional ativo da barbearia pode editar clientes';
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

  -- Atualiza SOMENTE os 4 campos permitidos. ativo e created_at permanecem
  -- intactos; updated_at é mantido pelo trigger trg_clientes_updated_at.
  -- O WHERE com a barbearia derivada impede editar cliente de outra
  -- barbearia (UPDATE não afeta linha alguma e a RPC rejeita).
  UPDATE public.clientes
     SET nome        = trim(p_nome),
         telefone    = trim(p_telefone),
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

-- -----------------------------------------------------------------------
-- 2) Privilégios mínimos (somente authenticated, sem acesso a PUBLIC/anon)
-- -----------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.editar_cliente(bigint, text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.editar_cliente(bigint, text, text, text, text) TO authenticated;