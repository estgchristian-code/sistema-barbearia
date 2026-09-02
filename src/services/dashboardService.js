import { supabase } from '../lib/supabase.js';

// Limites do dia de hoje em horário local, como strings ISO.
// data_hora_* é timestamptz; o Supabase/PostgREST compara com ISO corretamente.
function limitesDoDiaAtual() {
  const agora = new Date();
  const inicio = new Date(agora.getFullYear(), agora.getMonth(), agora.getDate());
  const fim = new Date(agora.getFullYear(), agora.getMonth(), agora.getDate() + 1);
  return { inicio: inicio.toISOString(), fim: fim.toISOString() };
}

// Dados da barbearia. O barbearia_id vem do profissional autenticado
// (derivado de profissionais.auth_user_id = auth.uid()), nunca do usuário.
export async function obterBarbearia(barbeariaId) {
  if (!barbeariaId) return null;
  const { data, error } = await supabase
    .from('barbearias')
    .select('id, nome, telefone, endereco')
    .eq('id', barbeariaId)
    .maybeSingle();
  if (error) throw error;
  return data;
}

// Resumo do dashboard, SEM nenhuma escrita (somente leitura via RLS).
// Todos os indicadores são do dia atual, para um painel operacional diário.
export async function obterResumoDashboard(barbeariaId) {
  const { inicio, fim } = limitesDoDiaAtual();

  // Agendamentos do dia, apenas da barbearia do profissional autenticado.
  const { data: agendamentos, error: erroAgendamentos } = await supabase
    .from('agendamentos')
    .select('id, status, data_hora_inicio, servico_id')
    .eq('barbearia_id', barbeariaId)
    .gte('data_hora_inicio', inicio)
    .lt('data_hora_inicio', fim);

  if (erroAgendamentos) throw erroAgendamentos;

  const lista = agendamentos || [];
  const naoCancelados = lista.filter((a) => a.status !== 'cancelado');

  // Faturamento previsto: soma do preço dos serviços dos agendamentos de
  // hoje que não foram cancelados. Busca os preços em servicos (mesma
  // barbearia, permitido por RLS) e soma em memória.
  let faturamento = 0;
  if (naoCancelados.length) {
    const idsServico = [...new Set(naoCancelados.map((a) => a.servico_id))];
    const { data: servicos, error: erroServicos } = await supabase
      .from('servicos')
      .select('id, preco')
      .eq('barbearia_id', barbeariaId)
      .in('id', idsServico);
    if (erroServicos) throw erroServicos;

    const precoPorServico = new Map(
      (servicos || []).map((s) => [s.id, Number(s.preco) || 0])
    );
    faturamento = naoCancelados.reduce(
      (soma, a) => soma + (precoPorServico.get(a.servico_id) || 0),
      0
    );
  }

  return {
    hoje: naoCancelados.length,
    pendentes: lista.filter((a) => a.status === 'pendente').length,
    confirmados: lista.filter((a) => a.status === 'confirmado').length,
    cancelados: lista.length - naoCancelados.length,
    faturamento,
    faturamentoFormatado: formatarMoeda(faturamento),
  };
}

function formatarMoeda(valor) {
  return new Intl.NumberFormat('pt-BR', {
    style: 'currency',
    currency: 'BRL',
  }).format(valor);
}
