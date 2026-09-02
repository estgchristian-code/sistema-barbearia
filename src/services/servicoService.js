import { supabase } from '../lib/supabase.js';
import { obterProfissionalAutenticado } from './profissionalService.js';

// Colunas retornadas nas listagens/consultas. Nunca incluímos operações que
// permitam alterar id, barbearia_id, created_at ou updated_at.
const CAMPOS_SERVICO = [
  'id',
  'barbearia_id',
  'nome',
  'descricao',
  'preco',
  'duracao_minutos',
  'ativo',
  'created_at',
  'updated_at',
].join(',');

// A barbearia NUNCA vem de campo digitado pelo usuário. Ela é derivada do
// profissional autenticado (profissionais.auth_user_id = auth.uid()).
// Toda consulta é filtrada por este barbearia_id, então o RLS só expõe o
// que o usuário tem direito de ver/gerenciar.
async function obterBarbeariaDoProfissional() {
  const profissional = await obterProfissionalAutenticado();
  if (!profissional) throw new Error('Usuário não está vinculado a uma barbearia.');
  if (!profissional.ativo) throw new Error('Este profissional está inativo.');
  return profissional.barbearia_id;
}

export async function listarServicosDaBarbearia() {
  const barbeariaId = await obterBarbeariaDoProfissional();

  const { data, error } = await supabase
    .from('servicos')
    .select(CAMPOS_SERVICO)
    .eq('barbearia_id', barbeariaId)
    .order('nome', { ascending: true });

  if (error) throw error;
  return data || [];
}

export async function criarServico(dados) {
  const barbeariaId = await obterBarbeariaDoProfissional();

  // barbearia_id é derivado no servidor (via profissional autenticado),
  // jamais vindo de dados enviados pelo frontend.
  const { data, error } = await supabase
    .from('servicos')
    .insert({
      barbearia_id: barbeariaId,
      nome: normalizarTexto(dados.nome),
      descricao: normalizarTextoOpcional(dados.descricao),
      preco: Number(dados.preco),
      duracao_minutos: Number(dados.duracao_minutos),
      ativo: Boolean(dados.ativo),
    })
    .select(CAMPOS_SERVICO)
    .single();

  if (error) throw error;
  return data;
}

export async function atualizarServico(id, dados) {
  const barbeariaId = await obterBarbeariaDoProfissional();

  const { data, error } = await supabase
    .from('servicos')
    .update({
      nome: normalizarTexto(dados.nome),
      descricao: normalizarTextoOpcional(dados.descricao),
      preco: Number(dados.preco),
      duracao_minutos: Number(dados.duracao_minutos),
      ativo: Boolean(dados.ativo),
    })
    .eq('id', id)
    .eq('barbearia_id', barbeariaId) // garante operação só na própria barbearia
    .select(CAMPOS_SERVICO)
    .single();

  if (error) throw error;
  return data;
}

export async function alterarAtivoServico(id, ativo) {
  const barbeariaId = await obterBarbeariaDoProfissional();

  const { data, error } = await supabase
    .from('servicos')
    .update({ ativo: Boolean(ativo) })
    .eq('id', id)
    .eq('barbearia_id', barbeariaId)
    .select(CAMPOS_SERVICO)
    .single();

  if (error) throw error;
  return data;
}

// Mensagem amigável para o erro de nome duplicado (único por barbearia).
export function mensagemErroServico(erro) {
  const mensagem = (erro?.message || '').toLowerCase();
  const codigo = erro?.code;

  // 23505 = unique_violation (uq_servicos_barbearia_nome)
  if (
    codigo === '23505' ||
    mensagem.includes('duplicate key') ||
    mensagem.includes('uq_servicos_barbearia_nome') ||
    mensagem.includes('já existe') ||
    mensagem.includes('already exists')
  ) {
    return 'Já existe um serviço com este nome nesta barbearia.';
  }

  if (codigo === '42501' || mensagem.includes('permission denied') || mensagem.includes('row-level security')) {
    return 'Sem permissão para realizar esta operação. Verifique se você é um administrador ativo desta barbearia.';
  }

  return erro?.message || 'Não foi possível concluir a operação.';
}

function normalizarTexto(texto) {
  return typeof texto === 'string' ? texto.trim() : '';
}

function normalizarTextoOpcional(texto) {
  const v = normalizarTexto(texto);
  return v === '' ? null : v;
}
