// ===========================================================================
// Edge Function: criar-acesso-profissional
//
// Cria um usuário no Supabase Auth e vincula ao registro de profissional.
// Somente administradores da barbearia podem executar esta operação.
//
// Segurança:
//   - verify_jwt = true (plataforma garante JWT válido).
//   -service_role SOMENTE dentro desta Edge Function.
//   - Verifica que o chamador é admin da barbearia do profissional.
//   - Não expõe service_role, nem logs, nem erros internos ao cliente.
//
// Deploy:
//   supabase functions deploy criar-acesso-profissional
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
// CORS — usa PUBLIC_ORIGINS (mesmo padrão de criar-agendamento).
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

function validarEmail(email: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
}

// ---------------------------------------------------------------------------
// Validação de entrada
// ---------------------------------------------------------------------------
interface Entrada {
  profissional_id: number;
  email: string;
  senha: string;
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

  const email = String(b.email ?? "").trim().toLowerCase();
  if (!email || !validarEmail(email)) {
    return { entrada: null, erro: "E-mail inválido." };
  }

  const senha = String(b.senha ?? "");
  if (senha.length < 12) {
    return { entrada: null, erro: "A senha deve ter pelo menos 12 caracteres." };
  }

  return { entrada: { profissional_id, email, senha } };
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
  // O平台 já verificou a assinatura (verify_jwt = true).
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
      return erro(403, "Somente administradores podem criar acessos.", headers);
    }
    const barbeariaId = Number(admins[0].barbearia_id);

    // 2) Verificar que o profissional existe, pertence à mesma barbearia,
    //    ainda NÃO foi excluído (soft delete) e ainda não possui acesso.
    const profs = await sql`
      SELECT id, auth_user_id, cargo
      FROM public.profissionais
      WHERE id = ${entrada.profissional_id}
        AND barbearia_id = ${barbeariaId}
        AND deleted_at IS NULL
      LIMIT 1
    `;
    if (profs.length === 0) {
      return erro(404, "Profissional não encontrado nesta barbearia.", headers);
    }
    if (profs[0].auth_user_id) {
      return erro(
        409,
        "Este profissional já possui acesso ao sistema.",
        headers,
      );
    }

    // 3) Criar usuário no Supabase Auth via API admin.
    const authRes = await fetch(`${SUPABASE_URL}/auth/v1/admin/users`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: SERVICE_ROLE_KEY,
      },
      body: JSON.stringify({
        email: entrada.email,
        password: entrada.senha,
        email_confirm: true,
        user_metadata: {
          barbearia_id: barbeariaId,
          profissional_id: entrada.profissional_id,
          cargo: profs[0].cargo,
        },
      }),
    });

    const authData = await authRes.json();

    if (!authRes.ok) {
      const msg = authData?.msg || authData?.message || "";
      const errorDescription = authData?.error_description || "";

      // E-mail duplicado no Auth.
      if (
        authRes.status === 409 ||
        msg.toLowerCase().includes("already") ||
        errorDescription.toLowerCase().includes("already")
      ) {
        return erro(
          409,
          "Este e-mail já está cadastrado no sistema.",
          headers,
        );
      }

      console.error("[criar-acesso-profissional] auth error", authRes.status, authData);
      return erro(500, "Erro ao criar usuário de acesso.", headers);
    }

    const authUserId = authData?.id;
    if (!authUserId) {
      console.error("[criar-acesso-profissional] auth response sem id", authData);
      return erro(500, "Erro ao criar usuário de acesso.", headers);
    }

    // 4) Vincular auth_user_id ao profissional.
    //    A constraint uq_profissionais_auth_user previne duplicatas.
    const atualizados = await sql`
      UPDATE public.profissionais
      SET auth_user_id = ${authUserId}::uuid,
          updated_at  = now()
      WHERE id = ${entrada.profissional_id}
        AND barbearia_id = ${barbeariaId}
        AND auth_user_id IS NULL
      RETURNING id, auth_user_id
    `;

    if (atualizados.length === 0) {
      // O profissional pode ter sido vinculado por outra requisição
      // simultânea. Tentar limpar o usuário Auth criado.
      console.error(
        "[criar-acesso-profissional] falha ao vincular — profissional pode ter sido vinculado por outra requisição",
      );
      await fetch(`${SUPABASE_URL}/auth/v1/admin/users/${authUserId}`, {
        method: "DELETE",
        headers: {
          apikey: SERVICE_ROLE_KEY,
        },
      }).catch(() => {
        // Se a limpeza falhar, o usuário Auth ficará órfão.
        // Pode ser removido manualmente no Dashboard.
      });

      return erro(
        409,
        "Este profissional já possui acesso ao sistema.",
        headers,
      );
    }

    return ok({ auth_user_id: authUserId }, headers);
  } catch (err) {
    console.error("[criar-acesso-profissional] erro interno", err);
    return erro(500, "Erro interno ao criar acesso.", headers);
  }
});
