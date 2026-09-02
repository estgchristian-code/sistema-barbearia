import { listarHorariosDaBarbearia } from './horarioService.js';
import { listarBloqueiosDoDia } from './bloqueioService.js';

// ===========================================================================
// Disponibilidade real da Agenda interna.
//
// A validação aqui é APENAS de apoio à interface: horário de funcionamento,
// bloqueios e horários passados. A autoridade final sobre conflitos entre
// agendamentos continua sendo o PostgreSQL (ux_agendamentos_sem_conflito),
// tratado pelas mensagens mapeadas em agendamentoService.
// ===========================================================================

function extrairHM(isoHora) {
  // Aceita "08:00" ou "08:00:00".
  const texto = String(isoHora || '');
  const parte = texto.split('T').pop();
  const [h, m] = parte.split(':').map(Number);
  return { h: h || 0, m: m || 0 };
}

function ehSuperiorOuIgual(a, b) {
  return a.h > b.h || (a.h === b.h && a.m >= b.m);
}

// Transforma um horário em minutos desde a meia-noite (para comparar faixas).
function paraMinutos(hm) {
  return hm.h * 60 + hm.m;
}

function horaParaMinutos(strHora) {
  const { h, m } = extrairHM(strHora);
  return paraMinutos({ h, m });
}

// Obtém o registro de horário de funcionamento (ou 'null' se o dia não tiver
// registro configurado — trata como fechado, para segurança).
async function obterHorarioDoDia(data) {
  const horarios = await listarHorariosDaBarbearia();
  const diaSemana = data.getDay();
  return horarios.find((x) => x.dia_semana === diaSemana) || null;
}

// Bloqueios aplicáveis à data e ao barbeiro: bloqueios gerais (barbeiro_id
// NULL) + bloqueios específicos do barbeiro. Reutiliza listarBloqueiosDoDia.
export async function obterBloqueiosAplicaveis(data, barbeiroId) {
  const doDia = await listarBloqueiosDoDia(data);
  return doDia.filter((b) => !b.barbeiro_id || b.barbeiro_id === barbeiroId);
}

// Verifica se o intervalo [inicio, fim] sobrepõe algum bloqueio.
// Retorna o primeiro bloqueio que conflita (ou null).
function bloqueioEmConflito(inicio, fim, bloqueios) {
  const ini = inicio.getTime();
  const f = fim.getTime();
  return bloqueios.find((b) => {
    const bIni = new Date(b.inicio).getTime();
    const bFim = new Date(b.fim).getTime();
    // Sobreposição real: inicio < fimBloqueio E fim > inicioBloqueio.
    return ini < bFim && f > bIni;
  }) || null;
}

// ===========================================================================
// Verificação completa de disponibilidade.
//
// Parâmetros:
//   inicio, fim   — Date (timestamptz local) do intervalo do agendamento.
//   servico       — objeto do serviço (contém duracao_minutos e ativo).
//   barbeiroId    — id do profissional selecionado como barbeiro.
//   ehNovo        — true para novos agendamentos (aplica regra de passado).
//
// Retorna      : { disponivel: true }
//                 ou { disponivel: false, motivo: '<mensagem amigável>' }
// // Lança exceção apenas em falhas de leitura (rede/RLS), não em indisponibilidade.
// ===========================================================================
export async function verificarDisponibilidade({ inicio, fim, servico, barbeiroId, ehNovo = true }) {
  // 1. Serviço ativo com duração válida.
  if (!servico || !servico.ativo) {
    return { disponivel: false, motivo: 'O serviço selecionado é inválido ou está inativo.' };
  }

  // 2. Intervalo mínimo coerente (fim > inicio).
  if (!fim || fim.getTime() <= inicio.getTime()) {
    return { disponivel: false, motivo: 'O horário final deve ser posterior ao inicial.' };
  }

  // Duração do serviço é derivada exclusivamente do registro real.
  const duracaoMinutos = Number(servico.duracao_minutos);
  const fimEsperado = new Date(inicio.getTime() + duracaoMinutos * 60000).getTime();
  if (fimEsperado !== fim.getTime()) {
    return { disponivel: false, motivo: 'A duração do serviço não confere com o horário final.' };
  }

  // 3. Horários passados (somente novos agendamentos).
  if (ehNovo && inicio.getTime() < Date.now()) {
    return { disponivel: false, motivo: 'Não é possível agendar em um horário passado.' };
  }

  // 4. Horário de funcionamento da barbearia para o dia da data inicial.
  const horario = await obterHorarioDoDia(inicio);
  if (!horario || horario.fechado) {
    return { disponivel: false, motivo: 'Barbearia fechada neste dia.' };
  }

  const aberturaMin = horaParaMinutos(horario.hora_abertura);
  const fechamentoMin = horaParaMinutos(horario.hora_fechamento);
  const inicioMin = inicio.getHours() * 60 + inicio.getMinutes();
  const fimMin = fim.getHours() * 60 + fim.getMinutes();

  // 5. Início antes da abertura OU fim depois do fechamento → fora do horário.
  if (inicioMin < aberturaMin || fimMin > fechamentoMin) {
    return { disponivel: false, motivo: 'Este horário está fora do funcionamento da barbearia.' };
  }

  // 6. Bloqueios gerais e específicos do barbeiro.
  const bloqueios = await obterBloqueiosAplicaveis(inicio, barbeiroId);
  if (bloqueioEmConflito(inicio, fim, bloqueios)) {
    return { disponivel: false, motivo: 'Este horário está bloqueado para este barbeiro.' };
  }

  return { disponivel: true };
}
