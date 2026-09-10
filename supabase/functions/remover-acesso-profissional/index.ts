// ===========================================================================
// Edge Function: remover-acesso-profissional
//
// Remove o usuário do Supabase Auth de um profissional EXCLUÍDO (soft
// delete). A exclusão lógica em si é feita pela RPC admin_excluir_profissional;
// esta função serve apenas para "matar" o login do profissional excluído.
//
// Fluxo (secure):
//   1. Frontend chama a RPC admin_excluir_profissional (marca deleted_at +
//      ativo = false). A partir daí o profissional já não opera (RLS exige
//      deleted_at IS NULL em todas as funções auxiliares).
//   2. Frontend (ou operação server-side) chama ESTA função para remover o
//      usuário Auth. A FK profissionais.auth_user_id -> auth.users(id) com
//      ON DELETE SET NULL desvincula automaticamente o auth_user_id.
//
// Segurança:
//   - verify_jwt = true (plataforma garante JWT válido).
//   - service_role SOMENTE dentro desta Edge Function (API de admin Auth).
//   - Verifica que o chamador é ADMIN da mesma barbearia do profissional.
//   - Só remove acesso de profissional com deleted_at IS NOT NULL — esta
//     função NÃO funciona como "revogar acesso" genérico.
//   - Não expõe service_role, nem logs, nem erros internos ao cliente.
//
// Deploy:
//   supabase functions deploy remover-acesso-profissional
//   (com --verify-jwt, que é o padrão).
// ===========================================================================

import postgres from "npm:postgres@3";

// ---------------------------------------------------------------------------
// Configuração
// ---------------------------------------------------------------------------
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const sql = postgres(
  Deno.env.get("SUPABASE_DB_URL") ?? Deno.env.get("DATABASE_URL") ?? "",
  { max: 5, connect_timeout: 10 },
);

// ---------------------------------------------------------------------------
// CORS — usa PUBLIC_ORIGINS (mesmo padrão das demais funções).
// ---------------------------------------------------------------------------
const ALLOWED_ORIGINS = (Deno.env.get("PUBLIC_ORIGINS") ?? "")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);

function corsHeaders(req: Request): Headers {
  const origin = req.headers.get("origin") ?? "";
  const permitido = ALLOWED_ORIGINS.includes(origin);
  const headers = new Headers({ "content-type": "application/json" });
  if (permitido) {
    headers.set("access-control-allow-origin", origin);
    headers.set("vary", "Origin");
    headers.set("access-control-allow-methods", "POST, OPTIONS");
    headers.set("access-control-allow-headers", "content-type, authorization");
  }
  return headers;
}

function ok(data: unknown, headers: Headers): Response {
  return new Response(JSON.stringify({ ok: true, data }), { status: 200, headers });
}

function erro(status: number, mensagem: string, headers: Headers): Response {
  return new Response(JSON.stringify({ ok: false, message: mensagem }), {
    status,
    headers,
  });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
function extrairToken(req: Request): string | null {
  const auth = req.headers.get("authorization") ?? "";
  if (auth.toLowerCase().startsWith("bearer ")) {
    return auth.slice(7).trim() || null;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Validação de entrada
// ---------------------------------------------------------------------------
interface Entrada {
  profissional_id: number;
}

function parseEntrada(body: unknown): { entrada: Entrada | null; erro?: string } {
  if (!body || typeof body !== "object") {
    return { entrada: null, erro: "Corpo da requisição inválido." };
  }
  const b = body as Record<string, unknown>;

  const profissional_id = Number(b.profissional_id);
  if (!Number.isInteger(profissional_id) || profissional_id <= 0) {
    return { entrada: null, erro: "profissional_id inválido." };
  }

  return { entrada: { profissional_id } };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
Deno.serve(async (req: Request) => {
  const headers = corsHeaders(req);

  if (req.method === "OPTIONS") {
    if (ALLOWED_ORIGINS.length === 0) {
      return erro(403, "Nenhuma origem configurada.", headers);
    }
    return new Response(null, { status: 204, headers });
  }

  if (req.method !== "POST") {
    return erro(405, "Método não permitido.", headers);
  }

  // --- JWT ---
  const token = extrairToken(req);
  if (!token) {
    return erro(401, "Autenticação necessária.", headers);
  }

  // Decodifica o JWT para obter o sub (auth user id).
  // A plataforma já verificou a assinatura (verify_jwt = true).
  let payload: Record<string, unknown>;
  try {
    const payloadB64 = token.split(".")[1];
    const json = atob(payloadB64.replace(/-/g, "+").replace(/_/g, "/"));
    payload = JSON.parse(json);
  } catch {
    return erro(401, "Token inválido.", headers);
  }

  const chamadorAuthId = payload.sub;
  if (typeof chamadorAuthId !== "string" || !chamadorAuthId) {
    return erro(401, "Token inválido.", headers);
  }

  // --- Corpo ---
  let corpo: unknown;
  try {
    corpo = await req.json();
  } catch {
    return erro(400, "JSON inválido no corpo da requisição.", headers);
  }

  const { entrada, erro: erroEntrada } = parseEntrada(corpo);
  if (!entrada || erroEntrada) {
    return erro(400, erroEntrada ?? "Dados inválidos.", headers);
  }

  try {
    // 1) Verificar que o chamador é admin de uma barbearia e obter seu
    //    barbearia_id.
    const admins = await sql`
      SELECT id, barbearia_id
      FROM public.profissionais
      WHERE auth_user_id = ${chamadorAuthId}
        AND cargo = 'admin'
        AND ativo = true
        AND deleted_at IS NULL
      LIMIT 1
    `;
    if (admins.length === 0) {
      return erro(403, "Somente administradores podem remover acessos.", headers);
    }
    const barbeariaId = Number(admins[0].barbearia_id);

    // 2) Verificar que existe um profissional EXCLUÍDO (deleted_at não nulo)
    //    da mesma barbearia. Esta função não serve para revogar acesso de
    //    profissionais ativos/desativados — apenas do fluxo de exclusão.
    const profs = await sql`
      SELECT id, auth_user_id
      FROM public.profissionais
      WHERE id = ${entrada.profissional_id}
        AND barbearia_id = ${barbeariaId}
        AND deleted_at IS NOT NULL
      LIMIT 1
    `;
    if (profs.length === 0) {
      return erro(404, "Profissional excluído não encontrado nesta barbearia.", headers);
    }

    // 3) Sem usuário Auth vinculado: nada a fazer (por exemplo, o vínculo já
    //    foi desfeito pelo ON DELETE SET NULL ou nunca existiu).
    const authUserId = profs[0].auth_user_id;
    if (!authUserId) {
      return ok({ removido: false, motivo: "sem_vínculo_auth" }, headers);
    }

    // 4) Remover o usuário no Supabase Auth via API admin.
    const authRes = await fetch(
      `${SUPABASE_URL}/auth/v1/admin/users/${authUserId}`,
      {
        method: "DELETE",
        headers: {
          apikey: SERVICE_ROLE_KEY,
        },
      },
    );

    if (!authRes.ok) {
      const authData = await authRes.json().catch(() => null);

      // 404 = usuário Auth já não existe (foi removido por outra via).
      if (authRes.status === 404) {
        return ok({ removido: false, motivo: "auth_inexistente" }, headers);
      }

      console.error(
        "[remover-acesso-profissional] auth error",
        authRes.status,
        authData,
      );
      return erro(500, "Não foi possível remover o usuário de acesso.", headers);
    }

    // A FK (auth_user_id -> auth.users ON DELETE SET NULL) desvincula
    // automaticamente o auth_user_id. Não há ação extra no banco aqui.

    return ok({ removido: true, auth_user_id: authUserId }, headers);
  } catch (err) {
    console.error("[remover-acesso-profissional] erro interno", err);
    return erro(500, "Erro interno ao remover acesso.", headers);
  }
});