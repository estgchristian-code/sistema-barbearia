import { supabase } from '../lib/supabase.js';
import { obterProfissionalAutenticado } from './profissionalService.js';

async function obterBarbeariaDoProfissional() {
  const profissional = await obterProfissionalAutenticado();
  if (!profissional) throw new Error('Usuário não está vinculado a uma barbearia.');
  if (!profissional.ativo) throw new Error('Este profissional está inativo.');
  return profissional.barbearia_id;
}

// Leitura: bloqueios da própria barbearia (RLS bloqueios_select_propria),
// ordenados pelo início.
export async function listarBloqueiosDaBarbearia() {
  const barbeariaId = await obterBarbeariaDoProfissional();

  const { data, error } = await supabase
    .from('bloqueios_agenda')
    .select('id, barbearia_id, barbeiro_id, inicio, fim, motivo, created_at, updated_at')
    .eq('barbearia_id', barbeariaId)
    .order('inicio', { ascending: true });

  if (error) throw error;
  return data || [];
}

// Bloqueios que sobrepõem um determinado dia (para exibição na Agenda).
// A seleção por barbearia + intervalo (inicio < fimDoDia E fim > inicioDoDia)
// representa qualquer sobreposição com o dia.
export async function listarBloqueiosDoDia(data) {
  const dia = data instanceof Date ? data : new Date(data);
  const inicioDia = new Date(dia.getFullYear(), dia.getMonth(), dia.getDate());
  const fimDia = new Date(dia.getFullYear(), dia.getMonth(), dia.getDate() + 1);
  const barbeariaId = await obterBarbeariaDoProfissional();

  const { data: bloqueios, error } = await supabase
    .from('bloqueios_agenda')
    .select('id, barbearia_id, barbeiro_id, inicio, fim, motivo')
    .eq('barbearia_id', barbeariaId)
    .lt('inicio', fimDia.toISOString())
    .gt('fim', inicioDia.toISOString())
    .order('inicio', { ascending: true });

  if (error) throw error;
  return bloqueios || [];
}

// Cria um bloqueio. barbeiro_id NULL = bloqueio geral ("Todos os barbeiros").
// barbeiro_id é sempre derivado da lista de profissionais da própria barbearia
// no frontend; nunca aceitamos barbearia_id vindo de campo do usuário.
export async function criarBloqueio(dados) {
  const barbeariaId = await obterBarbeariaDoProfissional();

  const { data, error } = await supabase
    .from('bloqueios_agenda')
    .insert({
      barbearia_id: barbeariaId,
      barbeiro_id: dados.barbeiro_id || null,
      inicio: dados.inicio.toISOString(),
      fim: dados.fim.toISOString(),
      motivo: dados.motivo || null,
    })
    .select('id, barbearia_id, barbeiro_id, inicio, fim, motivo')
    .single();

  if (error) throw error;
  return data;
}

export async function atualizarBloqueio(id, dados) {
  const barbeariaId = await obterBarbeariaDoProfissional();

  const { data, error } = await supabase
    .from('bloqueios_agenda')
    .update({
      barbeiro_id: dados.barbeiro_id || null,
      inicio: dados.inicio.toISOString(),
      fim: dados.fim.toISOString(),
      motivo: dados.motivo || null,
    })
    .eq('id', id)
    .eq('barbearia_id', barbeariaId)
    .select('id, barbearia_id, barbeiro_id, inicio, fim, motivo')
    .single();

  if (error) throw error;
  return data;
}

export async function excluirBloqueio(id) {
  const barbeariaId = await obterBarbeariaDoProfissional();

  const { error } = await supabase
    .from('bloqueios_agenda')
    .delete()
    .eq('id', id)
    .eq('barbearia_id', barbeariaId);

  if (error) throw error;
}

export function mensagemErroBloqueio(erro) {
  const msg = (erro?.message || '').toLowerCase();
  if (erro?.code === '42501' || msg.includes('permission denied') || msg.includes('row-level security')) {
    return 'Sem permissão para alterar os bloqueios. Somente um administrador da barbearia pode fazer isso.';
  }
  if (erro?.code === '23503' || msg.includes('fk_bloqueios_barbeiro_barbearia')) {
    return 'O barbeiro selecionado é inválido ou não pertence a esta barbearia.';
  }
  if (msg.includes('chk_bloqueios_intervalo') || msg.includes('fim > início')) {
    return 'O fim do bloqueio deve ser posterior ao início.';
  }
  return erro?.message || 'Não foi possível concluir a operação.';
}
