import { supabase } from '../lib/supabase.js';
import { obterUsuarioAutenticado } from './authService.js';
import { validarTelefoneBrasileiro } from '../lib/validacao.js';

const CAMPOS_PERFIL = 'id, auth_user_id, barbearia_id, nome, telefone, cargo, ativo, deleted_at';

export async function obterProfissionalAutenticado() {
  const usuario = await obterUsuarioAutenticado();
  if (!usuario) return null;

  const { data, error } = await supabase
    .from('profissionais')
    .select(CAMPOS_PERFIL)
    .eq('auth_user_id', usuario.id)
    .is('deleted_at', null)
    .maybeSingle();

  if (error) throw error;
  return data;
}

// Lista os profissionais VIGENTES da própria barbearia
// (RLS profissionais_select_propria). Excluídos (deleted_at) ficam de fora.
export async function listarProfissionaisDaBarbearia() {
  const profissional = await obterProfissionalAutenticado();
  if (!profissional) return [];
  if (!profissional.ativo) throw new Error('Este profissional está inativo.');

  const { data, error } = await supabase
    .from('profissionais')
    .select(CAMPOS_PERFIL)
    .eq('barbearia_id', profissional.barbearia_id)
    .is('deleted_at', null)
    .order('nome', { ascending: true });

  if (error) throw error;
  return data || [];
}

// Todos os profissionais da própria barbearia, INCLUINDO excluídos
// (soft delete). Usado SOMENTE para resolver nomes no histórico de
// agendamentos e bloqueios — nunca em seletores de novos registros.
export async function listarProfissionaisIncluindoExcluidos() {
  const profissional = await obterProfissionalAutenticado();
  if (!profissional) return [];
  if (!profissional.ativo) throw new Error('Este profissional está inativo.');

  const { data, error } = await supabase
    .from('profissionais')
    .select('id, nome, cargo, ativo, deleted_at')
    .eq('barbearia_id', profissional.barbearia_id)
    .order('nome', { ascending: true });

  if (error) throw error;
  return data || [];
}

// A barbearia NUNCA vem do frontend. Ela é derivada do profissional
// autenticado (profissionais.auth_user_id = auth.uid()) e validada pelo RLS
// (profissionais_write_admin exige cargo 'admin' da própria barbearia).
async function obterBarbeariaDoProfissional(requerAdmin = true) {
  const profissional = await obterProfissionalAutenticado();
  if (!profissional) throw new Error('Usuário não está vinculado a uma barbearia.');
  if (!profissional.ativo) throw new Error('Este profissional está inativo.');
  if (requerAdmin && profissional.cargo !== 'admin') {
    throw new Error('Somente um administrador pode realizar esta operação.');
  }
  return profissional.barbearia_id;
}

// Cria um profissional (barbeiro) na própria barbearia.
// auth_user_id fica NULL: o futuro vínculo com Supabase Auth será tratado
// em etapa específica. Nenhum usuário Auth é criado aqui.
export async function criarProfissional(dados) {
  const erroValidacao = validarDadosProfissional(dados);
  if (erroValidacao) throw new Error(erroValidacao);

  const barbeariaId = await obterBarbeariaDoProfissional();

  const { data, error } = await supabase
    .from('profissionais')
    .insert({
      barbearia_id: barbeariaId,
      nome: normalizarTexto(dados.nome, true),
      telefone: normalizarTextoOpcional(dados.telefone),
      cargo: 'barbeiro',
      auth_user_id: null,
      ativo: true,
    })
    .select(CAMPOS_PERFIL)
    .single();

  if (error) throw error;
  return data;
}

// Atualiza nome/telefone/ativo. Nunca altera id, barbearia_id, auth_user_id
// nem cargo — o cargo (admin) não pode ser alterado via interface nesta etapa.
export async function atualizarProfissional(id, dados) {
  const erroValidacao = validarDadosProfissional(dados);
  if (erroValidacao) throw new Error(erroValidacao);

  const barbeariaId = await obterBarbeariaDoProfissional();

  const { data, error } = await supabase
    .from('profissionais')
    .update({
      nome: normalizarTexto(dados.nome, true),
      telefone: normalizarTextoOpcional(dados.telefone),
      ativo: Boolean(dados.ativo),
    })
    .eq('id', id)
    .eq('barbearia_id', barbeariaId)
    .select(CAMPOS_PERFIL)
    .single();

  if (error) throw error;
  return data;
}

// Exclusão lógica via campo 'ativo'. Nenhuma exclusão física.
export async function alterarAtivoProfissional(id, ativo) {
  const barbeariaId = await obterBarbeariaDoProfissional();

  const { data, error } = await supabase
    .from('profissionais')
    .update({ ativo: Boolean(ativo) })
    .eq('id', id)
    .eq('barbearia_id', barbeariaId)
    .select(CAMPOS_PERFIL)
    .single();

  if (error) throw error;
  return data;
}

// ---------------------------------------------------------------------------
// Exclusão (soft delete) de um profissional. Server-side e somente Admin:
//   1. RPC admin_excluir_profissional marca deleted_at = now() e ativo =
//      false (o banco valida admin da mesma barbearia, não deixa excluir o
//      próprio cadastro nem o único admin ativo). NUNCA exclui a linha.
//   2. Se o profissional tinha acesso (auth_user_id), chama a Edge Function
//      remover-acesso-profissional para remover o usuário do Supabase Auth.
//      Se essa remoção falhar, o profissional JÁ está excluído e inoperante
//      (RLS exige deleted_at IS NULL), mas o aviso é propagado para retry.
// ---------------------------------------------------------------------------
export async function excluirProfissional(id, temAcesso) {
  const { error } = await supabase.rpc('admin_excluir_profissional', {
    p_profissional_id: id,
  });
  if (error) throw error;

  if (temAcesso) {
    const aviso = await removerAcessoProfissional(id);
    if (aviso) {
      throw new Error(
        'O profissional foi excluído, mas o acesso ao sistema não pôde ser removido automaticamente. Tente novamente ou remova manualmente no Supabase.'
      );
    }
  }
}

// Remove o usuário Auth de um profissional excluído. Retorna null em caso de
// sucesso ou uma mensagem de erro amigável (a exclusão já foi efetivada).
// Faz exatamente 1 retry (com pequeno backoff) SOMENTE em erros transitórios
// (falha de rede, 5xx, 429, 408). Erros definitivos de autorização/validação
// (4xx sem 429/408) não são repetidos para não gerar loop nem reenviar
// chamadas que falharão novamente.
async function removerAcessoProfissional(profissionalId) {
  const { data: sessao, error: sessaoErro } = await supabase.auth.getSession();
  if (sessaoErro || !sessao?.session?.access_token) {
    return 'Sessão expirada.';
  }

  const supabaseUrl = import.meta.env.VITE_SUPABASE_URL;
  const url = `${supabaseUrl}/functions/v1/remover-acesso-profissional`;
  const opcoes = {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${sessao.session.access_token}`,
    },
    body: JSON.stringify({ profissional_id: profissionalId }),
  };

  const MAX_TENTATIVAS = 2;
  const BACKOFF_MS = 800;

  let ultimoErro = null;
  for (let tentativa = 1; tentativa <= MAX_TENTATIVAS; tentativa++) {
    let resposta;
    let json;
    try {
      resposta = await fetch(url, opcoes);
    } catch {
      ultimoErro = 'Não foi possível contactar o servidor.';
      if (tentativa < MAX_TENTATIVAS) {
        await new Promise((r) => setTimeout(r, BACKOFF_MS));
      }
      continue;
    }

    try {
      json = await resposta.json();
    } catch {
      ultimoErro = 'Resposta inválida do servidor.';
      if (tentativa < MAX_TENTATIVAS) {
        await new Promise((r) => setTimeout(r, BACKOFF_MS));
      }
      continue;
    }

    if (!resposta.ok || json?.ok === false) {
      const transitorio =
        resposta.status >= 500 ||
        resposta.status === 429 ||
        resposta.status === 408;
      ultimoErro = json?.message || 'Não foi possível remover o acesso.';
      if (transitorio && tentativa < MAX_TENTATIVAS) {
        await new Promise((r) => setTimeout(r, BACKOFF_MS));
        continue;
      }
      break;
    }

    return null;
  }

  return ultimoErro;
}

// ---------------------------------------------------------------------------
// Criar acesso de login (Supabase Auth) para um profissional.
// Chama a Edge Function criar-acesso-profissional (server-side).
// ---------------------------------------------------------------------------
export async function criarAcessoProfissional(profissionalId, email, senha) {
  const barbeariaId = await obterBarbeariaDoProfissional();

  const { data: sessao, error: sessaoErro } = await supabase.auth.getSession();
  if (sessaoErro || !sessao?.session?.access_token) {
    throw new Error('Sessão expirada. Faça login novamente.');
  }

  const supabaseUrl = import.meta.env.VITE_SUPABASE_URL;
  const url = `${supabaseUrl}/functions/v1/criar-acesso-profissional`;

  const resposta = await fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${sessao.session.access_token}`,
    },
    body: JSON.stringify({
      profissional_id: profissionalId,
      email,
      senha,
    }),
  });

  let json;
  try {
    json = await resposta.json();
  } catch {
    throw new Error('Resposta inválida do servidor.');
  }

  if (!resposta.ok || json?.ok === false) {
    throw new Error(json?.message || 'Não foi possível criar o acesso.');
  }

  return json.data;
}

export function mensagemErroProfissional(erro) {
  const mensagem = (erro?.message || '').toLowerCase();

  if (mensagem.includes('excluir o próprio cadastro')) {
    return 'Você não pode excluir o próprio cadastro.';
  }

  if (mensagem.includes('único administrador')) {
    return 'Não é possível excluir o único administrador da barbearia.';
  }

  if (mensagem.includes('já foi excluído')) {
    return 'Este profissional já foi excluído.';
  }

  if (mensagem.includes('profissional não encontrado')) {
    return 'Profissional não encontrado ou já excluído.';
  }

  if (erro?.code === '42501' || mensagem.includes('permission denied') || mensagem.includes('row-level security')) {
    return 'Sem permissão para realizar esta operação. Verifique se você é um administrador ativo desta barbearia.';
  }

  if (erro?.code === '23505' || mensagem.includes('uq_profissionais_auth_user')) {
    return 'Este usuário já está vinculado a um profissional.';
  }

  return erro?.message || 'Não foi possível concluir a operação.';
}

// Validação de negócio única para cadastro e edição de profissional. Nome é
// obrigatório; telefone é opcional, mas se informado deve ser um telefone
// brasileiro válido (DDD + número).
function validarDadosProfissional(dados) {
  const nome = normalizarTexto(dados.nome);
  if (!nome) return 'O nome do profissional é obrigatório.';

  const telefone = normalizarTexto(dados.telefone);
  if (telefone) {
    const erroTelefone = validarTelefoneBrasileiro(dados.telefone);
    if (erroTelefone) return erroTelefone;
  }

  return null;
}

function normalizarTexto(texto, obrigatorio = false) {
  const v = typeof texto === 'string' ? texto.trim() : '';
  if (obrigatorio && v === '') throw new Error('Campo obrigatório não informado.');
  return v;
}

function normalizarTextoOpcional(texto) {
  const v = normalizarTexto(texto);
  return v === '' ? null : v;
}