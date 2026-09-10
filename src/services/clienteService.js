import { supabase } from '../lib/supabase.js';
import { obterProfissionalAutenticado } from './profissionalService.js';
import { normalizarTelefone, validarTelefoneBrasileiro } from '../lib/validacao.js';

// Re-export das validações de telefone (origem: lib/validacao.js) para manter
// compatibilidade com importações existentes.
export { normalizarTelefone, validarTelefoneBrasileiro };

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
  // Leitura via RPC SECURITY DEFINER: devolve os clientes da PRÓPRIA
  // barbearia do profissional autenticado (admin e barbeiro com a mesma
  // visão), sem ampliar policies/RLS.
  const { data, error } = await supabase.rpc('listar_clientes_da_barbearia');
  if (error) throw error;
  return data || [];
}

export async function criarCliente(dados) {
  const erroValidacao = validarDadosCliente(dados);
  if (erroValidacao) throw new Error(erroValidacao);

  // A criação (admin E barbeiro) passa SOMENTE pela RPC public.criar_cliente:
  // barbearia_id é derivado do auth.uid() no banco — nunca do payload.
  const { data, error } = await supabase.rpc('criar_cliente', {
    p_nome: normalizarTexto(dados.nome, true),
    p_telefone: normalizarTexto(dados.telefone, true),
    p_email: normalizarTextoOpcional(dados.email),
    p_observacoes: normalizarTextoOpcional(dados.observacoes),
    p_ativo: Boolean(dados.ativo),
  });

  if (error) throw error;
  return data;
}

export async function atualizarCliente(id, dados) {
  const erroValidacao = validarDadosCliente(dados);
  if (erroValidacao) throw new Error(erroValidacao);

  const barbeariaId = await obterBarbeariaDoProfissional();

  const { data, error } = await supabase
    .from('clientes')
    .update({
      nome: normalizarTexto(dados.nome, true),
      telefone: normalizarTexto(dados.telefone, true),
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

export async function editarClienteBarbeiro(id, dados) {
  const erroValidacao = validarDadosCliente(dados);
  if (erroValidacao) throw new Error(erroValidacao);

  // Única via de edição do barbeiro: RPC public.editar_cliente (M007).
  // A RPC NÃO aceita p_ativo nem p_barbearia_id: a barbearia é derivada
  // do auth.uid() no banco; ativo e created_at jamais são tocados; o
  // servidor rejeita cliente de outra barbearia.
  const { data, error } = await supabase.rpc('editar_cliente', {
    p_cliente_id: id,
    p_nome: normalizarTexto(dados.nome, true),
    p_telefone: normalizarTexto(dados.telefone, true),
    p_email: normalizarTextoOpcional(dados.email),
    p_observacoes: normalizarTextoOpcional(dados.observacoes),
  });

  if (error) throw error;
  return data;
}

// Validação de negócio única para cadastro e edição de cliente.
// Rejeita nome/telefone vazios, telefone brasileiro inválido e e-mail malformado.
function validarDadosCliente(dados) {
  if (!normalizarTexto(dados.nome, false)) return 'O nome do cliente é obrigatório.';

  const erroTelefone = validarTelefoneBrasileiro(dados.telefone);
  if (erroTelefone) return erroTelefone;

  if (dados.email) {
    const email = normalizarTexto(dados.email, false);
    if (email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      return 'Informe um e-mail válido.';
    }
  }

  return null;
}

export function mensagemErroCliente(erro) {
  const mensagem = (erro?.message || '').toLowerCase();

  if (erro?.code === '42501' || mensagem.includes('permission denied') || mensagem.includes('row-level security')) {
    return 'Sem permissão para realizar esta operação. Verifique se você é um administrador ativo desta barbearia.';
  }

  // Erros de validação/regra da RPC public.criar_cliente (server-side).
  if (mensagem.includes('nome do cliente é obrigatório')) {
    return 'O nome do cliente é obrigatório.';
  }
  if (mensagem.includes('telefone do cliente é obrigatório')) {
    return 'O telefone do cliente é obrigatório.';
  }
  if (mensagem.includes('e-mail inválido')) {
    return 'Informe um e-mail válido.';
  }
  if (mensagem.includes('somente um profissional ativo da barbearia')) {
    return 'Somente um profissional ativo da barbearia pode cadastrar, editar ou listar clientes.';
  }
  if (mensagem.includes('cliente não encontrado ou de outra barbearia')) {
    return 'Cliente não encontrado ou pertence a outra barbearia.';
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
