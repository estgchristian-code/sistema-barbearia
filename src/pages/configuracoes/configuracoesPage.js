import {
  DIAS_SEMANA,
  garantirDiasDaBarbearia,
  atualizarHorario,
  mensagemErroHorario,
} from '../../services/horarioService.js';
import {
  listarBloqueiosDaBarbearia,
  criarBloqueio,
  atualizarBloqueio,
  excluirBloqueio,
  mensagemErroBloqueio,
} from '../../services/bloqueioService.js';
import { listarProfissionaisDaBarbearia } from '../../services/profissionalService.js';
import { criarElemento, criarCampoFormulario, criarEstado } from '../../lib/dom.js';
import { abrirModal, criarMensagem, abrirModalConfirmacao } from '../../components/modal.js';

export async function renderizarConfiguracoes(conteudo, contexto) {
  const { profissional } = contexto;
  const ehAdmin = profissional?.cargo === 'admin';

  conteudo.innerHTML = '';

  const cabecalho = criarElemento('header', { class: 'page-header' }, [
    criarElemento('div', {}, [
      criarElemento('h1', { text: 'Configurações' }),
      criarElemento('p', { text: 'Gerencie os horários de funcionamento e os bloqueios da agenda.' }),
    ]),
  ]);
  conteudo.append(cabecalho);

  if (!ehAdmin) {
    conteudo.append(
      criarElemento('p', { class: 'alert alert-info', text: 'Somente administradores podem alterar horários e bloqueios. Você está vendo em modo leitura.' })
    );
  }

  const secaoHorarios = criarElemento('section', { class: 'config-secao' });
  const secaoBloqueios = criarElemento('section', { class: 'config-secao' });
  conteudo.append(secaoHorarios, secaoBloqueios);

  // Horários e Bloqueios carregam de forma independente: uma seção nunca
  // bloqueia a renderização da outra.
  await Promise.all([
    renderizarHorarios(secaoHorarios, { ehAdmin }),
    renderizarBloqueios(secaoBloqueios, { ehAdmin }),
  ]);

  // Abas ligadas APÓS o render: os botões .config-aba só existem depois que
  // renderizarHorarios os cria. Ligá-los antes resultava em nenhum listener.
  conteudo.querySelectorAll('.config-aba').forEach((aba) => {
    aba.addEventListener('click', () => {
      const alvo = aba.dataset.alvo;
      secaoHorarios.classList.toggle('oculto', alvo !== 'horarios');
      secaoBloqueios.classList.toggle('oculto', alvo !== 'bloqueios');
      conteudo.querySelectorAll('.config-aba').forEach((a) => a.classList.toggle('ativo', a === aba));
    });
  });
}

// ------------------------- HORÁRIOS DE FUNCIONAMENTO -------------------------

async function renderizarHorarios(secao, { ehAdmin }) {
  const titulo = criarElemento('div', { class: 'config-secao-titulo' }, [
    criarElemento('h2', { text: 'Horários de funcionamento' }),
  ]);
  const abas = criarElemento('div', { class: 'config-abas' }, [
    criarElemento('button', { type: 'button', class: 'config-aba ativo', 'data-alvo': 'horarios', text: 'Horários' }),
    criarElemento('button', { type: 'button', class: 'config-aba', 'data-alvo': 'bloqueios', text: 'Bloqueios' }),
  ]);
  const area = criarElemento('div');
  secao.append(abas, titulo, area);

  // Dias com estado padrão para montar a estrutura imediatamente, antes de o
  // carregamento dos dados chegar.
  const diasPadrao = DIAS_SEMANA.map((d) => ({
    id: null,
    dia_semana: d.dia_semana,
    hora_abertura: '09:00:00',
    hora_fechamento: '18:00:00',
    fechado: true,
  }));

  function montarGrade(dias) {
    area.innerHTML = '';
    const grade = criarElemento('div', { class: 'horarios-grade' });
    for (const dia of dias) {
      grade.append(montarLinhaDia(dia, { ehAdmin, aoSalvar }));
    }
    area.append(grade);
  }

  async function aoSalvar(dia) {
    return atualizarHorario(dia);
  }

  // A estrutura dos 7 dias é sempre renderizada, mesmo enquanto os dados
  // carregam ou se a consulta falhar.
  montarGrade(diasPadrao);

  let horarios;
  try {
    horarios = await garantirDiasDaBarbearia();
  } catch (erro) {
    area.prepend(criarElemento('p', { class: 'alert alert-danger', text: mensagemErroHorario(erro) }));
    return;
  }

  // Preenche os dias com os valores reais assim que os dados chegam.
  const porDia = new Map(horarios.map((h) => [h.dia_semana, h]));
  montarGrade(diasPadrao.map((d) => porDia.get(d.dia_semana) || d));
}

function montarLinhaDia(dia, { ehAdmin, aoSalvar }) {
  const info = DIAS_SEMANA.find((d) => d.dia_semana === dia.dia_semana) || { rotulo: `Dia ${dia.dia_semana}` };

  const chkAberto = criarElemento('input', { type: 'checkbox' });
  chkAberto.checked = !dia.fechado;

  const inputAbertura = criarElemento('input', { type: 'time', class: 'input' });
  const inputFechamento = criarElemento('input', { type: 'time', class: 'input' });
  if (dia.hora_abertura) inputAbertura.value = dia.hora_abertura.slice(0, 5);
  if (dia.hora_fechamento) inputFechamento.value = dia.hora_fechamento.slice(0, 5);

  const chkRotulo = criarElemento('label', { class: 'horario-aberto-rotulo' }, [chkAberto, criarElemento('span', { text: 'Aberto' })]);

  const linha = criarElemento('div', { class: 'horario-linha' }, [
    criarElemento('span', { class: 'horario-dia', text: info.rotulo }),
    chkRotulo,
    criarElemento('label', { class: 'horario-campo' }, [criarElemento('span', { text: 'Abertura' }), inputAbertura]),
    criarElemento('label', { class: 'horario-campo' }, [criarElemento('span', { text: 'Fechamento' }), inputFechamento]),
  ]);

  const btnSalvar = criarElemento('button', { type: 'button', class: 'btn btn-primary btn-sm', text: 'Salvar' });
  const msg = criarElemento('span', { class: 'horario-msg' });
  const acoes = criarElemento('div', { class: 'horario-acoes' }, [msg, btnSalvar]);
  linha.append(acoes);

  function sincronizarEstado() {
    const aberto = chkAberto.checked;
    inputAbertura.disabled = !aberto;
    inputFechamento.disabled = !aberto;
  }
  sincronizarEstado();

  chkAberto.addEventListener('change', sincronizarEstado);

  btnSalvar.addEventListener('click', async () => {
    if (!dia.id) {
      msg.textContent = 'Aguardando o carregamento dos dados. Tente novamente.';
      return;
    }

    msg.textContent = '';
    btnSalvar.disabled = true;
    btnSalvar.textContent = 'Salvando…';

    const dados = {
      id: dia.id,
      fechado: !chkAberto.checked,
      hora_abertura: chkAberto.checked ? inputAbertura.value : dia.hora_abertura,
      hora_fechamento: chkAberto.checked ? inputFechamento.value : dia.hora_fechamento,
    };

    if (chkAberto.checked) {
      const erro = validarHorario(inputAbertura.value, inputFechamento.value);
      if (erro) {
        msg.textContent = erro;
        btnSalvar.disabled = false;
        btnSalvar.textContent = 'Salvar';
        return;
      }
    }

    try {
      const atualizado = await aoSalvar(dados);
      dia.hora_abertura = atualizado.hora_abertura;
      dia.hora_fechamento = atualizado.hora_fechamento;
      dia.fechado = atualizado.fechado;
      msg.textContent = 'Salvo.';
      msg.classList.add('ok');
      setTimeout(() => {
        msg.textContent = '';
        msg.classList.remove('ok');
      }, 2500);
    } catch (erro) {
      msg.textContent = mensagemErroHorario(erro);
    } finally {
      btnSalvar.disabled = false;
      btnSalvar.textContent = 'Salvar';
    }
  });

  if (!ehAdmin) {
    chkAberto.disabled = true;
    inputAbertura.disabled = true;
    inputFechamento.disabled = true;
    btnSalvar.disabled = true;
    btnSalvar.textContent = 'Somente admin';
  }

  return linha;
}

function validarHorario(abertura, fechamento) {
  if (!abertura) return 'Informe a hora de abertura.';
  if (!fechamento) return 'Informe a hora de fechamento.';
  if (fechamento <= abertura) return 'O fechamento deve ser posterior à abertura.';
  return null;
}

// ------------------------- BLOQUEIOS DE AGENDA -------------------------

async function renderizarBloqueios(secao, { ehAdmin }) {
  const bloco = criarElemento('div');
  secao.append(bloco);

  await carregarBloqueios(bloco, { ehAdmin });
}

async function carregarBloqueios(bloco, { ehAdmin }) {
  bloco.innerHTML = '';
  const estado = criarEstado('Carregando bloqueios…');
  bloco.append(estado);

  const cabecalho = criarElemento('div', { class: 'bloqueios-cabecalho' }, [
    criarElemento('div', { class: 'config-secao-titulo' }, [criarElemento('h2', { text: 'Bloqueios de agenda' })]),
    ehAdmin
      ? criarElemento('button', { type: 'button', class: 'btn btn-primary', id: 'btn-novo-bloqueio', text: '+ Novo bloqueio' })
      : null,
  ]);
  bloco.append(cabecalho);

  // Listeners registrados antes do carregamento (padrão Agenda): o botão
  // continua funcional mesmo se o carregamento de dados demorar ou falhar.
  let ativos = [];
  const btnNovo = cabecalho.querySelector('#btn-novo-bloqueio');
  if (btnNovo) {
    btnNovo.addEventListener('click', () => {
      abrirModalBloqueio({
        bloqueio: null,
        profissionais: ativos,
        aoSalvar: criarBloqueio,
        aoFechar: () => carregarBloqueios(bloco, { ehAdmin }),
      });
    });
  }

  let bloqueios;
  let profissionais;
  try {
    [bloqueios, profissionais] = await Promise.all([
      listarBloqueiosDaBarbearia(),
      listarProfissionaisDaBarbearia(),
    ]);
  } catch (erro) {
    estado.remove();
    bloco.append(criarElemento('p', { class: 'alert alert-danger', text: mensagemErroBloqueio(erro) }));
    return;
  }

  estado.remove();

  ativos = (profissionais || []).filter((p) => p.ativo);

  const lista = criarElemento('div');
  bloco.append(lista);

  if (!bloqueios.length) {
    lista.append(
      criarElemento('div', { class: 'empty-state' }, [
        criarElemento('span', { class: 'empty-state-icone', 'aria-hidden': 'true', text: '🚧' }),
        criarElemento('h3', { class: 'empty-state-titulo', text: 'Nenhum bloqueio' }),
        criarElemento('p', { text: ehAdmin ? 'Clique em "+ Novo bloqueio" para começar.' : 'Nenhum bloqueio para exibir.' }),
      ])
    );
  } else {
    for (const b of bloqueios) {
      lista.append(montarCartaoBloqueio(b, ativos, { ehAdmin, aoEditar, aoExcluir }));
    }
  }

  function aoEditar(bloqueio) {
    abrirModalBloqueio({
      bloqueio,
      profissionais: ativos,
      aoSalvar: (dados) => atualizarBloqueio(bloqueio.id, dados),
      aoFechar: () => carregarBloqueios(bloco, { ehAdmin }),
    });
  }

  async function aoExcluir(bloqueio) {
    abrirModalConfirmacao({
      titulo: 'Remover bloqueio',
      mensagem: `Remover o bloqueio de ${formatarPeriodo(bloqueio) || 'período'}?`,
      rotuloConfirmar: 'Remover',
      variante: 'danger',
      aoConfirmar: async () => {
        try {
          await excluirBloqueio(bloqueio.id);
        } catch (erro) {
          throw new Error(mensagemErroBloqueio(erro));
        }
        carregarBloqueios(bloco, { ehAdmin });
      },
    });
  }
}

function montarCartaoBloqueio(bloqueio, profissionais, { ehAdmin, aoEditar, aoExcluir }) {
  const barbeiro = bloqueio.barbeiro_id
    ? profissionais.find((p) => p.id === bloqueio.barbeiro_id)
    : null;

  const rotuloBarbeiro = bloqueio.barbeiro_id
    ? (barbeiro ? barbeiro.nome : `Profissional #${bloqueio.barbeiro_id}`)
    : 'Todos os barbeiros';

  const acoes = [];
  if (ehAdmin) {
    const btnEditar = criarElemento('button', { type: 'button', class: 'btn btn-ghost btn-sm', text: 'Editar' });
    const btnExcluir = criarElemento('button', { type: 'button', class: 'btn btn-danger btn-sm', text: 'Remover' });
    btnEditar.addEventListener('click', () => aoEditar(bloqueio));
    btnExcluir.addEventListener('click', () => aoExcluir(bloqueio));
    acoes.push(btnEditar, btnExcluir);
  }

  const card = criarElemento('article', {
    class: bloqueio.barbeiro_id ? 'bloqueio-card especifico' : 'bloqueio-card geral',
  }, [
    criarElemento('div', { class: 'bloqueio-card-periodo' }, [
      criarElemento('strong', { text: formatarDatetime(bloqueio.inicio) }),
      criarElemento('span', { text: 'até' }),
      criarElemento('strong', { text: formatarDatetime(bloqueio.fim) }),
    ]),
    criarElemento('div', { class: 'bloqueio-card-info' }, [
      criarElemento('span', {
        class: bloqueio.barbeiro_id ? 'badge badge-info' : 'badge badge-neutral',
        text: rotuloBarbeiro,
      }),
      bloqueio.motivo ? criarElemento('p', { class: 'bloqueio-card-motivo', text: bloqueio.motivo }) : null,
    ]),
    criarElemento('div', { class: 'bloqueio-card-acoes' }, acoes),
  ]);

  return card;
}

// ------------------------- Modal de bloqueio -------------------------

function abrirModalBloqueio({ bloqueio = null, profissionais, aoSalvar, aoFechar }) {
  const ehEdicao = Boolean(bloqueio);
  const msgErro = criarMensagem('danger');

  const selBarbeiro = criarElemento('select', { name: 'barbeiro_id', class: 'input' });
  selBarbeiro.append(criarElemento('option', { value: '', text: 'Todos os barbeiros' }));
  for (const p of profissionais) {
    selBarbeiro.append(criarElemento('option', { value: String(p.id), text: p.nome }));
  }

  const areaMotivo = criarElemento('textarea', { name: 'motivo', rows: 3, class: 'input', placeholder: 'Motivo do bloqueio (opcional)' });

  // Data/hora separadas (evita o problema do ano de 5 dígitos do datetime-local).
  const campoTempoInicio = criarCampoDataHora('Início *', 'inicio', 'inicio');
  const campoTempoFim = criarCampoDataHora('Fim *', 'fim', 'fim');

  // O início não pode estar no passado: define o min de hoje (mas também
  // há validação em JavaScript, que é a autoridade real).
  campoTempoInicio.data.min = formatarDataInput(new Date());

  if (ehEdicao) {
    if (bloqueio.barbeiro_id) selBarbeiro.value = String(bloqueio.barbeiro_id);
    parcDataHora(campoTempoInicio, new Date(bloqueio.inicio));
    parcDataHora(campoTempoFim, new Date(bloqueio.fim));
    if (bloqueio.motivo) areaMotivo.value = bloqueio.motivo;
  }

  const form = criarElemento('form', { id: 'form-bloqueio' }, [
    criarCampoFormulario('Barbeiro (opcional)', selBarbeiro),
    campoTempoInicio.wrapper,
    campoTempoFim.wrapper,
    criarCampoFormulario('Motivo', areaMotivo),
    msgErro,
  ]);

  const btnCancelar = criarElemento('button', { type: 'button', class: 'btn btn-secondary', text: 'Cancelar' });
  const btnSalvar = criarElemento('button', {
    type: 'button',
    class: 'btn btn-primary',
    text: ehEdicao ? 'Salvar alterações' : 'Criar bloqueio',
  });

  const modal = abrirModal({
    titulo: ehEdicao ? 'Editar bloqueio' : 'Novo bloqueio',
    tamanho: 'md',
    corpo: [form],
    rodape: [btnCancelar, btnSalvar],
    aoFechar,
  });

  async function salvar() {
    msgErro.limpar();

    const barbeiroId = selBarbeiro.value ? Number(selBarbeiro.value) : null;

    const inicioCombinado = combinarDataHora(campoTempoInicio);
    const fimCombinado = combinarDataHora(campoTempoFim);
    if (inicioCombinado.erro) {
      msgErro.definir(`Início: ${inicioCombinado.erro}`);
      return;
    }
    if (fimCombinado.erro) {
      msgErro.definir(`Fim: ${fimCombinado.erro}`);
      return;
    }
    const inicio = inicioCombinado.date;
    const fim = fimCombinado.date;

    const erro = validarBloqueio({ barbeiroId, inicio, fim, motivo: areaMotivo.value.trim() }, profissionais);
    if (erro) {
      msgErro.definir(erro);
      return;
    }

    btnSalvar.disabled = true;
    btnSalvar.textContent = ehEdicao ? 'Salvando…' : 'Criando…';
    try {
      await aoSalvar({ barbeiro_id: barbeiroId, inicio, fim, motivo: areaMotivo.value.trim() });
      modal.fechar();
    } catch (e) {
      msgErro.definir(mensagemErroBloqueio(e));
      btnSalvar.disabled = false;
      btnSalvar.textContent = ehEdicao ? 'Salvar alterações' : 'Criar bloqueio';
    }
  }

  btnCancelar.addEventListener('click', modal.fechar);
  btnSalvar.addEventListener('click', salvar);
  form.addEventListener('submit', (evento) => {
    evento.preventDefault();
    salvar();
  });
}

function validarBloqueio({ barbeiroId, inicio, fim, motivo }, profissionais) {
  if (!inicio || !inputValido(inicio)) return 'Informe a data e a hora de início.';
  if (!fim || !inputValido(fim)) return 'Informe a data e a hora de fim.';

  // O início deve ser futuro (não pode começar no passado).
  const agora = new Date();
  if (inicio <= agora) return 'O início do bloqueio deve estar no futuro.';

  if (fim <= inicio) return 'O horário de fim deve ser posterior ao horário de início.';

  if (barbeiroId) {
    const selecionado = profissionais.find((p) => p.id === barbeiroId);
    if (!selecionado || !selecionado.ativo) {
      return 'O barbeiro selecionado é inválido ou está inativo.';
    }
  }

  return null;
}

function inputValido(data) {
  return data instanceof Date && !Number.isNaN(data.getTime());
}

// ------------------------- Helpers -------------------------

function formatarDatetime(iso) {
  return new Intl.DateTimeFormat('pt-BR', {
    day: '2-digit',
    month: '2-digit',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  }).format(new Date(iso));
}

function formatarPeriodo(bloqueio) {
  if (!bloqueio) return '';
  return formatarDatetime(bloqueio.inicio);
}

// Cria os campos separados de data + hora para um dos extremos do bloqueio.
// Retorna { wrapper, data, hora } para uso na montagem e leitura.
function criarCampoDataHora(rotulo, prefixoData, prefixoHora) {
  const inputData = criarElemento('input', {
    type: 'date',
    name: prefixoData,
    class: 'input',
    required: true,
    'aria-label': `${rotulo} — data`,
  });
  const inputHora = criarElemento('input', {
    type: 'time',
    name: prefixoHora,
    class: 'input',
    required: true,
    'aria-label': `${rotulo} — hora`,
  });

  const campos = criarElemento('div', { class: 'form-grid' }, [inputData, inputHora]);
  const wrapper = criarCampoFormulario(rotulo, campos);

  return { wrapper, data: inputData, hora: inputHora };
}

// Preenche data + hora a partir de um objeto Date (na edição).
function parcDataHora({ data, hora }, valorDate) {
  if (!inputValido(valorDate)) return;
  data.value = formatarDataInput(valorDate);
  hora.value = formatarHoraInput(valorDate);
}

// Junta data + hora num Date local. Retorna null se algum campo estiver
// vazio ou inválido. Valida o ano com exatamente 4 dígitos.
// Retorna { date, erro } — quando data/hora inválidas, date fica null.
function combinarDataHora({ data, hora }) {
  const valorData = data.value.trim();
  const valorHora = hora.value.trim();

  if (!valorData) return { date: null, erro: 'Informe a data.' };
  if (!valorHora) return { date: null, erro: 'Informe a hora.' };

  const validoAno = /^\d{4}$/.test(valorData.slice(0, 4));
  if (!validoAno) return { date: null, erro: 'O ano da data deve ter exatamente 4 dígitos.' };

  // O próprio construtor de Date valida datas inválidas (ex.: 2026-13-45).
  return { date: new Date(`${valorData}T${valorHora}:00`), erro: null };
}

function formatarDataInput(data) {
  const ano = data.getFullYear();
  const mes = String(data.getMonth() + 1).padStart(2, '0');
  const dia = String(data.getDate()).padStart(2, '0');
  return `${ano}-${mes}-${dia}`;
}

function formatarHoraInput(data) {
  const hora = String(data.getHours()).padStart(2, '0');
  const min = String(data.getMinutes()).padStart(2, '0');
  return `${hora}:${min}`;
}

