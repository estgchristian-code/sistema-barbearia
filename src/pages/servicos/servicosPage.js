import {
  listarServicosDaBarbearia,
  criarServico,
  atualizarServico,
  alterarAtivoServico,
  mensagemErroServico,
} from '../../services/servicoService.js';
import { criarElemento, textoClaro, criarCampoFormulario } from '../../lib/dom.js';
import { abrirModal, criarMensagem } from '../../components/modal.js';
import { toastSucesso, toastErro } from '../../components/toast.js';

function formatarMoeda(valor) {
  return new Intl.NumberFormat('pt-BR', {
    style: 'currency',
    currency: 'BRL',
  }).format(Number(valor) || 0);
}

export async function renderizarServicos(conteudo, contexto) {
  const { profissional } = contexto;
  const somenteLeitura = profissional?.cargo !== 'admin';

  conteudo.innerHTML = '';

  const cabecalho = criarElemento('header', { class: 'page-header' }, [
    criarElemento('div', {}, [
      criarElemento('h1', { text: 'Serviços' }),
      criarElemento('p', { text: 'Cadastre e gerencie os serviços oferecidos pela barbearia.' }),
    ]),
    criarElemento('div', { class: 'page-header-acoes' }, [
      somenteLeitura
        ? null
        : criarElemento('button', {
            type: 'button',
            class: 'btn btn-primary',
            id: 'btn-novo-servico',
            text: '+ Novo serviço',
          }),
    ]),
  ]);
  conteudo.append(cabecalho);

  if (somenteLeitura) {
    conteudo.append(
      criarElemento('p', {
        class: 'alert alert-info',
        text: 'Somente administradores podem cadastrar, editar ou ativar/desativar serviços.',
      })
    );
  }

  const lista = criarElemento('div', { id: 'servicos-lista' });
  conteudo.append(lista);

  // Listener registrado antes do carregamento (padrão Agenda): o botão
  // continua funcional mesmo se o carregamento de dados demorar ou falhar.
  conteudo.querySelector('#btn-novo-servico')?.addEventListener('click', () => {
    abrirFormularioModal({
      somenteLeitura,
      aposSalvar: () => carregarServicos(lista, { somenteLeitura }),
    });
  });

  await carregarServicos(lista, { somenteLeitura });
}

async function carregarServicos(lista, { somenteLeitura }) {
  lista.innerHTML = '';
  lista.append(criarEstado('Carregando serviços…'));

  let servicos;
  try {
    servicos = await listarServicosDaBarbearia();
  } catch (erro) {
    lista.innerHTML = '';
    lista.append(criarElemento('p', { class: 'alert alert-danger', text: mensagemErroServico(erro) }));
    return;
  }

  lista.innerHTML = '';

  if (!servicos.length) {
    lista.append(
      criarElemento('div', { class: 'empty-state' }, [
        criarElemento('span', { class: 'empty-state-icone', 'aria-hidden': 'true', text: '✂' }),
        criarElemento('h3', { class: 'empty-state-titulo', text: 'Nenhum serviço cadastrado ainda' }),
        criarElemento('p', { text: 'Clique em "+ Novo serviço" para começar.' }),
      ])
    );
    return;
  }

  const tabela = criarElemento('table', { class: 'table' });
  const thead = criarElemento('thead', {}, [
    criarElemento('tr', {}, [
      criarElemento('th', { text: 'Nome' }),
      criarElemento('th', { text: 'Descrição' }),
      criarElemento('th', { class: 'num', text: 'Preço' }),
      criarElemento('th', { class: 'num', text: 'Duração' }),
      criarElemento('th', { text: 'Status' }),
      criarElemento('th', { class: 'acoes', text: 'Ações' }),
    ]),
  ]);
  const tbody = criarElemento('tbody');
  for (const servico of servicos) {
    tbody.append(
      criarElemento('tr', {}, [
        criarElemento('td', { 'data-label': 'Nome', text: textoClaro(servico.nome) }),
        criarElemento('td', { 'data-label': 'Descrição', text: textoClaro(servico.descricao) || '—' }),
        criarElemento('td', { class: 'num', 'data-label': 'Preço', text: formatarMoeda(servico.preco) }),
        criarElemento('td', { class: 'num', 'data-label': 'Duração', text: `${textoClaro(servico.duracao_minutos)} min` }),
        criarElemento('td', { 'data-label': 'Status' }, [criarBadgeStatus(servico.ativo)]),
        criarElemento('td', { class: 'acoes', 'data-label': 'Ações' }, [
          criarElemento('div', { class: 'acao-cel' }, montarAcoes(servico, { somenteLeitura })),
        ]),
      ])
    );
  }
  tabela.append(thead, tbody);
  lista.append(criarElemento('div', { class: 'table-wrap' }, [tabela]));

  tbody.querySelectorAll('button[data-edit-id]').forEach((btn) => {
    btn.addEventListener('click', () => {
      const id = Number(btn.dataset.editId);
      const servico = servicos.find((s) => s.id === id);
      if (servico) {
        abrirFormularioModal({
          somenteLeitura,
          servico,
          aposSalvar: () => carregarServicos(lista, { somenteLeitura }),
        });
      }
    });
  });

  tbody.querySelectorAll('[data-toggle-id]').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const id = Number(btn.dataset.toggleId);
      const novoAtivo = btn.dataset.ativo !== 'true';
      btn.disabled = true;
      try {
        await alterarAtivoServico(id, novoAtivo);
        await carregarServicos(lista, { somenteLeitura });
      } catch (erro) {
        btn.disabled = false;
        toastErro(mensagemErroServico(erro));
      }
    });
  });
}

function montarAcoes(servico, { somenteLeitura }) {
  if (somenteLeitura) return [criarElemento('span', { text: '—' })];
  const toggle = criarElemento('button', {
    type: 'button',
    class: 'btn btn-ghost btn-sm',
    'data-toggle-id': String(servico.id),
    'data-ativo': servico.ativo ? 'true' : 'false',
    text: servico.ativo ? 'Desativar' : 'Ativar',
  });
  const editar = criarElemento('button', {
    type: 'button',
    class: 'btn btn-secondary btn-sm',
    'data-edit-id': String(servico.id),
    text: 'Editar',
  });
  return [editar, toggle];
}

function criarBadgeStatus(ativo) {
  return criarElemento('span', {
    class: ativo ? 'badge badge-success' : 'badge badge-neutral',
    text: ativo ? 'Ativo' : 'Inativo',
  });
}

function criarEstado(texto) {
  return criarElemento('div', { class: 'loading' }, [
    criarElemento('span', { class: 'spinner' }),
    criarElemento('span', { text }),
  ]);
}

function toastNegar(mensagem) {
  criarElemento; // (placeholder — toast de erro importado abaixo)
}

// ------------------------- Formulário em modal -------------------------
function abrirFormularioModal({ servico = null, aposSalvar }) {
  const ehEdicao = Boolean(servico);
  const msgErro = criarMensagem('danger');

  const inputNome = criarElemento('input', {
    type: 'text',
    name: 'nome',
    class: 'input',
    value: textoClaro(servico?.nome),
    required: true,
    maxlength: 200,
    placeholder: 'Ex.: Corte de cabelo',
  });

  const inputDescricao = criarElemento('textarea', {
    name: 'descricao',
    class: 'input',
    rows: 3,
  });
  if (servico?.descricao) inputDescricao.value = textoClaro(servico.descricao);

  const inputPreco = criarElemento('input', {
    type: 'text',
    name: 'preco',
    class: 'input',
    inputmode: 'decimal',
    required: true,
    placeholder: '0,00',
  });
  if (servico?.preco !== null && servico?.preco !== undefined) {
    inputPreco.value = String(servico.preco).replace('.', ',');
  }

  const inputDuracao = criarElemento('input', {
    type: 'number',
    name: 'duracao_minutos',
    class: 'input',
    required: true,
    min: 1,
    step: 1,
    placeholder: '30',
  });
  if (servico?.duracao_minutos !== null && servico?.duracao_minutos !== undefined) {
    inputDuracao.value = String(servico.duracao_minutos);
  }

  const inputAtivo = criarElemento('input', { type: 'checkbox', name: 'ativo' });
  if (servico) {
    if (servico.ativo) inputAtivo.setAttribute('checked', '');
  } else {
    inputAtivo.setAttribute('checked', '');
  }

  const form = criarElemento('form', { id: 'form-servico' }, [
    criarCampoFormulario('Nome *', inputNome),
    criarCampoFormulario('Descrição', inputDescricao),
    criarElemento('div', { class: 'form-grid' }, [
      criarCampoFormulario('Preço (R$) *', inputPreco),
      criarCampoFormulario('Duração (minutos) *', inputDuracao),
    ]),
    criarElemento('label', { class: 'form-linha' }, [
      inputAtivo,
      criarElemento('span', { text: 'Ativo' }),
    ]),
  ]);
  form.append(msgErro);

  const btnCancelar = criarElemento('button', { type: 'button', class: 'btn btn-secondary', text: 'Cancelar' });
  const btnSalvar = criarElemento('button', {
    type: 'button',
    class: 'btn btn-primary',
    text: ehEdicao ? 'Salvar alterações' : 'Cadastrar serviço',
  });

  const modal = abrirModal({
    titulo: ehEdicao ? 'Editar serviço' : 'Novo serviço',
    tamanho: 'md',
    corpo: [form],
    rodape: [btnCancelar, btnSalvar],
  });

  async function salvar() {
    msgErro.limpar();
    const precoBruto = inputPreco.value.trim();
    const dados = {
      nome: inputNome.value.trim(),
      descricao: inputDescricao.value.trim(),
      preco: precoBruto.replace(',', '.'),
      duracao_minutos: inputDuracao.value,
      ativo: inputAtivo.checked,
    };

    const erroValidacao = validarDados(dados);
    if (erroValidacao) {
      msgErro.definir(erroValidacao);
      return;
    }

    btnSalvar.disabled = true;
    btnSalvar.textContent = ehEdicao ? 'Salvando…' : 'Cadastrando…';
    try {
      if (ehEdicao) {
        await atualizarServico(servico.id, dados);
      } else {
        await criarServico(dados);
      }
      toastSucesso(ehEdicao ? 'Serviço atualizado com sucesso.' : 'Serviço cadastrado com sucesso.');
      modal.fechar();
      if (typeof aposSalvar === 'function') aposSalvar();
    } catch (erro) {
      msgErro.definir(mensagemErroServico(erro));
      btnSalvar.disabled = false;
      btnSalvar.textContent = ehEdicao ? 'Salvar alterações' : 'Cadastrar serviço';
    }
  }

  btnCancelar.addEventListener('click', modal.fechar);
  btnSalvar.addEventListener('click', salvar);
  form.addEventListener('submit', (evento) => {
    evento.preventDefault();
    salvar();
  });
}

function validarDados(dados) {
  if (!dados.nome) return 'O nome do serviço é obrigatório.';

  const preco = Number(String(dados.preco).replace(' ', ''));
  if (dados.preco === '' || Number.isNaN(preco)) return 'Informe um preço válido.';
  if (preco < 0) return 'O preço não pode ser negativo.';

  const duracao = Number(dados.duracao_minutos);
  if (String(dados.duracao_minutos).trim() === '' || Number.isNaN(duracao)) {
    return 'Informe a duração em minutos.';
  }
  if (duracao <= 0) return 'A duração deve ser maior que zero.';
  if (!Number.isInteger(duracao)) return 'A duração deve ser um número inteiro.';

  return null;
}