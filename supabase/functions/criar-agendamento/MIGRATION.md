# Migration necessária — Identificador público da barbearia (`slug`)

A Edge Function `criar-agendamento` foi ajustada para receber o **slug** público da
barbearia como identificador (em vez do `id` interno sequencial). A busca por esse
slug exige que a tabela `public.barbearias` tenha uma coluna `slug` única.

Esta alteração **ainda não foi aplicada ao banco**. Nenhum SQL executado nesta etapa.
Executar a migration abaixo **antes** de fazer o deploy da Edge Function; caso
contrário, a função responderá `404 "Barbearia não encontrada."` ao procurar o slug.

> Observação: este arquivo descreve a alteração. A execução deve ser feita no
> SQL Editor do Supabase pelo responsável, fora do fluxo desta etapa (que é
> somente de documentação/preparação).

## 1. Adicionar a coluna `slug` (única e indexada)

```sql
ALTER TABLE public.barbearias
    ADD COLUMN slug TEXT;

CREATE UNIQUE INDEX uq_barbearias_slug
    ON public.barbearias (slug)
    WHERE slug IS NOT NULL;
```

> Usa-se um índice único parcial (`WHERE slug IS NOT NULL`) para permitir que
> barbearias existentes fiquem temporariamente sem slug enquanto não forem
> populadas, sem violar a unicidade.

## 2. Preencher slugs das barbearias existentes (uma única vez)

Gera um slug a partir do nome (minúsculas, espaços viram hífen, remove acentos).
Rode repetidamente até nenhuma linha ser alterada:

```sql
UPDATE public.barbearias
SET slug = (
    WITH canon AS (
        SELECT id,
               lower(
                   regexp_replace(
                       translate(nome, 'àáâãäéèêëíìîïóòôõöúùûüçñ', 'aaaaaeeeeiiiiooooouuuucn'),
                       '[^a-z0-9]+', '-', 'g'
                   )
               ) AS base
        FROM public.barbearias
        WHERE slug IS NULL
    ),
    numerada AS (
        SELECT id, base, row_number() OVER (PARTITION BY base ORDER BY id) AS rn
        FROM canon
    )
    SELECT base || CASE WHEN rn = 1 THEN '' ELSE '-' || (rn - 1) END
    FROM numerada
    WHERE numerada.id = barbearias.id
)
WHERE slug IS NULL;
```

> A lógica de particionamento garante unicidade mesmo havendo nomes com o mesmo
> slug gerado (ex.: "Barbearia A" e "Barbearia a" → "barbearia-a" e "barbearia-a-1").

## 3. (Recomendado) Tornar `slug` obrigatório após populá-lo

Somente depois que todas as linhas tiverem slug:

```sql
ALTER TABLE public.barbearias
    ALTER COLUMN slug SET NOT NULL;
```

## 4. Índice/restrição adicional (opcional, se preferir nó único formal)

O índice único parcial do passo 1 já garante a unicidade. Se preferir uma
constraint nomeada explícita, substitua o passo 1 por:

```sql
ALTER TABLE public.barbearias
    ADD COLUMN slug TEXT,
    ADD CONSTRAINT uq_barbearias_slug UNIQUE (slug);
```

## Resumo do impacto

- A página pública passa a usar a URL/base do estabelecimento, ex.:
  `https://agenda.suaempresa.com.br/barbearia-estilo` → `slug = "barbearia-estilo"`.
- Nenhum `id` interno sequencial é exposto ao cliente no agendamento público.
- A Edge Function resolve `slug → barbearia_id` internamente e usa o id em todas
  as validações e no INSERT (nada muda no restante do schema nem no RLS).
