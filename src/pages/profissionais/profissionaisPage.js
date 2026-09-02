import {
  listarProfissionaisDaBarbearia,
  criarProfissional,
  atualizarProfissional,
  alterarAtivoProfissional,
  mensagemErroProfissional,
} from '../../services/profissionalService.js';
import { criarElemento, criarCampoFormulario } from '../../lib/dom.js';
import { abrirModal, criarMensagem, abrirModalConfirmacao } from '../../components/modal.js';

export async function renderizarProfissionais(conteudo, contexto) {
  const { profissional } = contexto;
  const ehAdmin = profissional?.cargo === 'admin';
  // admin atual da sessão (para proteger o próprio e não deixar sem admin).
  const idAdminAtual = profissional?.id;

  conteudo.innerHTML = '';

  const cabecalho = criarElemento('header', { class: 'page-header' }, [
    criarElemento('div', {}, [
      criarElemento('h1', { text: 'Profissionais' }),
      criarElemento('p', { text: 'Gerencie os barbeiros da sua barbearia.' }),
    ]),
    criarElemento('div', { class: 'page-header-acoes' }, [
      ehAdmin
        ? criarElemento('button', { type: 'button', class: 'btn btn-primary', id: 'btn-novo-profissional', text: '+ Novo profissional' })
        : null,
    ]),
  ]);
  conteudo.append(cabecalho);

  if (!ehAdmin) {
    conteudo.append(
      criarElemento('p', { class: 'alert alert-info', text: 'Somente administradores podem cadastrar, editar ou ativar/desativar profissionais.' })
    );
  }

  const lista = criarElemento('div', { id: 'prof-lista' });
  conteudo.append(lista);

  // Listener registrado antes do carregamento (padrão Agenda): o botão
  // continua funcional mesmo se o carregamento de dados demorar ou falhar.
  conteudo.querySelector('#btn-novo-profissional')?.addEventListener('click', () => {
    abrirFormularioModal({
      aoSalvar: criarProfissional,
      aoFechar: () => carregarProfissionais(lista, { ehAdmin, idAdminAtual }),
    });
  });

  await carregarProfissionais(lista, { ehAdmin, idAdminAtual });
}

async function carregarProfissionais(lista, { ehAdmin, idAdminAtual }) {
  lista.innerHTML = '';
  lista.append(criarEstado('Carregando profissionais…'));

  let profissionais;
  try {
    profissionais = await listarProfissionaisDaBarbearia();
  } catch (erro) {
    lista.innerHTML = '';
    lista.append(criarElemento('p', { class: 'alert alert-danger', text: mensagemErroProfissional(erro) }));
    return;
  }

  lista.innerHTML = '';

  if (!profissionais.length) {
    lista.append(
      criarElemento('div', { class: 'empty-state' }, [
        criarElemento('span', { class: 'empty-state-icone', 'aria-hidden': 'true', text: '💈' }),
        criarElemento('h3', { class: 'empty-state-titulo', text: 'Nenhum profissional cadastrado' }),
        criarElemento('p', { text: ehAdmin ? 'Clique em "+ Novo profissional" para começar.' : 'Nenhum profissional para exibir.' }),
      ])
    );
    return;
  }

  const tabela = criarElemento('table', { class: 'table' });
  const thead = criarElemento('thead', {}, [
    criarElemento('tr', {}, [
      criarElemento('th', { text: 'Nome' }),
      criarElemento('th', { text: 'Telefone' }),
      criarElemento('th', { text: 'Cargo' }),
      criarElemento('th', { text: 'Status' }),
      criarElemento('th', { text: 'Acesso ao sistema' }),
      criarElemento('th', { class: 'acoes', text: 'Ações' }),
    ]),
  ]);
  const tbody = criarElemento('tbody');

  for (const p of profissionais) {
    const ehAdminLinha = p.cargo === 'admin';
    const protegido = ehAdminLinha && p.id === idAdminAtual;
    tbody.append(
      criarElemento('tr', {}, [
        criarElemento('td', { 'data-label': 'Nome', text: p.nome }),
        criarElemento('td', { 'data-label': 'Telefone', text: p.telefone || '—' }),
        criarElemento('td', { 'data-label': 'Cargo' }, [
          criarElemento('span', { class: ehAdminLinha ? 'badge badge-accent' : 'badge badge-neutral', text: ehAdminLinha ? 'Admin' : 'Barbeiro' }),
        ]),
        criarElemento('td', { 'data-label': 'Status' }, [criarBadgeAtivo(p.ativo)]),
        criarElemento('td', { 'data-label': 'Acesso' }, [criarBadgeAcesso(p.auth_user_id)]),
        criarElemento('td', { class: 'acoes', 'data-label': 'Ações' }, [
          criarElemento('div', { class: 'acao-cel' }, montarAcoes(p, {
            ehAdmin,
            ehAdminLinha,
            protegido,
          })),
        ]),
      ])
    );
  }
  tabela.append(thead, tbody);
  lista.append(criarElemento('div', { class: 'table-wrap' }, [tabela]));

  tbody.querySelectorAll('button[data-edit-id]').forEach((btn) => {
    btn.addEventListener('click', () => {
      const id = Number(btn.dataset.editId);
      const p = profissionais.find((x) => x.id === id);
      if (p) {
        abrirFormularioModal({
          profissional: p,
          aoSalvar: (dados) => atualizarProfissional(p.id, dados),
          aoFechar: () => carregarProfissionais(lista, { ehAdmin, idAdminAtual }),
        });
      }
    });
  });
  tbody.querySelectorAll('[data-toggle-id]').forEach((btn) => {
    btn.addEventListener('click', () => {
      const id = Number(btn.dataset.toggleId);
      const novoAtivo = btn.dataset.ativo !== 'true';
      abrirModalConfirmacao({
        titulo: novoAtivo ? 'Ativar profissional' : 'Desativar profissional',
        mensagem: `Tem certeza que deseja ${novoAtivo ? 'ativar' : 'desativar'} este profissional? Os agendamentos históricos são mantidos.`,
        rotuloConfirmar: novoAtivo ? 'Ativar' : 'Desativar',
        aoConfirmar: async () => {
          try {
            await alterarAtivoProfissional(id, novoAtivo);
          } catch (erro) {
            throw new Error(mensagemErroProfissional(erro));
          }
          await carregarProfissionais(lista, { ehAdmin, idAdminAtual });
        },
      });
    });
  });
}

function montarAcoes(p, { ehAdmin, ehAdminLinha, protegido }) {
  if (!ehAdmin) return [criarElemento('span', { text: '—' })];
  if (protegido) {
    return [criarElemento('span', { text: 'Protegido' })];
  }

  const editar = criarElemento('button', {
    type: 'button',
    class: 'btn btn-secondary btn-sm',
    'data-edit-id': String(p.id),
    text: 'Editar',
  });

  // Admin não pode ser desativado (impede deixar a barbearia sem admin).
  if (ehAdminLinha) return [editar];

  const desativar = criarElemento('button', {
    type: 'button',
    class: 'btn btn-ghost btn-sm',
    'data-toggle-id': String(p.id),
    'data-ativo': p.ativo ? 'true' : 'false',
    text: p.ativo ? 'Desativar' : 'Ativar',
  });

  return [editar, desativar];
}

function criarBadgeAtivo(ativo) {
  return criarElemento('span', {
    class: ativo ? 'badge badge-success' : 'badge badge-neutral',
    text: ativo ? 'Ativo' : 'Inativo',
  });
}

function criarBadgeAcesso(authUserId) {
  return criarElemento('span', {
    class: authUserId ? 'badge badge-success' : 'badge badge-neutral',
    text: authUserId ? 'Com acesso' : 'Sem acesso',
  });
}

function criarEstado(texto) {
  return criarElemento('div', { class: 'loading' }, [
    criarElemento('span', { class: 'spinner' }),
    criarElemento('span', { text }),
  ]);
}

// ------------------------- Modal (cadastro/edição) -------------------------

function abrirFormularioModal({ profissional = null, aoSalvar, aoFechar }) {
  const ehEdicao = Boolean(profissional);
  const ehAdminLinha = profissional?.cargo === 'admin';
  const msgErro = criarMensagem('danger');

  const inputNome = criarElemento('input', {
    type: 'text',
    name: 'nome',
    class: 'input',
    value: profissional?.nome || '',
  });
  const inputTelefone = criarElemento('input', {
    type: 'text',
    name: 'telefone',
    class: 'input',
    value: profissional?.telefone || '',
    maxlength: 30,
    placeholder: '(41) 99999-9999',
  });

  // Cargo: fixo como "Barbeiro" no cadastro; inalterável na edição.
  const inputCargo = criarElemento('input', {
    type: 'text',
    class: 'input',
    value: ehAdminLinha ? 'Admin' : 'Barbeiro',
    readonly: true,
    disabled: true,
  });

  const inputAtivo = criarElemento('input', { type: 'checkbox', name: 'ativo' });
  if (profissional?.ativo) inputAtivo.setAttribute('checked', '');

  // Ativo: permitido no barbeiro; admin sempre ativo (protegido).
  const campoAtivo = criarElemento('label', { class: 'form-linha' }, [
    inputAtivo,
    criarElemento('span', { text: 'Ativo' }),
  ]);
  if (ehEdicao && ehAdminLinha) {
    inputAtivo.checked = true;
    inputAtivo.disabled = true;
  }

  // Aviso de acesso (novos barbeiros não têm acesso ainda).
  const avisoAcesso = ehEdicao
    ? null
    : criarElemento('p', { class: 'alert alert-info', text: 'Este profissional ainda não possui acesso ao sistema.' });

  const form = criarElemento('form', { id: 'form-profissional' }, [
    criarCampoFormulario('Nome *', inputNome),
    criarCampoFormulario('Telefone', inputTelefone),
    criarCampoFormulario('Cargo', inputCargo),
  ]);
  if (ehEdicao) form.append(campoAtivo);
  if (avisoAcesso) form.append(avisoAcesso);
  form.append(msgErro);

  const btnCancelar = criarElemento('button', { type: 'button', class: 'btn btn-secondary', text: 'Cancelar' });
  const btnSalvar = criarElemento('button', {
    type: 'button',
    class: 'btn btn-primary',
    text: ehEdicao ? 'Salvar alterações' : 'Cadastrar profissional',
  });

  const modal = abrirModal({
    titulo: ehEdicao ? 'Editar profissional' : 'Novo profissional',
    tamanho: 'md',
    corpo: [form],
    rodape: [btnCancelar, btnSalvar],
    aoFechar,
  });

  async function salvar() {
    msgErro.limpar();

    const dados = {
      nome: inputNome.value.trim(),
      telefone: inputTelefone.value.trim(),
      ativo: ehEdicao ? inputAtivo.checked : true,
    };

    if (!dados.nome) {
      msgErro.definir('O nome do profissional é obrigatório.');
      return;
    }

    btnSalvar.disabled = true;
    btnSalvar.textContent = ehEdicao ? 'Salvando…' : 'Cadastrando…';
    try {
      await aoSalvar(dados);
      modal.fechar();
    } catch (erro) {
      msgErro.definir(mensagemErroProfissional(erro));
      btnSalvar.disabled = false;
      btnSalvar.textContent = ehEdicao ? 'Salvar alterações' : 'Cadastrar profissional';
    }
  }

  btnCancelar.addEventListener('click', modal.fechar);
  btnSalvar.addEventListener('click', salvar);
  form.addEventListener('submit', (evento) => {
    evento.preventDefault();
    salvar();
  });
}