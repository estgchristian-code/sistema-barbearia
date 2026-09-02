import {
  listarAgendamentosDoDia,
  obterDadosSuporteAgenda,
  criarAgendamento,
  atualizarAgendamento,
  excluirAgendamento,
  mensagemErroAgendamento,
} from '../../services/agendamentoService.js';
import { listarBloqueiosDoDia } from '../../services/bloqueioService.js';
import { verificarDisponibilidade } from '../../services/disponibilidadeService.js';
import { criarElemento, criarCampoFormulario } from '../../lib/dom.js';
import { abrirModal, criarMensagem, abrirModalConfirmacao } from '../../components/modal.js';

const DESCRICAO_STATUS = {
  pendente: 'Pendente',
  confirmado: 'Confirmado',
  concluido: 'Concluído',
  cancelado: 'Cancelado',
};

// Transições permitidas (regra central do banco). O status atual sempre é
// uma opção (permite salvar sem alterar o status). O frontend não oferece
// transições que o banco rejeitaria.
const TRANSICOES = {
  pendente: ['pendente', 'confirmado', 'cancelado'],
  confirmado: ['confirmado', 'concluido', 'cancelado'],
  concluido: ['concluido'],
  cancelado: ['cancelado'],
};

const STATUS_CLASSE = {
  pendente: 'pendente',
  confirmado: 'confirmado',
  concluido: 'concluido',
  cancelado: 'cancelado',
};

const BADGE_STATUS = {
  pendente: 'badge-warning',
  confirmado: 'badge-info',
  concluido: 'badge-success',
  cancelado: 'badge-neutral',
};

export async function renderizarAgenda(conteudo, contexto) {
  const { profissional } = contexto;
  const ehAdmin = profissional?.cargo === 'admin';

  conteudo.innerHTML = '';

  // Estado local
  const dataSelecionada = inicioDoDia(new Date());
  let filtroBarbeiro = '';

  // Dados de suporte (clientes/serviços/profissionais ativos) e agendamentos.
  let suporte;
  try {
    suporte = await obterDadosSuporteAgenda();
  } catch (erro) {
    conteudo.append(criarElemento('p', { class: 'alert alert-danger', text: mensagemErroAgendamento(erro) }));
    return;
  }

  const topo = criarElemento('header', { class: 'page-header' }, [
    criarElemento('div', {}, [
      criarElemento('h1', { text: 'Agenda' }),
      criarElemento('p', { text: 'Acompanhe e gerencie os agendamentos do dia.' }),
    ]),
    criarElemento('div', { class: 'page-header-acoes' }, [
      ehAdmin
        ? criarElemento('button', { type: 'button', class: 'btn btn-primary', id: 'btn-novo-agendamento', text: '+ Novo agendamento' })
        : null,
    ]),
  ]);
  conteudo.append(topo);

  if (!ehAdmin) {
    conteudo.append(
      criarElemento('p', { class: 'alert alert-info', text: 'Somente administradores podem criar, editar ou excluir agendamentos.' })
    );
  }

  // Barra de controle de data + filtro.
  const controles = criarElemento('div', { class: 'agenda-controles' });

  const btnAnterior = criarElemento('button', { type: 'button', class: 'btn btn-ghost btn-sm', text: '←' });
  const btnHoje = criarElemento('button', { type: 'button', class: 'btn btn-ghost btn-sm', text: 'Hoje' });
  const btnProximo = criarElemento('button', { type: 'button', class: 'btn btn-ghost btn-sm', text: '→' });

  const inputData = criarElemento('input', { type: 'date', class: 'field-sm', 'aria-label': 'Data da agenda' });
  inputData.value = formatarDataInput(dataSelecionada);

  const filtroSel = criarElemento('select', { class: 'agenda-filtro field-sm', id: 'filtro-barbeiro', 'aria-label': 'Filtrar por barbeiro' });
  filtroSel.append(criarElemento('option', { value: '', text: 'Todos os barbeiros' }));
  // Somente barbeiros (cargo 'barbeiro') ativos podem receber novos agendamentos.
  for (const p of suporte.profissionais.filter((x) => x.cargo === 'barbeiro' && x.ativo)) {
    filtroSel.append(criarElemento('option', { value: String(p.id), text: p.nome }));
  }

  controles.append(btnAnterior, btnHoje, btnProximo, inputData, filtroSel);
  conteudo.append(controles);

  const lista = criarElemento('div', { id: 'agenda-lista' });
  conteudo.append(lista);

  async function atualizarLista() {
    lista.innerHTML = '';
    lista.append(criarEstado('Carregando agenda…'));

    let agendamentos;
    let bloqueios;
    try {
      [agendamentos, bloqueios] = await Promise.all([
        listarAgendamentosDoDia(dataSelecionada),
        listarBloqueiosDoDia(dataSelecionada),
      ]);
    } catch (erro) {
      lista.innerHTML = '';
      lista.append(criarElemento('p', { class: 'alert alert-danger', text: mensagemErroAgendamento(erro) }));
      return;
    }

    lista.innerHTML = '';
    const dataExibida = criarElemento('p', { class: 'agenda-data-exibida', text: formatarDataLonga(dataSelecionada) });
    if (ehHoje(dataSelecionada)) {
      dataExibida.append(criarElemento('span', { class: 'agenda-data-badge-hoje', text: 'Hoje' }));
    }
    lista.append(dataExibida);

    const filtrarId = filtroBarbeiro ? Number(filtroBarbeiro) : null;
    const doDia = agendamentos.filter((a) => !filtrarId || a.barbeiro_id === filtrarId);

    // Bloqueios do dia, respeitando o filtro de barbeiro (geral = todos).
    const bloqueiosVisiveis = bloqueios.filter((b) => {
      if (!filtrarId) return true;
      if (!b.barbeiro_id) return true; // bloqueio geral vale para todos
      return b.barbeiro_id === filtrarId;
    });

    // Bloqueios aparecem primeiro, sempre diferenciados dos agendamentos.
    for (const b of bloqueiosVisiveis) {
      lista.append(montarCartaoBloqueio(b, suporte.profissionais));
    }

    if (!doDia.length && !bloqueiosVisiveis.length) {
      lista.append(
        criarElemento('div', { class: 'empty-state' }, [
          criarElemento('span', { class: 'empty-state-icone', 'aria-hidden': 'true', text: '📅' }),
          criarElemento('h3', { class: 'empty-state-titulo', text: 'Nenhum agendamento neste dia' }),
          criarElemento('p', { text: ehAdmin ? 'Clique em "+ Novo agendamento" para criar.' : 'Nenhum agendamento para exibir.' }),
        ])
      );
      return;
    }

    for (const a of doDia) {
      lista.append(montarCartaoAgendamento(a, suporte, { ehAdmin, aoEditar, aoExcluir }));
    }
  }

  function aoEditar(agendamento) {
    abrirModalAgendamento({
      agendamento,
      suporte,
      aoSalvar: (dados) => atualizarAgendamento(agendamento.id, dados),
      aoFechar: atualizarLista,
    });
  }

  function aoExcluir(agendamento) {
    abrirModalConfirmacao({
      titulo: 'Excluir registro',
      mensagem: `Excluir definitivamente o agendamento de ${nomePorId(suporte.clientes, agendamento.cliente_id)}? Essa ação não pode ser desfeita.`,
      rotuloConfirmar: 'Excluir',
      variante: 'danger',
      aoConfirmar: async () => {
        try {
          await excluirAgendamento(agendamento.id);
        } catch (erro) {
          throw new Error(mensagemErroAgendamento(erro));
        }
        atualizarLista();
      },
    });
  }

  btnAnterior.addEventListener('click', () => mudarData(-1));
  btnProximo.addEventListener('click', () => mudarData(1));
  btnHoje.addEventListener('click', () => {
    setDataAtual(inicioDoDia(new Date()));
  });
  inputData.addEventListener('change', () => {
    if (inputData.value) setDataAtual(parseDataInput(inputData.value));
  });
  filtroSel.addEventListener('change', () => {
    filtroBarbeiro = filtroSel.value;
    atualizarLista();
  });

  const btnNovo = conteudo.querySelector('#btn-novo-agendamento');
  if (btnNovo) {
    btnNovo.addEventListener('click', () => {
      abrirModalAgendamento({
        agendamento: null,
        suporte,
        dataPadrao: dataSelecionada,
        aoSalvar: criarAgendamento,
        aoFechar: atualizarLista,
      });
    });
  }

  function setDataAtual(novaData) {
    dataSelecionada.setFullYear(novaData.getFullYear(), novaData.getMonth(), novaData.getDate());
    inputData.value = formatarDataInput(dataSelecionada);
    atualizarLista();
  }

  function mudarData(dias) {
    const nova = new Date(dataSelecionada);
    nova.setDate(nova.getDate() + dias);
    setDataAtual(nova);
  }

  await atualizarLista();
}

// ------------------------- Cartão de agendamento -------------------------

function montarCartaoAgendamento(a, suporte, { ehAdmin, aoEditar, aoExcluir }) {
  const cancelado = a.status === 'cancelado';
  const classeStatus = STATUS_CLASSE[a.status] || 'pendente';

  const inicio = new Date(a.data_hora_inicio);
  const fim = new Date(a.data_hora_fim);
  const servico = porId(suporte.servicos, a.servico_id);
  const cliente = porId(suporte.clientes, a.cliente_id);
  const barbeiro = porId(suporte.profissionais, a.barbeiro_id);

  const linhas = [
    criarElemento('span', { class: 'agenda-card-cliente', text: cliente?.nome || `Cliente #${a.cliente_id}` }),
    criarElemento('span', { class: 'agenda-card-servico', text: servico?.nome || `Serviço #${a.servico_id}` }),
  ];
  if (a.observacoes) {
    linhas.push(criarElemento('p', { class: 'agenda-card-obs', text: a.observacoes }));
  }

  const corpo = criarElemento('div', { class: 'agenda-card-corpo' }, linhas);

  const rodape = criarElemento('div', { class: 'agenda-card-rodape' }, [
    criarElemento('span', { class: 'agenda-card-barbeiro', text: `✂ ${barbeiro?.nome || `#${a.barbeiro_id}`}` }),
  ]);

  const acoes = [];
  if (ehAdmin) {
    const btnEditar = criarElemento('button', { type: 'button', class: 'btn btn-ghost btn-sm', text: 'Editar' });
    const btnExcluir = criarElemento('button', { type: 'button', class: 'btn btn-danger btn-sm', text: 'Excluir' });
    btnEditar.addEventListener('click', () => aoEditar(a));
    btnExcluir.addEventListener('click', () => aoExcluir(a));
    acoes.push(btnEditar, btnExcluir);
  }

  const card = criarElemento('article', {
    class: `agenda-card${cancelado ? ' cancelado' : ''} status-${classeStatus}`,
  }, [
    criarElemento('div', { class: 'agenda-card-hora' }, [
      criarElemento('span', { class: 'agenda-card-hora-horario' }, [
        criarElemento('span', { class: 'hora-inicio', text: formatarHora(inicio) }),
        criarElemento('span', { class: 'hora-sep', 'aria-hidden': 'true', text: '→' }),
        criarElemento('span', { class: 'hora-fim', text: formatarHora(fim) }),
      ]),
      criarElemento('span', { class: 'agenda-card-duracao', text: formatarDuracao(servico?.duracao_minutos) }),
    ]),
    corpo,
    criarElemento('div', { class: 'agenda-card-status', 'data-label': 'Status' }, [criarBadgeStatus(a.status)]),
    rodape,
    criarElemento('div', { class: 'agenda-card-acoes' }, acoes),
  ]);

  return card;
}

function criarBadgeStatus(status) {
  return criarElemento('span', {
    class: `badge ${BADGE_STATUS[status] || 'badge-warning'}`,
    text: DESCRICAO_STATUS[status] || status,
  });
}

// Cartão de bloqueio exibido na Agenda (diferente visualmente dos
// agendamentos). Não possui ações: na Etapa 8 o bloqueio só é exibido.
function montarCartaoBloqueio(b, profissionais) {
  const barbeiro = b.barbeiro_id ? porId(profissionais, b.barbeiro_id) : null;
  const rotuloBarbeiro = b.barbeiro_id
    ? (barbeiro ? barbeiro.nome : `#${b.barbeiro_id}`)
    : 'Todos os barbeiros';

  const inicio = new Date(b.inicio);
  const fim = new Date(b.fim);

  return criarElemento('article', {
    class: b.barbeiro_id ? 'agenda-bloqueio especifico' : 'agenda-bloqueio geral',
  }, [
    criarElemento('div', { class: 'agenda-bloqueio-hora' }, [
      criarElemento('span', { text: 'Bloqueio' }),
      criarElemento('strong', { text: `${formatarHora(inicio)} – ${formatarHora(fim)}` }),
    ]),
    criarElemento('div', { class: 'agenda-bloqueio-info' }, [
      criarElemento('span', { class: 'agenda-bloqueio-barbeiro', text: rotuloBarbeiro }),
      b.motivo ? criarElemento('p', { class: 'agenda-bloqueio-motivo', text: b.motivo }) : null,
    ]),
  ]);
}

// ------------------------- Modal de criação/edição -------------------------

function abrirModalAgendamento({ agendamento = null, suporte, dataPadrao, aoSalvar, aoFechar }) {
  const ehEdicao = Boolean(agendamento);

  // Cliente
  const selCliente = criarElemento('select', { name: 'cliente_id', class: 'input', required: true });
  selCliente.append(criarElemento('option', { value: '', text: 'Selecione o cliente…', disabled: true, selected: true }));
  for (const c of suporte.clientes.filter((x) => x.ativo)) {
    selCliente.append(criarElemento('option', { value: String(c.id), text: c.nome }));
  }

  // Barbeiro — somente profissionais com cargo 'barbeiro' e ativo podem
  // receber novos agendamentos. Admins (ex.: Christian) não aparecem aqui.
  const selBarbeiro = criarElemento('select', { name: 'barbeiro_id', class: 'input', required: true });
  selBarbeiro.append(criarElemento('option', { value: '', text: 'Selecione o barbeiro…', disabled: true, selected: true }));
  for (const p of suporte.profissionais.filter((x) => x.cargo === 'barbeiro' && x.ativo)) {
    selBarbeiro.append(criarElemento('option', { value: String(p.id), text: p.nome }));
  }

  // Serviço
  const selServico = criarElemento('select', { name: 'servico_id', class: 'input', required: true });
  selServico.append(criarElemento('option', { value: '', text: 'Selecione o serviço…', disabled: true, selected: true }));
  for (const s of suporte.servicos.filter((x) => x.ativo)) {
    selServico.append(criarElemento('option', { value: String(s.id), text: `${s.nome} (${s.duracao_minutos} min)` }));
  }

  // Data e hora inicial
  const inputData = criarElemento('input', { type: 'date', name: 'data', class: 'input', required: true });

  // Hora inicial e final (calculada — somente leitura)
  const inputHora = criarElemento('input', { type: 'time', name: 'hora_inicio', class: 'input', required: true });
  const inputHoraFim = criarElemento('input', { type: 'time', name: 'hora_fim', class: 'input', readonly: true, placeholder: '—' });

  // Status (somente na edição; na criação é fixo "pendente")
  let selStatus = null;
  let textoStatus = null;
  if (ehEdicao) {
    const opcoes = TRANSICOES[agendamento.status] || [agendamento.status];
    selStatus = criarElemento('select', { name: 'status', class: 'input' });
    for (const s of opcoes) {
      selStatus.append(criarElemento('option', { value: s, text: DESCRICAO_STATUS[s], selected: s === agendamento.status }));
    }
  } else {
    textoStatus = criarElemento('p', { class: 'agenda-status-fixo', text: 'Status do novo agendamento: Pendente' });
  }

  const areaObs = criarElemento('textarea', { name: 'observacoes', rows: 3, class: 'input' });
  if (ehEdicao && agendamento.observacoes) areaObs.value = agendamento.observacoes;

  // Elemento de erro: começa oculto e só aparece quando há mensagem real.
  const msgErro = criarMensagem('danger');

  // Aviso de disponibilidade (dia fechado, fora do horário, bloqueado,
  // passado). Também começa oculto; só aparece quando houver motivo real.
  const avisoDisponibilidade = criarMensagem('warning');

  const form = criarElemento('form', { id: 'form-agendamento' }, [
    criarCampoFormulario('Cliente *', selCliente),
    criarCampoFormulario('Barbeiro *', selBarbeiro),
    criarCampoFormulario('Serviço *', selServico),
    criarElemento('div', { class: 'form-grid' }, [
      criarCampoFormulario('Data *', inputData),
      criarCampoFormulario('Hora inicial *', inputHora),
    ]),
    criarCampoFormulario('Hora final (automática)', inputHoraFim),
    avisoDisponibilidade,
    ehEdicao ? criarCampoFormulario('Status', selStatus) : textoStatus,
    criarCampoFormulario('Observações', areaObs),
    msgErro,
  ]);

  const btnCancelar = criarElemento('button', { type: 'button', class: 'btn btn-secondary', text: 'Cancelar' });
  const btnSalvar = criarElemento('button', {
    type: 'button',
    class: 'btn btn-primary',
    text: ehEdicao ? 'Salvar alterações' : 'Cadastrar agendamento',
  });

  const modal = abrirModal({
    titulo: ehEdicao ? 'Editar agendamento' : 'Novo agendamento',
    tamanho: 'md',
    corpo: [form],
    rodape: [btnCancelar, btnSalvar],
    aoFechar,
  });

  // Pré-preencher na edição.
  if (ehEdicao) {
    selCliente.value = String(agendamento.cliente_id);
    selBarbeiro.value = String(agendamento.barbeiro_id);
    selServico.value = String(agendamento.servico_id);
    inputData.value = formatarDataInput(new Date(agendamento.data_hora_inicio));
    inputHora.value = formatarHora(new Date(agendamento.data_hora_inicio));
  } else if (dataPadrao) {
    inputData.value = formatarDataInput(dataPadrao);
  }

  // Recalcula a hora final (duração real do serviço) e a disponibilidade.
  async function atualizarFormulario() {
    const data = inputData.value;
    const hora = inputHora.value;
    const servico = porId(suporte.servicos, Number(selServico.value));
    inputHoraFim.value = '';
    avisoDisponibilidade.limpar();

    if (!(data && hora && servico)) return;

    const inicio = new Date(`${data}T${hora}:00`);
    if (Number.isNaN(inicio.getTime())) return;

    const fim = new Date(inicio.getTime() + servico.duracao_minutos * 60000);
    inputHoraFim.value = formatarHora(fim);

    // Validação de disponibilidade (dia fechado, fora do horário, bloqueio,
    // passado). Na edição, registros históricos não são bloqueados pela regra
    // de passado (ehNovo = false), mantendo registros existentes editáveis.
    const barbeiroId = Number(selBarbeiro.value) || null;
    const resultado = await verificarDisponibilidade({
      inicio,
      fim,
      servico,
      barbeiroId,
      ehNovo: !ehEdicao,
    });
    if (!resultado.disponivel) {
      avisoDisponibilidade.definir(resultado.motivo);
    }
  }

  selServico.addEventListener('change', atualizarFormulario);
  selBarbeiro.addEventListener('change', atualizarFormulario);
  inputHora.addEventListener('change', atualizarFormulario);
  inputData.addEventListener('change', atualizarFormulario);
  atualizarFormulario();

  async function salvar() {
    msgErro.limpar();

    const dados = montarDadosDoForm();
    const erroValidacao = validarFormulario(dados, ehEdicao, suporte);
    if (erroValidacao) {
      msgErro.definir(erroValidacao);
      return;
    }

    // Disponibilidade (horário de funcionamento, bloqueios, passado) antes da
    // RPC. O banco continua sendo a autoridade final sobre conflitos.
    const servico = porId(suporte.servicos, dados.servico_id);
    const disponibilidade = await verificarDisponibilidade({
      inicio: dados.data_hora_inicio,
      fim: dados.data_hora_fim,
      servico,
      barbeiroId: dados.barbeiro_id,
      ehNovo: !ehEdicao,
    });
    if (!disponibilidade.disponivel) {
      msgErro.definir(disponibilidade.motivo);
      return;
    }

    btnSalvar.disabled = true;
    btnSalvar.textContent = ehEdicao ? 'Salvando…' : 'Cadastrando…';
    try {
      await aoSalvar(dados);
      modal.fechar();
    } catch (erro) {
      msgErro.definir(mensagemErroAgendamento(erro));
      btnSalvar.disabled = false;
      btnSalvar.textContent = ehEdicao ? 'Salvar alterações' : 'Cadastrar agendamento';
    }
  }

  function montarDadosDoForm() {
    const data = inputData.value;
    const hora = inputHora.value;
    const servico = porId(suporte.servicos, Number(selServico.value));
    const inicio = new Date(`${data}T${hora}:00`);
    const fim = servico ? new Date(inicio.getTime() + servico.duracao_minutos * 60000) : new Date(inicio.getTime());

    return {
      cliente_id: Number(selCliente.value),
      barbeiro_id: Number(selBarbeiro.value),
      servico_id: Number(selServico.value),
      data_hora_inicio: inicio,
      data_hora_fim: fim,
      status: ehEdicao ? selStatus.value : 'pendente',
      observacoes: areaObs.value.trim(),
    };
  }

  btnCancelar.addEventListener('click', modal.fechar);
  btnSalvar.addEventListener('click', salvar);
  form.addEventListener('submit', (evento) => {
    evento.preventDefault();
    salvar();
  });
}

// ------------------------- Helpers -------------------------

function validarFormulario(dados, ehEdicao, suporte) {
  if (!dados.cliente_id) return 'Selecione um cliente.';
  if (!dados.barbeiro_id) return 'Selecione um barbeiro.';
  if (!dados.servico_id) return 'Selecione um serviço.';
  if (!dados.data_hora_inicio) return 'Informe data e hora inicial.';

  const servico = porId(suporte.servicos, dados.servico_id);
  const cliente = porId(suporte.clientes, dados.cliente_id);
  const barbeiro = porId(suporte.profissionais, dados.barbeiro_id);

  if (!servico || !servico.ativo) return 'O serviço selecionado é inválido ou está inativo.';
  if (!cliente || !cliente.ativo) return 'O cliente selecionado é inválido ou está inativo.';
  if (!barbeiro || !barbeiro.ativo || barbeiro.cargo !== 'barbeiro') return 'O barbeiro selecionado é inválido ou está inativo.';

  if (dados.data_hora_fim <= dados.data_hora_inicio) {
    return 'O horário final deve ser posterior ao inicial.';
  }

  if (ehEdicao && !dados.status) return 'Informe o status.';

  return null;
}

function inicioDoDia(d) {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate());
}

function formatarHora(data) {
  const h = String(data.getHours()).padStart(2, '0');
  const m = String(data.getMinutes()).padStart(2, '0');
  return `${h}:${m}`;
}

function formatarDataInput(data) {
  const ano = data.getFullYear();
  const mes = String(data.getMonth() + 1).padStart(2, '0');
  const dia = String(data.getDate()).padStart(2, '0');
  return `${ano}-${mes}-${dia}`;
}

function parseDataInput(valor) {
  const [ano, mes, dia] = valor.split('-').map(Number);
  return new Date(ano, mes - 1, dia);
}

function formatarDataLonga(data) {
  return new Intl.DateTimeFormat('pt-BR', {
    weekday: 'long',
    day: 'numeric',
    month: 'long',
    year: 'numeric',
  }).format(data);
}

function ehHoje(data) {
  const agora = new Date();
  return data.getFullYear() === agora.getFullYear()
    && data.getMonth() === agora.getMonth()
    && data.getDate() === agora.getDate();
}

function formatarDuracao(minutos) {
  const n = Number(minutos);
  if (!Number.isFinite(n) || n <= 0) return '';
  const h = Math.floor(n / 60);
  const m = Math.round(n % 60);
  if (h && m) return `${h}h ${m}min`;
  if (h) return `${h}h`;
  return `${m}min`;
}

function porId(lista, id) {
  return lista.find((x) => x.id === id);
}

function nomePorId(lista, id) {
  return porId(lista, id)?.nome || `#${id}`;
}

function criarEstado(texto) {
  return criarElemento('div', { class: 'loading' }, [
    criarElemento('span', { class: 'spinner' }),
    criarElemento('span', { text }),
  ]);
}