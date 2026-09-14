-- =====================================================================
-- MIGRATION 011 — NORMALIZAÇÃO DE TELEFONE EM CLIENTES
-- =====================================================================
-- Objetivo: garantir que todo telefone armazenado em public.clientes
-- esteja em formato canônico (somente dígitos).
--
-- Abordagem (defesa em profundidade):
--   1) Trigger BEFORE INSERT OR UPDATE normaliza o telefone na tabela.
--   2) RPCs criar_cliente e editar_cliente normalizam antes de gravar.
--   3) Frontend aplica normalizarTelefone antes de enviar.
--
-- NÃO cria UNIQUE — dados existentes podem conter duplicatas legadas,
-- e telefone pode ser compartilhado (família).
-- NÃO deduplica, não mescla, não exclui clientes existentes.
-- =====================================================================

-- ------------------------------------------------------------------
-- 1. FUNÇÃO HELPER — normalizar telefone (somente dígitos)
-- ------------------------------------------------------------------
-- Réplica EXATA da normalização do fluxo público (criar-agendamento,
-- função normalizarTelefone): remove todo não-dígito, descarta o código
-- do país "55" e limita a 11 dígitos. Assim "(41) 99999-9999",
-- "+55 41 99999-9999" e "41999999999" caem no MESMO canônico — sem
-- duplicar clientes entre o painel e o fluxo público.
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

-- ------------------------------------------------------------------
-- 2. TRIGGER FUNCTION — normalizar telefone antes de INSERT/UPDATE
-- ------------------------------------------------------------------
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

-- ------------------------------------------------------------------
-- 3. TRIGGER — BEFORE INSERT OR UPDATE OF telefone
-- ------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_clientes_normalizar_telefone ON public.clientes;
CREATE TRIGGER trg_clientes_normalizar_telefone
    BEFORE INSERT OR UPDATE OF telefone
    ON public.clientes
    FOR EACH ROW EXECUTE FUNCTION public.normalizar_telefone_clientes();

-- ------------------------------------------------------------------
-- 4. REVOKE — helper não deve ser chamada diretamente por anon/authenticated
-- ------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.normalizar_telefone(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.normalizar_telefone_clientes() FROM PUBLIC, anon;

-- ------------------------------------------------------------------
-- 5. RPC criar_cliente — normalizar telefone antes de gravar
-- ------------------------------------------------------------------
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

  -- Normalizar telefone (somente dígitos) antes da validação.
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
-- 6. RPC editar_cliente — normalizar telefone antes de gravar
-- ------------------------------------------------------------------
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

  -- Normalizar telefone (somente dígitos) antes da validação.
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
