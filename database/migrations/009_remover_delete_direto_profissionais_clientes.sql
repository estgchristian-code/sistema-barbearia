-- ===========================================================================
-- MIGRATION 009 — F2: remover hard DELETE direto de profissionais e clientes
--
-- Contexto (achado de auditoria F2, reproduzido em produção):
--   Um Admin conseguia executar DELETE direto em public.profissionais e
--   public.clientes contornando o soft delete (RPC admin_excluir_profissional)
--   e a desativação via ativo=false, porque:
--     * GRANT ... DELETE ON public.profissionais, public.clientes TO
--       authenticated (rls.sql, seção GRANTS);
--     * policies FOR ALL ("profissionais_write_admin", "clientes_write_admin")
--       com USING/WITH CHECK de admin da própria barbearia.
--   Resultado observado:
--     * DELETE em registro SEM histórico (agendamentos/bloqueios) EXECUTAVA e
--       removia a linha fisicamente — histórico perdido;
--     * DELETE em registro JÁ soft-deletado (deleted_at) também EXECUTAVA —
--       soft delete contornável;
--     * DELETE de profissional com auth_user_id deixava o usuário do Supabase
--       Auth ÓRFÃO (auth.users permanece; UNIQUE uq_profissionais_auth_user
--       impede reutilização).
--   (DELETE em registro COM histórico era bloqueado pela FK RESTRICT.)
--
-- O que esta migration faz:
--   * REVOGA o privilégio DELETE de profissionais, servicos e clientes e
--     reafirma o privilégio mínimo. DELETE continua somente onde é legítimo
--     (horarios_funcionamento e bloqueios_agenda, usados diretamente pela UI);
--   * SUBSTITUI as policies FOR ALL por policies explícitas:
--       profissionais: INSERT + UPDATE (sem DELETE);
--       servicos:      INSERT + UPDATE (sem DELETE);
--       clientes:      UPDATE (criação já é SOMENTE via RPC criar_cliente);
--   * NÃO cria policy de DELETE: sem política, o RLS nega por padrão — mesmo
--     que alguém regrant DELETE no futuro, a falha bloqueia na policy;
--   * Manutenção da integridade: exclusão de profissional continua SOMENTE
--     pela RPC admin_excluir_profissional (soft delete); cliente continua via
--     ativo = false. Histórico de agendamentos/bloqueios é preservado.
--   * NÃO altera RPCs existentes (SECURITY DEFINER/search_path intactos),
--     NÃO altera triggers A1/M1, NÃO altera 005/006/007/008, NÃO altera o
--     frontend.
--
-- Idempotente e seguro para reexecução (REVOKE/GRANT e DROP POLICY IF
-- EXISTS são idempotentes). Portal de fix imediato em produção: basta aplicar
-- apenas este arquivo via SQL Editor / migration runner.
-- ===========================================================================

-- -----------------------------------------------------------------------
-- 1) Privilégios mínimos (somente authenticated; SEM DELETE em pro/cli/srv)
--    SELECT permanece concedido (rls.sql) e não é tocado aqui.
-- -----------------------------------------------------------------------
REVOKE INSERT, UPDATE, DELETE ON public.profissionais, public.servicos,
  public.horarios_funcionamento, public.bloqueios_agenda FROM authenticated;
REVOKE UPDATE, DELETE ON public.clientes FROM authenticated;

GRANT INSERT, UPDATE ON public.profissionais, public.servicos TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.horarios_funcionamento, public.bloqueios_agenda TO authenticated;
GRANT UPDATE ON public.clientes TO authenticated;

-- -----------------------------------------------------------------------
-- 2) Policies explícitas no lugar das FOR ALL (SEM policy de DELETE)
-- -----------------------------------------------------------------------

-- profissionais -----------------------------------------------------------
DROP POLICY IF EXISTS "profissionais_write_admin"    ON public.profissionais;
DROP POLICY IF EXISTS "profissionais_insert_admin"   ON public.profissionais;
DROP POLICY IF EXISTS "profissionais_update_admin"   ON public.profissionais;

CREATE POLICY "profissionais_insert_admin"
  ON public.profissionais
  FOR INSERT TO authenticated
  WITH CHECK (public.usuario_e_admin_da_barbearia(barbearia_id));

CREATE POLICY "profissionais_update_admin"
  ON public.profissionais
  FOR UPDATE TO authenticated
  USING (public.usuario_e_admin_da_barbearia(barbearia_id))
  WITH CHECK (public.usuario_e_admin_da_barbearia(barbearia_id));

-- servicos -----------------------------------------------------------------
DROP POLICY IF EXISTS "servicos_write_admin"         ON public.servicos;
DROP POLICY IF EXISTS "servicos_insert_admin"        ON public.servicos;
DROP POLICY IF EXISTS "servicos_update_admin"        ON public.servicos;

CREATE POLICY "servicos_insert_admin"
  ON public.servicos
  FOR INSERT TO authenticated
  WITH CHECK (public.usuario_e_admin_da_barbearia(barbearia_id));

CREATE POLICY "servicos_update_admin"
  ON public.servicos
  FOR UPDATE TO authenticated
  USING (public.usuario_e_admin_da_barbearia(barbearia_id))
  WITH CHECK (public.usuario_e_admin_da_barbearia(barbearia_id));

-- clientes ------------------------------------------------------------------
DROP POLICY IF EXISTS "clientes_write_admin"         ON public.clientes;
DROP POLICY IF EXISTS "clientes_update_admin"        ON public.clientes;

CREATE POLICY "clientes_update_admin"
  ON public.clientes
  FOR UPDATE TO authenticated
  USING (public.usuario_e_admin_da_barbearia(barbearia_id))
  WITH CHECK (public.usuario_e_admin_da_barbearia(barbearia_id));