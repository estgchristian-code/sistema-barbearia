// ===========================================================================
// Edge Function: criar-agendamento
//
// Rota pública de agendamento para a página pública (hosted em Vite/Vercel).
// Esta função RODA NO SERVIDOR e usa a chave de service role / connection
// string SOMENTE no ambiente da Edge Function — nunca retorna segredos ao
// cliente e nunca os coloca no frontend.
//
// Operação: valida tudo (barbearia, barbeiro, serviço, cliente, horário de
// funcionamento, bloqueios, duração) e insere um agendamento com status
// 'pendente'. O PostgreSQL (ux_agendamentos_sem_conflito) é a autoridade
// final contra sobreposição de horários.
//
// IDENTIFICADOR PÚBLICO: a página pública NÃO expõe o id interno sequencial.
// Ela envia um "slug" público (ex.: "barbearia-estilo"), a função busca a
// barbearia por esse slug e usa o id INTERNO obtido nas validações/INSERT.
//
//   slug público -> buscar barbearia -> obter id interno -> validar + inserir
//
// OBSERVAÇÃO DE DEPLOY: a busca por slug depende de uma coluna "slug" única
// em public.barbearias (ver migration documentada em
// supabase/functions/criar-agendamento/MIGRATION.md). Enquanto essa migration
// NÃO for aplicada, a função retorna 404 ao buscar o slug — NÃO fazer deploy
// antes de aplicar a migração.
//
// No deploy (Supabase CLI):  supabase functions deploy criar-agendamento
// (com --no-verify-jwt, pois é uma rota pública).
// ===========================================================================

import postgres from "npm:postgres@3";

// ---------------------------------------------------------------------------
// Configuração (variáveis de ambiente, todas server-side)
// ---------------------------------------------------------------------------
const ALLOWED_ORIGINS = (Deno.env.get("PUBLIC_ORIGINS") ?? "")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);
// Fuso horário LOCAL da barbearia para validar horário de funcionamento.
const BARBEARIA_TIMEZONE = Deno.env.get("PUBLIC_TIMEZONE") ?? "America/Sao_Paulo";

const sql = postgres(
  Deno.env.get("SUPABASE_DB_URL") ?? Deno.env.get("DATABASE_URL") ?? "",
  {
    max: 10,
    // Timeout curto para não travar a requisição.
    connect_timeout: 10,
  },
);

// ---------------------------------------------------------------------------
// CORS — somente origens configuradas. O domínio da aplicação pública
// (ex.: https://agenda.minhaempresa.com.br) deve constar em PUBLIC_ORIGINS
// no dashboard do Supabase (Environment > Edge Functions).
// ---------------------------------------------------------------------------
function corsHeaders(req: Request): Headers {
  const origin = req.headers.get("origin") ?? "";
  const permitido = ALLOWED_ORIGINS.includes(origin);
  const headers = new Headers({ "content-type": "application/json" });
  if (permitido) {
    headers.set("access-control-allow-origin", origin);
    headers.set("vary", "Origin");
    headers.set("access-control-allow-methods", "POST, OPTIONS");
    headers.set("access-control-allow-headers", "content-type");
  }
  return headers;
}

function resp(status: number, body: unknown, headers: Headers): Response {
  return new Response(JSON.stringify(body), { status, headers });
}

function sucesso(agendamento: unknown, headers: Headers): Response {
  return resp(201, { ok: true, data: agendamento }, headers);
}

function erro(status: number, mensagem: string, headers: Headers): Response {
  return resp(status, { ok: false, message: mensagem }, headers);
}

// ---------------------------------------------------------------------------
// Helpers de fuso horário (localização da barbearia)
// ---------------------------------------------------------------------------
function horaParaMinutos(str: string): number {
  const [h, m] = String(str || "").split(":").map(Number);
  return (h || 0) * 60 + (m || 0);
}

// Devolve a parte de relógio (hora/minuto) do instante naquele fuso.
function minutosLocais(tz: string, d: Date): number {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: tz,
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).formatToParts(d);
  let h = 0;
  let m = 0;
  for (const p of parts) {
    if (p.type === "hour") h = Number(p.value);
    if (p.type === "minute") m = Number(p.value);
  }
  // en-US pode retornar "24" para meia-noite.
  if (h === 24) h = 0;
  return h * 60 + m;
}

// Devolve o dia da semana (0=domingo .. 6=sábado) no fuso informado.
function diaSemanaLocal(tz: string, d: Date): number {
  const weekday = new Intl.DateTimeFormat("en-US", {
    timeZone: tz,
    weekday: "short",
  }).format(d);
  const mapa: Record<string, number> = {
    Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6,
  };
  return mapa[weekday] ?? 0;
}

// ---------------------------------------------------------------------------
// Validação de entrada
// ---------------------------------------------------------------------------
interface Entrada {
  slug: string;
  cliente_nome: string;
  cliente_telefone: string;
  cliente_email?: string | null;
  barbeiro_id: number;
  servico_id: number;
  data_hora_inicio: string;
  observacoes?: string | null;
}

function validarTelefone(t: string): boolean {
  // Aceita dígitos e espaços/traços/parenteses com pelo menos 8 dígitos.
  return /^[\d\s()+-]{8,20}$/.test(t) && /\d{8,}/.test(t);
}

function validarEmail(e: string): boolean {
  return /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(e);
}

// Slug público: letras minúsculas, dígitos e hífens, sem começar/terminar em
// hífen, 3 a 60 caracteres. Evita caracteres especiais/injeção.
function validarSlug(s: string): boolean {
  return /^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(s) && s.length >= 3 && s.length <= 60;
}

function parseEntrada(objeto: unknown): { entrada: Entrada; erro?: string } {
  if (!objeto || typeof objeto !== "object") {
    return { entrada: null as never, erro: "Corpo da requisição inválido." };
  }
  const b = objeto as Record<string, unknown>;

  // Identificador público: slug (não expõe o id interno sequencial).
  const slug = String(b.slug ?? "").trim().toLowerCase();
  if (!validarSlug(slug)) {
    return { entrada: null as never, erro: "slug da barbearia inválido." };
  }

  const barbeiro_id = Number(b.barbeiro_id);
  const servico_id = Number(b.servico_id);
  if (!Number.isInteger(barbeiro_id) || barbeiro_id <= 0) {
    return { entrada: null as never, erro: "barbeiro_id inválido." };
  }
  if (!Number.isInteger(servico_id) || servico_id <= 0) {
    return { entrada: null as never, erro: "servico_id inválido." };
  }

  const cliente_nome = String(b.cliente_nome ?? "").trim();
  if (!cliente_nome) {
    return { entrada: null as never, erro: "O nome do cliente é obrigatório." };
  }

  const cliente_telefone = String(b.cliente_telefone ?? "").trim();
  if (!validarTelefone(cliente_telefone)) {
    return { entrada: null as never, erro: "Telefone do cliente inválido." };
  }

  let cliente_email: string | null = null;
  if (b.cliente_email != null && b.cliente_email !== "") {
    cliente_email = String(b.cliente_email).trim();
    if (!validarEmail(cliente_email)) {
      return { entrada: null as never, erro: "E-mail do cliente inválido." };
    }
  }

  const data_hora_inicio = String(b.data_hora_inicio ?? "");
  const inicio = new Date(data_hora_inicio);
  if (!data_hora_inicio || Number.isNaN(inicio.getTime())) {
    return { entrada: null as never, erro: "Data/hora de início inválida." };
  }

  const observacoes = b.observacoes == null ? null : String(b.observacoes).slice(0, 1000);

  return {
    entrada: {
      slug,
      cliente_nome,
      cliente_telefone,
      cliente_email,
      barbeiro_id,
      servico_id,
      data_hora_inicio: inicio.toISOString(),
      observacoes,
    },
  };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
Deno.serve(async (req: Request) => {
  const headers = corsHeaders(req);

  if (req.method === "OPTIONS") {
    if (ALLOWED_ORIGINS.length === 0) {
      return erro(403, "Fonte não permitida: nenhuma origem configurada.", headers);
    }
    return new Response(null, { status: 204, headers });
  }

  if (req.method !== "POST") {
    return erro(405, "Método não permitido.", headers);
  }

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

  const inicio = new Date(entrada.data_hora_inicio);

  try {
    const agendamento = await criarAgendamentoPublico(entrada, inicio);
    console.log("[criar-agendamento] ok", {
      slug: entrada.slug,
      barbeiro_id: entrada.barbeiro_id,
      servico_id: entrada.servico_id,
      inicio: entrada.data_hora_inicio,
    });
    return sucesso(agendamento, headers);
  } catch (err) {
    const e = err as { code?: string; message?: string };

    // 23P01 = violação da exclusion constraint de sobreposição.
    if (e.code === "23P01") {
      return erro(409, "Esse horário já foi ocupado para este barbeiro.", headers);
    }

    // Códigos de validação de negócio da própria função (gerados com throw integrado).
    const msg = String(e.message ?? "");
    if (msg.startsWith("EM:")) {
      const [codigo, texto] = msg.slice(3).split("|", 2);
      return erro(Number(codigo) || 422, texto || "Solicitação inválida.", headers);
    }

    // Validações lançadas pelo banco (trigger trg_agendamentos_validar_bloqueios),
    // que é a autoridade final e o backstop para o caso concorrente (corrida
    // entre a pré-validação da função e o commit do agendamento). Devolvem uma
    // resposta amigável em vez de 500.
    if (msg.includes("bloqueado para este barbeiro")) {
      return erro(409, "Este horário está bloqueado para este barbeiro.", headers);
    }
    if (
      msg.includes("fora do funcionamento") ||
      msg.includes("fechada neste dia")
    ) {
      return erro(422, msg.trim(), headers);
    }

    console.error("[criar-agendamento] erro interno", e);
    // Nunca expor stack trace nem detalhes do banco ao cliente.
    return erro(500, "Erro interno ao processar o agendamento.", headers);
  }
});

// ---------------------------------------------------------------------------
// Lógica de negócio (usada dentro de transação)
// ---------------------------------------------------------------------------
async function criarAgendamentoPublico(entrada: Entrada, inicio: Date) {
  // A operação inteira roda em uma transação para ser o mais atômica possível:
  // validar tudo + obter/criar cliente + inserir agendamento.
  return await sql.begin(async (tx) => {
    // 1) Localizar a barbearia pelo IDENTIFICADOR PÚBLICO (slug) e obter o id
    // INTERNO. O id interno nunca vem do cliente.
    const barbearias = await tx`
      select id from public.barbearias
      where slug = ${entrada.slug} and ativo = true
      limit 1
    `;
    if (barbearias.length === 0) throw negocio(404, "Barbearia não encontrada.");
    const barbeariaId = Number(barbearias[0].id);

    // 2) Profissional existe, é da mesma barbearia, cargo barbeiro e ativo.
    const profissionais = await tx`
      select id, nome from public.profissionais
      where id = ${entrada.barbeiro_id}
        and barbearia_id = ${barbeariaId}
        and cargo = 'barbeiro'
        and ativo = true
      limit 1
    `;
    if (profissionais.length === 0) {
      throw negocio(404, "Barbeiro não encontrado ou indisponível.");
    }

    // 3) Serviço existe, é da mesma barbearia e ativo. A duração vem do banco.
    const servicos = await tx`
      select id, nome, duracao_minutos from public.servicos
      where id = ${entrada.servico_id}
        and barbearia_id = ${barbeariaId}
        and ativo = true
      limit 1
    `;
    if (servicos.length === 0) {
      throw negocio(404, "Serviço não encontrado ou indisponível.");
    }
    const duracaoMinutos = Number(servicos[0].duracao_minutos);

    // 4) Início no futuro.
    if (inicio.getTime() <= Date.now()) {
      throw negocio(422, "Não é possível agendar em um horário passado.");
    }

    // 5) Horário de funcionamento.
    const diaSemana = diaSemanaLocal(BARBEARIA_TIMEZONE, inicio);
    const horarios = await tx`
      select hora_abertura, hora_fechamento, fechado
      from public.horarios_funcionamento
      where barbearia_id = ${barbeariaId}
        and dia_semana = ${diaSemana}
      limit 1
    `;
    if (horarios.length === 0 || horarios[0].fechado) {
      throw negocio(422, "Barbearia fechada neste dia.");
    }
    const aberturaMin = horaParaMinutos(horarios[0].hora_abertura);
    const fechamentoMin = horaParaMinutos(horarios[0].hora_fechamento);

    // 6) Duracao e fim calculado server-side (nunca do frontend).
    const fim = new Date(inicio.getTime() + duracaoMinutos * 60000);
    const inicioMin = minutosLocais(BARBEARIA_TIMEZONE, inicio);
    const fimMin = minutosLocais(BARBEARIA_TIMEZONE, fim);

    // Intervalo completo dentro do funcionamento.
    if (inicioMin < aberturaMin || fimMin > fechamentoMin) {
      throw negocio(422, "Este horário está fora do funcionamento da barbearia.");
    }

    // 7) Bloqueios gerais e específicos do barbeiro.
    const bloqueios = await tx`
      select id from public.bloqueios_agenda
      where barbearia_id = ${barbeariaId}
        and (barbeiro_id is null or barbeiro_id = ${entrada.barbeiro_id})
        and inicio < ${fim.toISOString()}
        and fim > ${inicio.toISOString()}
      limit 1
    `;
    if (bloqueios.length > 0) {
      throw negocio(422, "Este horário está bloqueado para este barbeiro.");
    }

    // 8) Cliente: reutilizar se existir (por telefone na mesma barbearia; ou
    // por e-mail se informado) — senão criar. Qualquer vínculo é SEMPRE da
    // própria barbearia.
    const telefoneNorm = entrada.cliente_telefone.trim();
    let cliente;
    const porTelefone = await tx`
      select id from public.clientes
      where barbearia_id = ${barbeariaId}
        and telefone = ${telefoneNorm}
        and ativo = true
      limit 1
    `;
    if (porTelefone.length > 0) {
      cliente = porTelefone[0];
    } else if (entrada.cliente_email) {
      const porEmail = await tx`
        select id from public.clientes
        where barbearia_id = ${barbeariaId}
          and email = ${entrada.cliente_email}
          and ativo = true
        limit 1
      `;
      if (porEmail.length > 0) cliente = porEmail[0];
    }

    if (!cliente) {
      const criado = await tx`
        insert into public.clientes
          (barbearia_id, nome, telefone, email, ativo)
        values
          (${barbeariaId}, ${entrada.cliente_nome}, ${telefoneNorm}, ${entrada.cliente_email ?? null}, true)
        returning id, nome
      `;
      cliente = criado[0];
    }

    // 9) INSERT — a constraint ux_agendamentos_sem_conflito é a autoridade
    // final contra agendamentos sobrepostos do mesmo barbeiro (23P01 -> 409).
    // ATENÇÃO: isso NÃO é idempotência completa. Uma chave formal de
    // idempotência (para reenvio da MESMA requisição) ainda NÃO foi
    // implementada e poderá ser adicionada futuramente, se necessário.
    const agendados = await tx`
      insert into public.agendamentos
        (barbearia_id, cliente_id, barbeiro_id, servico_id, data_hora_inicio, data_hora_fim, status, observacoes)
      values
        (
          ${barbeariaId},
          ${Number(cliente.id)},
          ${entrada.barbeiro_id},
          ${entrada.servico_id},
          ${inicio.toISOString()},
          ${fim.toISOString()},
          'pendente',
          ${entrada.observacoes ?? null}
        )
      returning id, data_hora_inicio, data_hora_fim, status
    `;

    return agendados[0];
  });
}

// Helper: erro de negócio com código HTTP embutido ("EM:<status>|<mensagem>").
function negocio(status: number, mensagem: string): Error {
  return new Error(`EM:${status}|${mensagem}`);
}
