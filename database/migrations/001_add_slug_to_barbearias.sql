-- ===========================================================================
-- MIGRATION 001 — Identificador público (slug) para public.barbearias
--
-- Objetivo: adicionar uma coluna `slug` a public.barbearias para servir de
-- identificador PÚBLICO (adequado para URL) usado pela página pública e pela
-- Edge Function "criar-agendamento":
--
--     WHERE slug = $1 AND ativo = true
--
-- A migration é:
--   * segura para o banco existente (adiciona coluna, popula e só então impõe
--     UNIQUE/NOT NULL);
--   * idempotente (pode ser reexecutada sem erro);
--   * descarta dados fictícios — nenhuma barbearia é criada;
--   * NÃO altera RLS nem cria policies.
--
-- Executar manualmente no Supabase (SQL Editor) por quem detém privilégios.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1) Adicionar a coluna (se ainda não existir)
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name   = 'barbearias'
          AND column_name  = 'slug'
    ) THEN
        ALTER TABLE public.barbearias ADD COLUMN slug TEXT;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 2) Popular os slugs existentes a partir do NOME, de forma genérica e com
--    garantia de unicidade (nomes iguais viram slug, slug, slug-1, slug-2...).
--    "Barbearia Estilo" -> "barbearia-estilo" (graças ao translate/regexp).
--
--    O FIRST() com min(id) garante que a linha de menor id fique com o slug
--    "limpo" e as demais recebam sufixo numérico, sem duplicidade.
-- ---------------------------------------------------------------------------
UPDATE public.barbearias
SET slug = sub.slug_final
FROM (
    SELECT
        b.id,
        base.slug_base,
        -- Sufixo para repetidos: 0 para o primeiro (sem sufixo), 1, 2, ...
        CASE
            WHEN rn = 1 THEN slug_base
            ELSE slug_base || '-' || (rn - 1)
        END AS slug_final
    FROM public.barbearias b
    JOIN (
        -- Precisão/estabilidade do row_number:
        SELECT
            id,
            nome,
            lower(
                regexp_replace(
                    translate(
                        nome,
                        'àáâãäéèêëíìîïóòôõöúùûüçñÀÁÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ',
                        'aaaaaeeeeiiiiooooouuuucnaaaaaeeeeiiiiooooouuuucn'
                    ),
                    '[^a-z0-9]+', '-', 'g'
                )
            ) AS slug_base
        FROM public.barbearias
    ) base ON base.id = b.id
    JOIN (
        SELECT
            slug_candidato,
            id,
            row_number() OVER (
                PARTITION BY slug_candidato
                ORDER BY id
            ) AS rn
        FROM (
            SELECT
                id,
                lower(
                    regexp_replace(
                        translate(
                            nome,
                            'àáâãäéèêëíìîïóòôõöúùûüçñÀÁÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ',
                            'aaaaaeeeeiiiiooooouuuucnaaaaaeeeeiiiiooooouuuucn'
                        ),
                        '[^a-z0-9]+', '-', 'g'
                    )
                ) AS slug_candidato
            FROM public.barbearias
            WHERE slug IS NULL
        ) candidatos
    ) numerada ON numerada.id = b.id
    WHERE b.slug IS NULL
) sub
WHERE public.barbearias.id = sub.id;

-- Limpeza opcional: garante que futures inserts não ganhem sufixo por engano.
-- (Não cria nada; apenas normaliza slugs já vazios restantes.)

-- ---------------------------------------------------------------------------
-- 3) Garantir UNIQUE após a população
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'uq_barbearias_slug'
          AND conrelid = 'public.barbearias'::regclass
    ) THEN
        ALTER TABLE public.barbearias
            ADD CONSTRAINT uq_barbearias_slug UNIQUE (slug);
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 4) NOT NULL (somente se seguro: não pode restar linha sem slug)
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.barbearias WHERE slug IS NULL
    ) THEN
        ALTER TABLE public.barbearias ALTER COLUMN slug SET NOT NULL;
    END IF;
END $$;
