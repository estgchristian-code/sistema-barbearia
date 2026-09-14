-- ===========================================================================
-- MIGRATION 013 — F7.1: governança da coluna profissionais.cargo
--
-- Contexto (achados de auditoria F7, reproduzidos em teste local):
--   - A policy profissionais_update_admin usa
--       USING/WITH CHECK (usuario_e_admin_da_barbearia(barbearia_id))
--     sem restrição por coluna: um admin da própria barbearia conseguia,
--     via UPDATE direto (DevTools/API), alterar cargo de qualquer
--     profissional (inclusive de 'barbeiro' para 'admin') e auto-demover-se
--     ('admin' -> 'barbeiro'), deixando a barbearia potencialmente sem admin.
--   - O frontend NUNCA altera cargo (criarProfissional insere cargo='barbeiro';
--     atualizarProfissional/alterarAtivoProfissional tocam só nome/telefone/
--     ativo). Nenhuma RPC/Edge Function legítima muda cargo em UPDATE.
--
-- O que esta migration faz:
--   * cria a função public.trf_profissionais_proteger_cargo() — idempotente
--     (CREATE OR REPLACE). Regras:
--       1) UPDATE que não muda cargo -> fluxo normal (nome/telefone/ativo/
--          auth_user_id/deleted_at) continua igual;
--       2) mudança de cargo por profissional autenticado da própria barbearia
--          (admin ou barbeiro) -> RAISE EXCEPTION 'alteração de cargo é uma
--          operação restrita';
--       3) defesa em profundidade p/ canais privilegiados (service_role/
--          superuser, auth.uid()=null): rebaixar 'admin'->'barbeiro' do ÚNICO
--          admin ativo da barbearia -> RAISE EXCEPTION.
--   * cria o trigger BEFORE UPDATE OF cargo na tabela profissionais.
--     Obs.: 'BEFORE UPDATE OF cargo' só dispara quando cargo é candidata a
--     mudar; INSERT continua livre (novo profissional nasce 'barbeiro', ou
--     caso um seed/admin venha modificar).
--   * a função e o trigger também são replicados em database/rls.sql
--     (estado canônico das regras de negócio, reaplicável); schema.sql não
--     é alterado (mantém apenas triggers de updated_at, por convenção).
--   * NÃO altera RLS de outras tabelas, RPCs, triggers A1/M1, grants de
--     sequences (010) nem o frontend.
--
-- Idempotente: CREATE OR REPLACE + DROP TRIGGER IF EXISTS.
-- Portal de fix: aplicar apenas este arquivo via SQL Editor / runner.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Função de trigger (idempotente)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trf_profissionais_proteger_cargo()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF NEW.cargo IS NOT DISTINCT FROM OLD.cargo THEN
    RETURN NEW;
  END IF;

  IF public.usuario_pertence_a_barbearia(NEW.barbearia_id) THEN
    RAISE EXCEPTION 'alteração de cargo é uma operação restrita';
  END IF;

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

-- ---------------------------------------------------------------------------
-- 2. Trigger BEFORE UPDATE OF cargo (idempotente)
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_profissionais_proteger_cargo ON public.profissionais;

CREATE TRIGGER trg_profissionais_proteger_cargo
    BEFORE UPDATE OF cargo ON public.profissionais
    FOR EACH ROW EXECUTE FUNCTION public.trf_profissionais_proteger_cargo();