-- ===========================================================================
-- MIGRATION 004 — Barbeiro pode criar agendamento (somente para si mesmo)
--
-- Problema resolvido:
--   O barbeiro não tinha como criar agendamentos manualmente no painel
--   (apenas atualizar status/observações dos próprios registros).
--
-- Solução adotada (segura, mantém Admin/A1/M1):
--   1) Nova RPC public.barbeiro_criar_agendamento(...):
--        * NÃO aceita p_barbeiro_id nem p_barbearia_id — ambos são
--          DERIVADOS do token JWT (auth.uid()) no banco (nunca do request);
--        * exige cargo 'barbeiro' ativo; força status inicial 'pendente';
--        * valida cliente e serviço ATIVOS da própria barbearia;
--        * insere SEMPRE com barbeiro_id = o próprio profissional.
--      O admin continua usando admin_criar_agendamento (inalterada).
--   2) Nova RPC de LEITURA public.listar_clientes_para_agendamento():
--        * devolve SOMENTE id/nome/telefone/ativo dos clientes ATIVOS da
--          própria barbearia (necessários ao modal de criação), sem
--          ampliar policies/RLS existentes.
--   3) Grants mínimos: REVOKE de PUBLIC/anon + GRANT EXECUTE apenas a
--      authenticated. Continua SEM policy/GRANT de INSERT direto em
--      agendamentos (nenhuma via de escrita fora de RPC).
--
-- Proteções preservadas (nada é desligado):
--   * M1 — trg_agendamentos_derivar_duracao deriva data_hora_fim do
--     serviço;
--   * A1/M1 — trg_agendamentos_validar_bloqueios valida horário/bloqueio;
--   * ux_agendamentos_sem_conflito impede sobreposição do mesmo barbeiro;
--   * FKs compostas (id, barbearia_id) mantêm cliente/serviço/barbeiro da
--     mesma barbearia.
--
-- Idempotente e seguro para reexecução. NÃO altera RLS, NÃO altera
-- produção e NÃO abre permissão além de EXECUTE para authenticated.
-- ===========================================================================

-- -----------------------------------------------------------------------
-- 1) RPC — barbeiro criar agendamento para SI MESMO
-- -----------------------------------------------------------------------
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

-- -----------------------------------------------------------------------
-- 2) RPC de LEITURA — clientes da própria barbearia para o modal do barbeiro
-- -----------------------------------------------------------------------
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

-- -----------------------------------------------------------------------
-- 3) Privilégios mínimos (somente authenticated, sem acesso para PUBLIC/anon)
-- -----------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.barbeiro_criar_agendamento(bigint, bigint, timestamp with time zone, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.listar_clientes_para_agendamento() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.barbeiro_criar_agendamento(bigint, bigint, timestamp with time zone, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.listar_clientes_para_agendamento() TO authenticated;