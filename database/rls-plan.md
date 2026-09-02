# Plano de RLS / Policies — Sistema de Gestão de Barbearias

> **Status:** documentação apenas. Nenhum SQL deste arquivo deve ser
> executado antes da validação pela equipe.
>
> O `schema.sql` já habilitou **ROW LEVEL SECURITY** em todas as tabelas.
> Sem policies, os papéis `anon` e `authenticated` não têm acesso a nada —
> comportamento seguro por padrão.
>
> **Decisão de arquitetura:** o agendamento público (cliente que não possui
> conta) **não** será feito por policy `anon` no PostgreSQL. Será feito por
> um servidor (Supabase Edge Function com role `service_role`) em uma etapa
> futura. Portanto, nesta etapa o papel `anon` permanece totalmente bloqueado.
> Ver seção 3.3.

---

## 1. Princípios

1. **Nunca** usar `USING (true)` ou `WITH CHECK (true)`.
2. **Nunca** confiar em `barbearia_id` (ou qualquer filtro) enviado pelo
   frontend. O vínculo é sempre derivado do profissional autenticado:
   `profissionais.auth_user_id = auth.uid()` e `profissionais.barbearia_id`.
3. O mínimo de privilégio: cada policy concede somente o `FOR` (`select`,
   `insert`, `update`, `delete`, `all`) que o papel realmente utiliza, e os
   `GRANT`s concedem somente o necessário (`authenticated` apenas).
4. Agendamento cancelado continua existindo como histórico — regras de
   negócio limitam apenas *quais* transições de `status` são permitidas.
5. Papéis usados pelo Supabase: `anon` (cliente/site público) e
   `authenticated` (qualquer pessoa logada). A distinção admin/barbeiro é
   feita pelo campo `cargo` em `profissionais`. Nesta etapa, `anon` não
   possui **nenhum** privilégio nem policy.
6. RLS e `GRANT` são camadas complementares: RLS decide quais linhas podem
   ser acessadas; `GRANT` decide quais comandos/colunas a role pode tentar.
7. **Escrita em `agendamentos` passa APENAS por funções RPC** (SQL
   functions com `security definer`). Não há policy nem `GRANT` de
   INSERT/UPDATE/DELETE direto de `agendamentos` — o PostgreSQL recusa
   qualquer escrita direta, de qualquer coluna. Isso é o que de fato impede
   o barbeiro de alterar colunas além de `status`/`observacoes`.

---

## 2. Funções auxiliares (SECURITY DEFINER)

As policies precisam consultar `profissionais` para identificar o usuário
logado (`auth.uid()`). Se essa consulta rodasse dentro da própria policy,
ficaria sujeita ao RLS de `profissionais`, gerando recursão (ou resultado
vazio). Para quebrar o ciclo, as funções abaixo rodam como dono e retornam
**somente identificação** (id / barbearia / booleanos) — não expõem dados
de negócio. Medidas de segurança: `security definer`, `set search_path =
public`, `revoke execute ... from public, anon` e `grant execute` apenas
para `authenticated`, e leitura de `auth.uid()` do token JWT.

Cada função abaixo é usada por pelo menos uma policy (nenhuma foi criada
apenas por conveniência):

```sql
-- id do profissional ativo do usuário logado
create or replace function public.profissional_autenticado_id()
returns bigint
language sql stable security definer set search_path = public
as $$
  select p.id
  from public.profissionais p
  where p.auth_user_id = auth.uid()
    and p.ativo = true
  limit 1;
$$;

-- barbearia do usuário logado (nunca vem da requisição)
create or replace function public.barbearia_profissional_autenticado()
returns bigint
language sql stable security definer set search_path = public
as $$
  select p.barbearia_id
  from public.profissionais p
  where p.auth_user_id = auth.uid()
    and p.ativo = true
  limit 1;
$$;

-- o usuário logado pertence à barbearia informada?
create or replace function public.usuario_pertence_a_barbearia(p_barbearia bigint)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.profissionais p
    where p.auth_user_id = auth.uid()
      and p.barbearia_id = p_barbearia
      and p.ativo = true
  );
$$;

-- o usuário logado é admin da barbearia informada?
create or replace function public.usuario_e_admin_da_barbearia(p_barbearia bigint)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.profissionais p
    where p.auth_user_id = auth.uid()
      and p.cargo = 'admin'
      and p.barbearia_id = p_barbearia
      and p.ativo = true
  );
$$;

revoke all on function public.profissional_autenticado_id() from public, anon;
revoke all on function public.barbearia_profissional_autenticado() from public, anon;
revoke all on function public.usuario_pertence_a_barbearia(bigint) from public, anon;
revoke all on function public.usuario_e_admin_da_barbearia(bigint) from public, anon;
grant execute on function public.profissional_autenticado_id() to authenticated;
grant execute on function public.barbearia_profissional_autenticado() to authenticated;
grant execute on function public.usuario_pertence_a_barbearia(bigint) to authenticated;
grant execute on function public.usuario_e_admin_da_barbearia(bigint) to authenticated;
```

> Alternativa sem `SECURITY DEFINER` exigiria uma policy "ver a si mesmo"
> em `profissionais`; o padrão acima é mais simples e não recursivo.

---

## 3. Policies por papel

### 3.1 ADMIN — própria barbearia

Administrador mantêm a própria barbearia e gerencia profissionais,
serviços, clientes, agendamentos, horários e bloqueios — sempre limitado à
sua `barbearia_id` (derivada do usuário logado, nunca do frontend).

- **barbearias**: SELECT para qualquer profissional ativo da própria
  barbearia (`usuario_pertence_a_barbearia`); UPDATE somente admin.
- **profissionais / servicos / clientes / horarios_funcionamento /
  bloqueios_agenda**: SELECT para a própria barbearia; ALL somente admin.
- **agendamentos**: **somente leitura** via RLS (`agendamentos_select_propria`).
  Nenhuma escrita direta (INSERT/UPDATE/DELETE) é permitida por
  policy/GRANT. Toda escrita do admin é feita por RPC:
    - `admin_atualizar_agendamento(...)` — atualiza agendamento da própria
      barbearia (todas as colunas operáveis: cliente, barbeiro, serviço,
      horários, status, observações), sempre validando a transição de status;
    - `admin_criar_agendamento(...)` — cria agendamento `pendente`;
    - `admin_excluir_agendamento(...)` — exclui agendamento da própria
      barbearia.

O detalhamento completo está em `database/rls.sql` (arquivo único,
executável na ordem correta).

### 3.2 BARBEIRO — própria barbearia + próprios agendamentos

O barbeiro:

1. visualiza dados *necessários* da própria barbearia (barbearia, serviços,
   horários, bloqueios);
2. visualiza **apenas os próprios agendamentos** e os clientes dos seus
   atendimentos;
3. **altera** os próprios agendamentos **somente** por RPC
   `barbeiro_atualizar_status(...)`, que grava apenas `status` e
   `observacoes` — com transição validada;
4. **não** insere/exclui agendamentos nem altera id/barbearia/cliente/
   barbeiro/serviço/horários/created_at/updated_at (sem GRANT de escrita —
   ver seção "Como o PostgreSQL garante").

Trechos principais:

```sql
-- leitura dos próprios agendamentos
create policy "agendamentos_select_propria"
  on public.agendamentos for select to authenticated
  using (
    public.usuario_e_admin_da_barbearia(barbearia_id)
    or barbeiro_id = public.profissional_autenticado_id()
  );

-- clientes: admin vê todos da própria barbearia; barbeiro vê apenas
-- os que têm agendamento com ele (sem USING(true)).
create policy "clientes_select_propria"
  on public.clientes for select to authenticated
  using (
    public.usuario_e_admin_da_barbearia(barbearia_id)
    or (
      public.barbearia_profissional_autenticado() = barbearia_id
      and exists (
        select 1 from public.agendamentos a
        where a.cliente_id = clientes.id
          and a.barbeiro_id = public.profissional_autenticado_id()
      )
    )
  );
```

> **Não há** policy nem `GRANT` de INSERT/UPDATE/DELETE de `agendamentos`
> para `authenticated`. A escrita é exclusiva das RPCs (seção 6).

### 3.3 CLIENTE PÚBLICO — ADIADA (agendamento via Edge Function)

> Nesta etapa `anon` permanece **totalmente bloqueado**: nenhuma policy e
> nenhum `GRANT` para a role `anon`. O fluxo de agendamento público será
> implementado em etapa futura por meio de uma Edge Function no Supabase.

Motivos da decisão:

- `agendamentos.cliente_id` é `NOT NULL` com FK para `clientes`; o fluxo
  público precisa **localizar ou criar** o cliente antes de inserir o
  agendamento — lógica de negócio que exige um passo intermediário.
- Uma policy `anon` de INSERT em `clientes` abriria a base para poluição /
  criação arbitrária de registros.
- A comunicação do site público será feita **somente** via chamada HTTP à
  Edge Function — nunca via consulta SQL direta como `anon`.

Responsabilidades da Edge Function (role `service_role`, ignora RLS):

1. validar os dados de entrada (forma/conteúdo);
2. **localizar** o cliente por telefone/e-mail **ou criar** o registro em
   `clientes` (mesma barbearia, ativo);
3. validar que a barbearia existe e está `ativo`;
4. validar que o serviço pertence à **mesma** barbearia e está `ativo`;
5. validar que o profissional pertence à mesma barbearia e está `ativo`;
6. validar o horário: futuro, dentro do horário de funcionamento e sem
   conflito com `bloqueios_agenda`;
7. criar o agendamento com `status = 'pendente'` — o conflito de intervalo
   é garantido pela constraint `ux_agendamentos_sem_conflito`, não pela
   aplicação.

> Observações de segurança adicionais:
> - Nenhum `SELECT` é concedido a `anon` — a confirmação do agendamento é
>   entregue por WhatsApp/e-mail, não por consulta ao banco.
> - A Edge Function rodará com `service_role`: nunca expor esse segredo no
>   frontend; validar sempre entrada/saída dentro da própria função.

---

## 4. Regras de negócio de status (barbeiro e admin)

| De \ Para | pendente | confirmado | concluido | cancelado |
|---|---|---|---|---|
| **pendente** | — | ✔ | ✖ | ✔ |
| **confirmado** | ✖ | — | ✔ | ✔ |
| **concluido** | ✖ | ✖ | — | ✖ |
| **cancelado** | ✖ | ✖ | ✖ | — |

A tabela guarda apenas o status **atual**. Uma policy de UPDATE enxerga só
o estado pós-escrita e não conhece o status anterior (OLD). Para impedir
transições inválidas, a validação é feita **dentro das funções RPC**, que
podem comparar o status antigo (`OLD`) com o novo (`NEW`).

A validação central é a função `public.transicao_status_valida(novo, atual)`
(retorna `true` apenas para `pendente->confirmado`, `pendente->cancelado`,
`confirmado->concluido`, `confirmado->cancelado`). Ela é usada tanto pela
RPC do barbeiro quanto pela RPC do admin. Se o status **não muda**
(`p_status = a.status`, ex.: admin só ajusta o horário ou o barbeiro só
escreve observações), a atualização é permitida sem exigir transição. Com
isso:

- `concluido -> confirmado` / `concluido -> pendente` → recusado;
- `cancelado -> concluido` / `cancelado -> confirmado` → recusado.

---

## 5. Como o PostgreSQL garante que o barbeiro não modifique as demais colunas

Esse era o furo da versão anterior: `GRANT UPDATE ON agendamentos` concedia
atualização de **todas** as colunas, e o `GRANT UPDATE (status,
observacoes)` posterior não revogava o primeiro (no PostgreSQL o grant mais
amplo prevalece).

A solução segura elimina o problema pela raiz:

1. **Sem `GRANT` de escrita em `agendamentos`.** Nenhum `INSERT`, `UPDATE`
   ou `DELETE` (de tabela inteira **ou** por coluna) é concedido a nenhuma
   role pelo caminho direto da tabela. Sem o privilégio de UPDATE, o
   PostgreSQL recusa **qualquer** `UPDATE` direto — inclusive o de uma única
   coluna — com `permission denied for table agendamentos`. Isso vale para
   `id`, `barbearia_id`, `cliente_id`, `barbeiro_id`, `servico_id`,
   `data_hora_inicio`, `data_hora_fim`, `created_at`, `updated_at`.

2. **Sem policy de escrita de `agendamentos`.** RLS não é usada como
   substituto de privilégio de coluna; não há policy de INSERT/UPDATE/
   DELETE de `agendamentos` para `authenticated`, então não existe sequer
   um caminho de linha que autorize a escrita.

3. **Toda escrita via função RPC (`SECURITY DEFINER`).** As funções da
   seção 9 de `rls.sql` rodam como dono (ignoram RLS sem necessidade de
   grants). A **única** coluna/grupo que cada RPC grava está embutido no
   comando `SET` da própria função:
   - `barbeiro_atualizar_status(...)`: o `SET` é **exatamente**
     `status` e `observacoes`. É impossível passar `cliente_id`,
     `barbeiro_id`, `servico_id`, horários etc. porque esses parâmetros nem
     existem na assinatura da função — o PostgreSQL rejeita chamada com
     argumentos a mais/menos, e a função simplesmente não escreve nessas
     colunas. Além disso, o `WHERE` limita a linha a `barbeiro_id` do
     profissional autenticado.
   - `admin_atualizar_agendamento(...)`: aceita as colunas operáveis, mas o
     `WHERE` exige `usuario_e_admin_da_barbearia`, então um barbeiro que
     chame essa função recebe exceção.

Em resumo: o barbeiro **não possui privilégio de escrita direta** na tabela
e **só conhece uma RPC** cujo conjunto fixo de colunas é `status`/
`observacoes`. Não há como contornar com um `UPDATE` direto (sem grant) nem
com outra RPC (sem execute / validação de cargo).

---

## 6. Ordem de aplicação sugerida

1. Criar as funções auxiliares (seção 2) e a função de transição
   (seção 4) com os revokes/grants.
2. Aplicar os `DROP POLICY IF EXISTS` e as policies de leitura
   (`database/rls.sql`).
3. Criar as funções RPC de escrita de `agendamentos` (`admin_criar`,
   `admin_atualizar`, `admin_excluir`, `barbeiro_atualizar_status`).
4. Aplicar os `GRANT`s mínimos (somente `authenticated`; sem escrita direta
   de `agendamentos`).
5. Validar cada cenário com `set role authenticated;` e os testes da
   matriz em `database/rls.sql` (seção 13).
6. Implementar **depois**, em etapa futura, a Edge Function do agendamento
   público (seção 3.3) — aí sim a role `service_role` passa a escrever
   agendamentos. Nenhuma policy/GRANT para `anon` é prevista.

---

## 7. Checklist de auditoria

- [ ] Nenhuma `policy` com `USING (true)` / `WITH CHECK (true)`.
- [ ] Todo acesso deriva de `auth.uid()` via `profissionais`.
- [ ] Nenhum `barbearia_id` vindo do frontend é confiável isoladamente.
- [ ] `anon` não possui nenhum `GRANT`/policy nesta etapa (fluxo público
      via Edge Function `service_role` em etapa futura).
- [ ] **Nenhum** `GRANT` de INSERT/UPDATE/DELETE direto de `agendamentos`
      (nem de tabela, nem de coluna) — escrita só via RPC.
- [ ] Barbeiro só altera `status`/`observacoes` dos próprios agendamentos
      (via `barbeiro_atualizar_status`), com transição validada.
- [ ] Transições inválidas (`concluido`/`cancelado` → qualquer coisa) são
      recusadas pela função `transicao_status_valida`.
- [ ] Admin não acessa outras barbearias (multi-tenant seguro).
- [ ] Cada função auxiliar/`security definer` tem `search_path` fixo e é
      usada por pelo menos uma policy/RPC.