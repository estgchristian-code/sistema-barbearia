import { supabase } from '../lib/supabase.js';
import { obterProfissionalAutenticado } from './profissionalService.js';

export const DIAS_SEMANA = [
  { dia_semana: 0, rotulo: 'Domingo' },
  { dia_semana: 1, rotulo: 'Segunda' },
  { dia_semana: 2, rotulo: 'Terça' },
  { dia_semana: 3, rotulo: 'Quarta' },
  { dia_semana: 4, rotulo: 'Quinta' },
  { dia_semana: 5, rotulo: 'Sexta' },
  { dia_semana: 6, rotulo: 'Sábado' },
];

async function obterBancoEDados() {
  const profissional = await obterProfissionalAutenticado();
  if (!profissional) throw new Error('Usuário não está vinculado a uma barbearia.');
  if (!profissional.ativo) throw new Error('Este profissional está inativo.');
  return { supabase, barbeariaId: profissional.barbearia_id, cargo: profissional.cargo };
}

// Leitura: todos os dias da própria barbearia (RLS horarios_select_propria).
export async function listarHorariosDaBarbearia() {
  const { supabase, barbeariaId } = await obterBancoEDados();

  const { data, error } = await supabase
    .from('horarios_funcionamento')
    .select('id, barbearia_id, dia_semana, hora_abertura, hora_fechamento, fechado')
    .eq('barbearia_id', barbeariaId)
    .order('dia_semana', { ascending: true });

  if (error) throw error;
  return data || [];
}

// Garante que exista registro para cada um dos 7 dias da barbearia.
// Não cria dados fictícios: apenas os dias que faltam são inseridos de forma
// "fechado" para permitir a edição pela interface. Se todos já existem,
// nada é escrito.
export async function garantirDiasDaBarbearia() {
  const { supabase, barbeariaId } = await obterBancoEDados();

  const existentes = await listarHorariosDaBarbearia();
  const existentesMap = new Map(existentes.map((h) => [h.dia_semana, h]));
  const faltantes = DIAS_SEMANA.filter((d) => !existentesMap.has(d.dia_semana));

  if (!faltantes.length) return existentes;

  const { data, error } = await supabase
    .from('horarios_funcionamento')
    .insert(faltantes.map((d) => ({
      barbearia_id: barbeariaId,
      dia_semana: d.dia_semana,
      hora_abertura: '09:00:00',
      hora_fechamento: '18:00:00',
      fechado: true,
    })))
    .select('id, barbearia_id, dia_semana, hora_abertura, hora_fechamento, fechado');

  if (error) throw error;

  return listarHorariosDaBarbearia();
}

// Atualiza um dia. Só a própria barbearia é alcançada (RLS horarios_write_admin).
export async function atualizarHorario(dia) {
  const erroValidacao = validarHorario(dia);
  if (erroValidacao) throw new Error(erroValidacao);

  const { supabase, barbeariaId } = await obterBancoEDados();

  const { data, error } = await supabase
    .from('horarios_funcionamento')
    .update({
      hora_abertura: dia.hora_abertura,
      hora_fechamento: dia.hora_fechamento,
      fechado: Boolean(dia.fechado),
    })
    .eq('id', dia.id)
    .eq('barbearia_id', barbeariaId)
    .select('id, barbearia_id, dia_semana, hora_abertura, hora_fechamento, fechado')
    .single();

  if (error) throw error;
  return data;
}

// Validação de negócio (defesa em profundidade). Quando o dia está aberto
// (não fechado), abertura e fechamento são obrigatórios e o fechamento deve
// ser posterior à abertura. Quando fechado, os horários são ignorados.
function validarHorario(dia) {
  const fechado = Boolean(dia.fechado);
  if (fechado) return null;

  const abertura = String(dia.hora_abertura || '').trim();
  const fechamento = String(dia.hora_fechamento || '').trim();
  if (!abertura) return 'Informe a hora de abertura.';
  if (!fechamento) return 'Informe a hora de fechamento.';
  if (fechamento <= abertura) return 'O horário de fechamento deve ser posterior ao de abertura.';
  return null;
}

export function mensagemErroHorario(erro) {
  const msg = (erro?.message || '').toLowerCase();
  if (erro?.code === '42501' || msg.includes('permission denied') || msg.includes('row-level security')) {
    return 'Sem permissão para alterar os horários. Somente um administrador da barbearia pode fazer isso.';
  }
  if (msg.includes('chk_horarios_fechamento') || msg.includes('fechamento')) {
    return 'O horário de fechamento deve ser posterior ao de abertura.';
  }
  return erro?.message || 'Não foi possível salvar os horários.';
}
