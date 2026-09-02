import { supabase } from '../lib/supabase.js';
import { obterProfissionalAutenticado } from './profissionalService.js';

const CAMPOS_CLIENTE = [
  'id',
  'barbearia_id',
  'nome',
  'telefone',
  'email',
  'observacoes',
  'ativo',
  'created_at',
  'updated_at',
].join(',');

// A barbearia NUNCA vem do frontend. É derivada do profissional autenticado
// (profissionais.auth_user_id = auth.uid()). Toda consulta é filtrada por
// este barbearia_id, então o RLS só expõe clientes da própria barbearia.
async function obterBarbeariaDoProfissional() {
  const profissional = await obterProfissionalAutenticado();
  if (!profissional) throw new Error('Usuário não está vinculado a uma barbearia.');
  if (!profissional.ativo) throw new Error('Este profissional está inativo.');
  return profissional.barbearia_id;
}

export async function listarClientesDaBarbearia() {
  const barbeariaId = await obterBarbeariaDoProfissional();

  const { data, error } = await supabase
    .from('clientes')
    .select(CAMPOS_CLIENTE)
    .eq('barbearia_id', barbeariaId)
    .order('nome', { ascending: true });

  if (error) throw error;
  return data || [];
}

export async function criarCliente(dados) {
  const barbeariaId = await obterBarbeariaDoProfissional();

  const { data, error } = await supabase
    .from('clientes')
    .insert({
      barbearia_id: barbeariaId,
      nome: normalizarTexto(dados.nome, true),
      telefone: normalizarTextoOpcional(dados.telefone),
      email: normalizarTextoOpcional(dados.email),
      observacoes: normalizarTextoOpcional(dados.observacoes),
      ativo: Boolean(dados.ativo),
    })
    .select(CAMPOS_CLIENTE)
    .single();

  if (error) throw error;
  return data;
}

export async function atualizarCliente(id, dados) {
  const barbeariaId = await obterBarbeariaDoProfissional();

  const { data, error } = await supabase
    .from('clientes')
    .update({
      nome: normalizarTexto(dados.nome, true),
      telefone: normalizarTextoOpcional(dados.telefone),
      email: normalizarTextoOpcional(dados.email),
      observacoes: normalizarTextoOpcional(dados.observacoes),
      ativo: Boolean(dados.ativo),
    })
    .eq('id', id)
    .eq('barbearia_id', barbeariaId) // garante operação só na própria barbearia
    .select(CAMPOS_CLIENTE)
    .single();

  if (error) throw error;
  return data;
}

export async function alterarAtivoCliente(id, ativo) {
  const barbeariaId = await obterBarbeariaDoProfissional();

  const { data, error } = await supabase
    .from('clientes')
    .update({ ativo: Boolean(ativo) })
    .eq('id', id)
    .eq('barbearia_id', barbeariaId)
    .select(CAMPOS_CLIENTE)
    .single();

  if (error) throw error;
  return data;
}

export function mensagemErroCliente(erro) {
  const mensagem = (erro?.message || '').toLowerCase();

  if (erro?.code === '42501' || mensagem.includes('permission denied') || mensagem.includes('row-level security')) {
    return 'Sem permissão para realizar esta operação. Verifique se você é um administrador ativo desta barbearia.';
  }

  // Violação do CHECK de e-mail (chk_clientes_email).
  if (
    mensagem.includes('chk_clientes_email') ||
    mensagem.includes('viola restrição') ||
    (mensagem.includes('email') && (mensagem.includes('check') || mensagem.includes('constraint')))
  ) {
    return 'O e-mail informado não é válido.';
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
