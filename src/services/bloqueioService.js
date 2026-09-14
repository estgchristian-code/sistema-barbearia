import { supabase } from '../lib/supabase.js';
import { obterProfissionalAutenticado } from './profissionalService.js';

async function obterBarbeariaDoProfissional() {
  const profissional = await obterProfissionalAutenticado();
  if (!profissional) throw new Error('Usuário não está vinculado a uma barbearia.');
  if (!profissional.ativo) throw new Error('Este profissional está inativo.');
  return profissional.barbearia_id;
}

const CAMPOS = 'id, barbearia_id, barbeiro_id, inicio, fim, motivo, recorrencia_dias, recorrencia_fim, created_at, updated_at';

// Leitura: bloqueios da própria barbearia (RLS bloqueios_select_propria),
// ordenados pelo início.
export async function listarBloqueiosDaBarbearia() {
  const barbeariaId = await obterBarbeariaDoProfissional();

  const { data, error } = await supabase
    .from('bloqueios_agenda')
    .select(CAMPOS)
    .eq('barbearia_id', barbeariaId)
    .order('inicio', { ascending: true });

  if (error) throw error;
  return data || [];
}

function formatarDataLocal(data) {
  const ano = data.getFullYear();
  const mes = String(data.getMonth() + 1).padStart(2, '0');
  const dia = String(data.getDate()).padStart(2, '0');
  return `${ano}-${mes}-${dia}`;
}

// Bloqueios que se aplicam a um determinado dia (para exibição na Agenda e
// para a checagem de disponibilidade):
//   * PONTUAIS  (recorrencia_dias NULL)  — sobrepõem o dia (inicio < fimDia
//     E fim > inicioDia), como antes;
//   * RECORRENTES (recorrencia_dias preenchido) — valem naquele dia se o dia
//     da semana está na lista E recorrencia_fim ainda não expirou.
export async function listarBloqueiosDoDia(data) {
  const dia = data instanceof Date ? data : new Date(data);
  const inicioDia = new Date(dia.getFullYear(), dia.getMonth(), dia.getDate());
  const fimDia = new Date(dia.getFullYear(), dia.getMonth(), dia.getDate() + 1);
  const dataLocal = formatarDataLocal(dia);
  const barbeariaId = await obterBarbeariaDoProfissional();

  const [pontuais, recorrentes] = await Promise.all([
    supabase
      .from('bloqueios_agenda')
      .select(CAMPOS)
      .eq('barbearia_id', barbeariaId)
      .is('recorrencia_dias', null)
      .lt('inicio', fimDia.toISOString())
      .gt('fim', inicioDia.toISOString())
      .order('inicio', { ascending: true }),
    supabase
      .from('bloqueios_agenda')
      .select(CAMPOS)
      .eq('barbearia_id', barbeariaId)
      .not('recorrencia_dias', 'is', null)
      .or(`recorrencia_fim.is.null,recorrencia_fim.gte.${dataLocal}`)
      .order('inicio', { ascending: true }),
  ]);

  if (pontuais.error) throw pontuais.error;
  if (recorrentes.error) throw recorrentes.error;

  // Recorrentes que valem ESPECIFICAMENTE naquele dia da semana.
  const diaSemana = dia.getDay();
  const recorrentesDoDia = (recorrentes.data || []).filter(
    (b) => Array.isArray(b.recorrencia_dias) && b.recorrencia_dias.includes(diaSemana)
  );

  // Junta os dois grupos sem duplicar (mesmo id) e ordena pelo início.
  const mapa = new Map();
  for (const b of [...(pontuais.data || []), ...recorrentesDoDia]) mapa.set(b.id, b);
  return [...mapa.values()].sort((a, b) => new Date(a.inicio) - new Date(b.inicio));
}

// Cria um bloqueio. barbeiro_id NULL = bloqueio geral ("Todos os barbeiros").
// barbeiro_id é sempre derivado da lista de profissionais da própria barbearia
// no frontend; nunca aceitamos barbearia_id vindo de campo do usuário.
// recorrencia_dias: array de dias (0..6) para bloqueio RECORRENTE; vazio/null
// = bloqueio PONTUAL. recorrencia_fim: última data ('YYYY-MM-DD' ou null).
export async function criarBloqueio(dados) {
  const erroValidacao = validarDadosBloqueio(dados);
  if (erroValidacao) throw new Error(erroValidacao);

  const barbeariaId = await obterBarbeariaDoProfissional();

  const { data, error } = await supabase
    .from('bloqueios_agenda')
    .insert({
      barbearia_id: barbeariaId,
      barbeiro_id: dados.barbeiro_id || null,
      inicio: dados.inicio.toISOString(),
      fim: dados.fim.toISOString(),
      motivo: dados.motivo || null,
      recorrencia_dias: dados.recorrencia_dias?.length ? dados.recorrencia_dias : null,
      recorrencia_fim: dados.recorrencia_fim || null,
    })
    .select(CAMPOS)
    .single();

  if (error) throw error;
  return data;
}

export async function atualizarBloqueio(id, dados) {
  const erroValidacao = validarDadosBloqueio(dados);
  if (erroValidacao) throw new Error(erroValidacao);

  const barbeariaId = await obterBarbeariaDoProfissional();

  const { data, error } = await supabase
    .from('bloqueios_agenda')
    .update({
      barbeiro_id: dados.barbeiro_id || null,
      inicio: dados.inicio.toISOString(),
      fim: dados.fim.toISOString(),
      motivo: dados.motivo || null,
      recorrencia_dias: dados.recorrencia_dias?.length ? dados.recorrencia_dias : null,
      recorrencia_fim: dados.recorrencia_fim || null,
    })
    .eq('id', id)
    .eq('barbearia_id', barbeariaId)
    .select(CAMPOS)
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

// Validação de negócio (defesa em profundidade): início e fim devem ser datas
// válidas e o fim deve ser posterior ao início. A regra de "início futuro" é
// tratada na interface (novo bloqueio) e não entra aqui para não impedir
// edições de registros históricos.
// Para bloqueios RECORRENTES, também valida os dias da semana e o "Repetir até".
function validarDadosBloqueio(dados) {
  const inicio = dados.inicio;
  const fim = dados.fim;

  if (!(inicio instanceof Date) || Number.isNaN(inicio.getTime())) {
    return 'Informe a data e a hora de início.';
  }
  if (!(fim instanceof Date) || Number.isNaN(fim.getTime())) {
    return 'Informe a data e a hora de fim.';
  }
  if (fim <= inicio) return 'O horário de fim deve ser posterior ao horário de início.';

  const dias = dados.recorrencia_dias;
  if (dias && dias.length) {
    if (!dias.every((d) => Number.isInteger(d) && d >= 0 && d <= 6)) {
      return 'Os dias da semana selecionados são inválidos.';
    }
    if (dados.recorrencia_fim) {
      const fimRec = dados.recorrencia_fim instanceof Date
        ? dados.recorrencia_fim
        : new Date(`${dados.recorrencia_fim}T00:00:00`);
      if (Number.isNaN(fimRec.getTime())) return 'Data "Repetir até" inválida.';
      if (fimRec.getTime() < new Date(`${formatarDataLocalFromDate(inicio)}T00:00:00`).getTime()) {
        return '"Repetir até" deve ser a partir da data inicial do bloqueio.';
      }
    }
  }

  return null;
}

function formatarDataLocalFromDate(data) {
  const ano = data.getFullYear();
  const mes = String(data.getMonth() + 1).padStart(2, '0');
  const dia = String(data.getDate()).padStart(2, '0');
  return `${ano}-${mes}-${dia}`;
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
  if (msg.includes('chk_bloqueios_recorrencia_dias')) {
    return 'Selecione de 1 a 7 dias da semana, válidos (domingo a sábado).';
  }
  if (msg.includes('chk_bloqueios_recorrencia_fim')) {
    return '"Repetir até" deve ser uma data a partir da data inicial do bloqueio.';
  }
  return erro?.message || 'Não foi possível concluir a operação.';
}
