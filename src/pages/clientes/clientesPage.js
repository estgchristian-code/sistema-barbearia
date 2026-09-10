import {
  listarClientesDaBarbearia,
  criarCliente,
  atualizarCliente,
  alterarAtivoCliente,
  editarClienteBarbeiro,
  mensagemErroCliente,
  validarTelefoneBrasileiro,
} from '../../services/clienteService.js';
import { criarElemento, criarCampoFormulario, criarEstado } from '../../lib/dom.js';
import { abrirModal, criarMensagem } from '../../components/modal.js';
import { toastSucesso } from '../../components/toast.js';

export async function renderizarClientes(conteudo, contexto) {
  const { profissional } = contexto;
  const permiteCriar = profissional?.cargo === 'admin' || profissional?.cargo === 'barbeiro';
  const permiteGerenciar = profissional?.cargo === 'admin';

  conteudo.innerHTML = '';

  const cabecalho = criarElemento('header', { class: 'page-header' }, [
    criarElemento('div', {}, [
      criarElemento('h1', { text: 'Clientes' }),
      criarElemento('p', { text: 'Cadastre e gerencie os clientes da barbearia.' }),
    ]),
    criarElemento('div', { class: 'page-header-acoes' }, [
      permiteCriar
        ? criarElemento('button', {
            type: 'button',
            class: 'btn btn-primary',
            id: 'btn-novo-cliente',
            text: '+ Novo cliente',
          })
        : null,
    ]),
  ]);
  conteudo.append(cabecalho);

  // Caixa de busca (nome, telefone ou e-mail).
  const busca = criarElemento('div', { class: 'page-tools' }, [
    criarElemento('input', {
      type: 'search',
      id: 'busca-clientes',
      class: 'input',
      placeholder: 'Buscar por nome, telefone ou e-mail…',
      'aria-label': 'Buscar clientes',
    }),
  ]);
  conteudo.append(busca);

  const lista = criarElemento('div', { id: 'clientes-lista' });
  conteudo.append(lista);

  // Listener registrado antes do carregamento (padrão Agenda): o botão
  // continua funcional mesmo se o carregamento de dados demorar ou falhar.
  const btnNovo = conteudo.querySelector('#btn-novo-cliente');
  if (btnNovo) {
    btnNovo.addEventListener('click', () => {
      abrirFormularioModal({
        aposSalvar: () => carregarClientes(lista, { permiteGerenciar, filtro: '' }),
        // Barbeiro cadastra sempre como ativo (não tem poder administrativo).
        permiteGerenciar,
      });
    });
  }

  let todosClientes = await carregarClientes(lista, { permiteGerenciar, filtro: '' });

  const campoBusca = conteudo.querySelector('#busca-clientes');
  campoBusca.addEventListener('input', () => {
    todosClientes = carregarClientes(lista, { permiteGerenciar, filtro: campoBusca.value.trim() });
  });
}

function montarFiltrados(clientes, filtro) {
  const termo = filtro.toLowerCase();
  if (!termo) return clientes;
  return clientes.filter(
    (c) =>
      (c.nome || '').toLowerCase().includes(termo) ||
      (c.telefone || '').toLowerCase().includes(termo) ||
      (c.email || '').toLowerCase().includes(termo)
  );
}

async function carregarClientes(lista, { permiteGerenciar, filtro }) {
  lista.innerHTML = '';
  lista.append(criarEstado('Carregando clientes…'));

  let clientes;
  try {
    clientes = await listarClientesDaBarbearia();
  } catch (erro) {
    lista.innerHTML = '';
    lista.append(criarElemento('p', { class: 'alert alert-danger', text: mensagemErroCliente(erro) }));
    return [];
  }

  lista.innerHTML = '';

  const filtrados = montarFiltrados(clientes, filtro);

  if (!filtrados.length) {
    const haTodos = clientes.length > 0;
    lista.append(
      criarElemento('div', { class: 'empty-state' }, [
        criarElemento('span', { class: 'empty-state-icone', 'aria-hidden': 'true', text: '👤' }),
        criarElemento('h3', { class: 'empty-state-titulo', text: haTodos ? 'Nenhum cliente encontrado' : 'Nenhum cliente cadastrado ainda' }),
        criarElemento('p', { text: haTodos ? 'Tente outro termo de busca.' : 'Clique em "+ Novo cliente" para começar.' }),
      ])
    );
    return clientes;
  }

  const tabela = criarElemento('table', { class: 'table' });
  const thead = criarElemento('thead', {}, [
    criarElemento('tr', {}, [
      criarElemento('th', { text: 'Nome' }),
      criarElemento('th', { text: 'Telefone' }),
      criarElemento('th', { text: 'E-mail' }),
      criarElemento('th', { text: 'Observações' }),
      criarElemento('th', { text: 'Status' }),
      criarElemento('th', { class: 'acoes', text: 'Ações' }),
    ]),
  ]);
  const tbody = criarElemento('tbody');
  for (const cliente of filtrados) {
    tbody.append(
      criarElemento('tr', {}, [
        criarElemento('td', { 'data-label': 'Nome', text: cliente.nome }),
        criarElemento('td', { 'data-label': 'Telefone', text: cliente.telefone || '—' }),
        criarElemento('td', { 'data-label': 'E-mail', text: cliente.email || '—' }),
        criarElemento('td', { 'data-label': 'Observações', text: cliente.observacoes || '—' }),
        criarElemento('td', { 'data-label': 'Status' }, [criarBadgeStatus(cliente.ativo)]),
        criarElemento('td', { class: 'acoes', 'data-label': 'Ações' }, [
          criarElemento('div', { class: 'acao-cel' }, montarAcoes(cliente, { permiteGerenciar })),
        ]),
      ])
    );
  }
  tabela.append(thead, tbody);
  lista.append(criarElemento('div', { class: 'table-wrap' }, [tabela]));

  tbody.querySelectorAll('button[data-edit-id]').forEach((btn) => {
    btn.addEventListener('click', () => {
      const id = Number(btn.dataset.editId);
      const cliente = filtrados.find((c) => c.id === id);
      if (cliente) {
        abrirFormularioModal({
          cliente,
          aposSalvar: () => carregarClientes(lista, { permiteGerenciar, filtro: '' }),
          permiteGerenciar,
        });
      }
    });
  });
  tbody.querySelectorAll('[data-toggle-id]').forEach((btn) => {
    btn.addEventListener('click', async (e) => {
      const alvo = e.currentTarget;
      const id = Number(alvo.dataset.toggleId);
      const novoAtivo = alvo.dataset.ativo === 'true' ? false : true;
      alvo.disabled = true;
      try {
        await alterarAtivoCliente(id, novoAtivo);
        await carregarClientes(lista, { permiteGerenciar, filtro });
      } catch (erro) {
        alvo.disabled = false;
        avisarErro(lista, mensagemErroCliente(erro));
      }
    });
  });

  return clientes;
}

function montarAcoes(cliente, { permiteGerenciar }) {
  // Barbeiro EDITA clientes (RPC editar_cliente, somente os 4 campos),
  // mas NÃO ativa/desativa (exclusivo do admin).
  if (!permiteGerenciar) {
    const editar = criarElemento('button', {
      type: 'button',
      class: 'btn btn-secondary btn-sm',
      'data-edit-id': String(cliente.id),
      text: 'Editar',
    });
    return [editar];
  }
  const toggle = criarElemento('button', {
    type: 'button',
    class: 'btn btn-ghost btn-sm',
    'data-toggle-id': String(cliente.id),
    'data-ativo': cliente.ativo ? 'true' : 'false',
    text: cliente.ativo ? 'Desativar' : 'Ativar',
  });
  const editar = criarElemento('button', {
    type: 'button',
    class: 'btn btn-secondary btn-sm',
    'data-edit-id': String(cliente.id),
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

// ------------------------- Formulário (cadastro/edição) em modal -------------------------

function abrirFormularioModal({ cliente = null, aposSalvar, permiteGerenciar = false }) {
  const ehEdicao = Boolean(cliente);
  const msgErro = criarMensagem('danger');

  const inputNome = criarElemento('input', {
    type: 'text',
    name: 'nome',
    class: 'input',
    value: cliente?.nome || '',
    required: true,
    maxlength: 200,
  });
  const inputTelefone = criarElemento('input', {
    type: 'text',
    name: 'telefone',
    class: 'input',
    value: cliente?.telefone || '',
    required: true,
    maxlength: 30,
    placeholder: '(41) 99999-9999',
  });
  const inputEmail = criarElemento('input', {
    type: 'email',
    name: 'email',
    class: 'input',
    value: cliente?.email || '',
    maxlength: 200,
    placeholder: 'cliente@exemplo.com',
  });
  const areaObservacoes = criarElemento('textarea', { name: 'observacoes', class: 'input', rows: 3 });
  if (cliente?.observacoes) areaObservacoes.value = cliente.observacoes;

  const inputAtivo = criarElemento('input', { type: 'checkbox', name: 'ativo' });
  if (cliente ? cliente.ativo : true) inputAtivo.setAttribute('checked', '');

  const itensForm = [
    criarCampoFormulario('Nome *', inputNome),
    criarElemento('div', { class: 'form-grid' }, [
      criarCampoFormulario('Telefone *', inputTelefone),
      criarCampoFormulario('E-mail', inputEmail),
    ]),
    criarCampoFormulario('Observações', areaObservacoes),
  ];
  // Barbeiro (sem poder administrativo) nunca vê o campo Ativo: edita/cria
  // sempre como ativo; o servidor reforça via RPC criar_cliente/editar_cliente.
  if (permiteGerenciar) {
    itensForm.push(
      criarElemento('label', { class: 'form-linha' }, [
        inputAtivo,
        criarElemento('span', { text: 'Ativo' }),
      ])
    );
  }

  const form = criarElemento('form', { id: 'form-cliente' }, itensForm);
  form.append(msgErro);

  const btnCancelar = criarElemento('button', { type: 'button', class: 'btn btn-secondary', text: 'Cancelar' });
  const btnSalvar = criarElemento('button', {
    type: 'button',
    class: 'btn btn-primary',
    text: ehEdicao ? 'Salvar alterações' : 'Cadastrar cliente',
  });

  const modal = abrirModal({
    titulo: ehEdicao ? 'Editar cliente' : 'Novo cliente',
    tamanho: 'md',
    corpo: [form],
    rodape: [btnCancelar, btnSalvar],
  });

  async function salvar() {
    msgErro.limpar();

    const dados = {
      nome: inputNome.value.trim(),
      telefone: inputTelefone.value.trim(),
      email: inputEmail.value.trim(),
      observacoes: areaObservacoes.value.trim(),
      // Barbeiro (sem o campo no form) é sempre ativo; o servidor reforça.
      ativo: permiteGerenciar ? inputAtivo.checked : true,
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
        if (permiteGerenciar) {
          // Admin: mantém o comportamento atual (update direto, inclui ativo).
          await atualizarCliente(cliente.id, dados);
        } else {
          // Barbeiro: edita SOMENTE os 4 campos pela RPC editar_cliente
          // (ativo/created_at nunca são alterados pelo servidor).
          await editarClienteBarbeiro(cliente.id, dados);
        }
        toastSucesso('Cliente atualizado com sucesso.');
      } else {
        await criarCliente(dados);
        toastSucesso('Cliente cadastrado com sucesso.');
      }
      modal.fechar();
      if (typeof aposSalvar === 'function') aposSalvar();
    } catch (erro) {
      msgErro.definir(mensagemErroCliente(erro));
      btnSalvar.disabled = false;
      btnSalvar.textContent = ehEdicao ? 'Salvar alterações' : 'Cadastrar cliente';
    }
  }

  btnCancelar.addEventListener('click', () => {
    modal.fechar();
    if (typeof aposSalvar === 'function') aposSalvar();
  });
  btnSalvar.addEventListener('click', salvar);
  form.addEventListener('submit', (evento) => {
    evento.preventDefault();
    salvar();
  });
}

function validarDados(dados) {
  if (!dados.nome) return 'O nome do cliente é obrigatório.';

  const erroTelefone = validarTelefoneBrasileiro(dados.telefone);
  if (erroTelefone) return erroTelefone;

  if (dados.email) {
    const regex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    if (!regex.test(dados.email)) return 'Informe um e-mail válido.';
  }

  return null;
}

function avisarErro(alvo, mensagem) {
  const el = criarElemento('p', { class: 'alert alert-danger', text: mensagem });
  alvo.prepend(el);
  setTimeout(() => el.remove(), 6000);
}