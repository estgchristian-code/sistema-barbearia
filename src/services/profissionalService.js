import { supabase } from '../lib/supabase.js';
import { obterUsuarioAutenticado } from './authService.js';

const CAMPOS_PERFIL = 'id, auth_user_id, barbearia_id, nome, telefone, cargo, ativo';

export async function obterProfissionalAutenticado() {
  const usuario = await obterUsuarioAutenticado();
  if (!usuario) return null;

  const { data, error } = await supabase
    .from('profissionais')
    .select(CAMPOS_PERFIL)
    .eq('auth_user_id', usuario.id)
    .maybeSingle();

  if (error) throw error;
  return data;
}

// Lista os profissionais da própria barbearia (RLS profissionais_select_propria).
export async function listarProfissionaisDaBarbearia() {
  const profissional = await obterProfissionalAutenticado();
  if (!profissional) return [];
  if (!profissional.ativo) throw new Error('Este profissional está inativo.');

  const { data, error } = await supabase
    .from('profissionais')
    .select(CAMPOS_PERFIL)
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

export function mensagemErroProfissional(erro) {
  const mensagem = (erro?.message || '').toLowerCase();

  if (erro?.code === '42501' || mensagem.includes('permission denied') || mensagem.includes('row-level security')) {
    return 'Sem permissão para realizar esta operação. Verifique se você é um administrador ativo desta barbearia.';
  }

  if (erro?.code === '23505' || mensagem.includes('uq_profissionais_auth_user')) {
    return 'Este usuário já está vinculado a um profissional.';
  }

  return erro?.message || 'Não foi possível concluir a operação.';
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