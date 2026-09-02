import { supabase } from '../lib/supabase.js';
import { obterProfissionalAutenticado } from './profissionalService.js';

const CAMPOS_AGENDAMENTO = [
  'id',
  'barbearia_id',
  'cliente_id',
  'barbeiro_id',
  'servico_id',
  'data_hora_inicio',
  'data_hora_fim',
  'status',
  'observacoes',
].join(',');

// A barbearia NUNCA vem do frontend. É derivada do profissional autenticado
// (profissionais.auth_user_id = auth.uid()). Nas RPCs o valor é repassado e
// VALIDADO internamente (usuario_e_admin_da_barbearia), e na leitura tudo é
// filtrado por este barbearia_id, respeitando o RLS.
async function obterContexto() {
  const profissional = await obterProfissionalAutenticado();
  if (!profissional) throw new Error('Usuário não está vinculado a uma barbearia.');
  if (!profissional.ativo) throw new Error('Este profissional está inativo.');
  return { barbeariaId: profissional.barbearia_id, cargo: profissional.cargo };
}

// ------------------------- LEITURA (SELECT respeitando RLS) -------------------------

export async function listarAgendamentosPorPeriodo(dataInicio, dataFim) {
  const { barbeariaId } = await obterContexto();

  const { data, error } = await supabase
    .from('agendamentos')
    .select(CAMPOS_AGENDAMENTO)
    .eq('barbearia_id', barbeariaId)
    .gte('data_hora_inicio', dataInicio)
    .lt('data_hora_inicio', dataFim)
    .order('data_hora_inicio', { ascending: true });

  if (error) throw error;
  return data || [];
}

// 'data' é a string/Date da data selecionada (dia local). Devolve os
// agendamentos cujo data_hora_inicio cai nesse dia, já ordenados.
export async function listarAgendamentosDoDia(data) {
  const dia = data instanceof Date ? data : new Date(data);
  const inicio = new Date(dia.getFullYear(), dia.getMonth(), dia.getDate());
  const fim = new Date(dia.getFullYear(), dia.getMonth(), dia.getDate() + 1);
  return listarAgendamentosPorPeriodo(inicio.toISOString(), fim.toISOString());
}

// Dados de suporte dos formulários: clientes, serviços e profissionais ATIVOS
// da própria barbearia. Nenhuma lista fixa em JavaScript.
export async function obterDadosSuporteAgenda() {
  const { barbeariaId } = await obterContexto();

  const [clientes, servicos, profissionais] = await Promise.all([
    supabase
      .from('clientes')
      .select('id, nome, telefone, ativo')
      .eq('barbearia_id', barbeariaId)
      .order('nome', { ascending: true }),
    supabase
      .from('servicos')
      .select('id, nome, preco, duracao_minutos, ativo')
      .eq('barbearia_id', barbeariaId)
      .order('nome', { ascending: true }),
    supabase
      .from('profissionais')
      .select('id, nome, cargo, ativo')
      .eq('barbearia_id', barbeariaId)
      .order('nome', { ascending: true }),
  ]);

  for (const r of [clientes, servicos, profissionais]) {
    if (r.error) throw r.error;
  }

  return {
    clientes: clientes.data || [],
    servicos: servicos.data || [],
    profissionais: profissionais.data || [],
  };
}

// ------------------------- ESCRITA (somente via RPC) -------------------------

// RPC: admin_criar_agendamento. O status é sempre 'pendente' na criação
// (o banco REJEITA qualquer outro status em admin_criar_agendamento).
export async function criarAgendamento(dados) {
  const erroValidacao = validarDadosAgendamento(dados);
  if (erroValidacao) throw new Error(erroValidacao);

  const { barbeariaId } = await obterContexto();

  const { data, error } = await supabase.rpc('admin_criar_agendamento', {
    p_barbearia_id: barbeariaId,
    p_barbeiro_id: dados.barbeiro_id,
    p_servico_id: dados.servico_id,
    p_cliente_id: dados.cliente_id,
    p_data_hora_inicio: dados.data_hora_inicio.toISOString(),
    p_data_hora_fim: dados.data_hora_fim.toISOString(),
    p_status: null,
    p_observacoes: dados.observacoes || null,
  });

  if (error) throw error;
  return data;
}

// RPC: admin_atualizar_agendamento. A transição de status é validada no banco
// a partir do status ANTERIOR da linha.
export async function atualizarAgendamento(id, dados) {
  const erroValidacao = validarDadosAgendamento(dados);
  if (erroValidacao) throw new Error(erroValidacao);

  const { data, error } = await supabase.rpc('admin_atualizar_agendamento', {
    p_agendamento_id: id,
    p_barbeiro_id: dados.barbeiro_id,
    p_servico_id: dados.servico_id,
    p_cliente_id: dados.cliente_id,
    p_data_hora_inicio: dados.data_hora_inicio.toISOString(),
    p_data_hora_fim: dados.data_hora_fim.toISOString(),
    p_status: dados.status,
    p_observacoes: dados.observacoes || null,
  });

  if (error) throw error;
  return data;
}

// RPC: admin_excluir_agendamento (exclusão física administrativa).
export async function excluirAgendamento(id) {
  const { error } = await supabase.rpc('admin_excluir_agendamento', {
    p_agendamento_id: id,
  });
  if (error) throw error;
}

// RPC: barbeiro_atualizar_status. Permite ao barbeiro alterar SOMENTE
// status e observacoes dos PRÓPRIOS agendamentos.
export async function barbeiroAtualizarStatus(id, novoStatus, novasObservacoes) {
  const { data, error } = await supabase.rpc('barbeiro_atualizar_status', {
    p_agendamento_id: id,
    p_novo_status: novoStatus,
    p_novas_observacoes: novasObservacoes ?? null,
  });

  if (error) throw error;
  return data;
}

// Validação de negócio comum a criação e edição (defesa em profundidade antes
// da RPC). O banco continua sendo a autoridade final sobre conflitos e
// transições de status; aqui barramos dados claramente inconsistentes.
function validarDadosAgendamento(dados) {
  if (!dados.barbeiro_id) return 'Selecione um barbeiro.';
  if (!dados.servico_id) return 'Selecione um serviço.';
  if (!dados.cliente_id) return 'Selecione um cliente.';

  const inicio = dados.data_hora_inicio;
  const fim = dados.data_hora_fim;
  if (!(inicio instanceof Date) || Number.isNaN(inicio.getTime())) {
    return 'Informe data e hora inicial válidas.';
  }
  if (!(fim instanceof Date) || Number.isNaN(fim.getTime())) {
    return 'Informe data e hora final válidas.';
  }
  if (fim <= inicio) return 'O horário final deve ser posterior ao inicial.';

  return null;
}

// ------------------------- Erros amigáveis -------------------------

export function mensagemErroAgendamento(erro) {  const msg = (erro?.message || '').toLowerCase();
  const codigo = erro?.code;

  // 23P01 = exclusion_violation (ux_agendamentos_sem_conflito).
  if (
    codigo === '23P01' ||
    msg.includes('ux_agendamentos_sem_conflito') ||
    msg.includes('conflicting key value') ||
    msg.includes('overlap')
  ) {
    return 'Esse horário já está ocupado para este barbeiro.';
  }

  if (
    msg.includes('transição de status inválida') ||
    (codigo === 'P0001' && msg.includes('status'))
  ) {
    return 'Transição de status inválida para este agendamento.';
  }

  if (msg.includes('deve iniciar com status pendente')) {
    return 'Um novo agendamento deve iniciar com status "pendente".';
  }

  if (msg.includes('somente admin') || msg.includes('administrador')) {
    return 'Somente um administrador desta barbearia pode realizar esta operação.';
  }

  if (msg.includes('somente um barbeiro ativo')) {
    return 'Somente um barbeiro ativo pode alterar o status de seus agendamentos.';
  }

  if (msg.includes('não encontrado') || msg.includes('pertence a outra barbearia')) {
    return 'Agendamento não encontrado ou não pertence a esta barbearia.';
  }

  if (codigo === '42501' || msg.includes('permission denied') || msg.includes('row-level security')) {
    return 'Sem permissão para realizar esta operação.';
  }

  // 23503 = foreign_key_violation (cliente/servico/barbeiro inexistente ou de outra barbearia).
  if (
    codigo === '23503' ||
    msg.includes('fk_agendamentos_cliente') ||
    msg.includes('fk_agendamentos_servico') ||
    msg.includes('fk_agendamentos_barbeiro')
  ) {
    return 'Cliente, serviço ou barbeiro inválido. Verifique se são ativos e pertencem a esta barbearia.';
  }

  return erro?.message || 'Não foi possível concluir a operação.';
}
