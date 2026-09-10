import {
  listarProfissionaisDaBarbearia,
  criarProfissional,
  atualizarProfissional,
  alterarAtivoProfissional,
  criarAcessoProfissional,
  excluirProfissional,
  mensagemErroProfissional,
} from '../../services/profissionalService.js';
import { criarElemento, criarCampoFormulario, criarEstado } from '../../lib/dom.js';
import { validarTelefoneBrasileiro } from '../../lib/validacao.js';
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
  tbody.querySelectorAll('[data-criar-acesso-id]').forEach((btn) => {
    btn.addEventListener('click', () => {
      const id = Number(btn.dataset.criarAcessoId);
      const p = profissionais.find((x) => x.id === id);
      if (p) {
        abrirModalCriarAcesso(p, () =>
          carregarProfissionais(lista, { ehAdmin, idAdminAtual })
        );
      }
    });
  });
  // Excluir (soft delete): somente admin; o banco valida as proteções
  // (não excluir a si mesmo nem o único admin ativo).
  tbody.querySelectorAll('[data-excluir-id]').forEach((btn) => {
    btn.addEventListener('click', () => {
      const id = Number(btn.dataset.excluirId);
      const p = profissionais.find((x) => x.id === id);
      if (p) {
        abrirModalConfirmacao({
          titulo: 'Excluir profissional',
          mensagem:
            `Tem certeza que deseja excluir ${p.nome}? O histórico de agendamentos e bloqueios será preservado e o acesso ao sistema será bloqueado.`,
          rotuloConfirmar: 'Excluir profissional',
          aoConfirmar: async () => {
            try {
              await excluirProfissional(id, Boolean(p.auth_user_id));
            } catch (erro) {
              throw new Error(mensagemErroProfissional(erro));
            }
            await carregarProfissionais(lista, { ehAdmin, idAdminAtual });
          },
        });
      }
    });
  });
}

function montarAcoes(p, { ehAdmin, ehAdminLinha, protegido }) {
  if (!ehAdmin) return [criarElemento('span', { text: '—' })];
  if (protegido) {
    return [criarElemento('span', { text: 'Protegido' })];
  }

  const botoes = [];

  if (!p.auth_user_id) {
    botoes.push(criarElemento('button', {
      type: 'button',
      class: 'btn btn-accent btn-sm',
      'data-criar-acesso-id': String(p.id),
      text: 'Criar acesso',
    }));
  }

  botoes.push(criarElemento('button', {
    type: 'button',
    class: 'btn btn-secondary btn-sm',
    'data-edit-id': String(p.id),
    text: 'Editar',
  }));

  // Admin não pode ser desativado (impede deixar a barbearia sem admin).
  if (!ehAdminLinha) {
    botoes.push(criarElemento('button', {
      type: 'button',
      class: 'btn btn-ghost btn-sm',
      'data-toggle-id': String(p.id),
      'data-ativo': p.ativo ? 'true' : 'false',
      text: p.ativo ? 'Desativar' : 'Ativar',
    }));
  }

  // Excluir (soft delete). O banco protege a si mesmo e o único admin ativo.
  botoes.push(criarElemento('button', {
    type: 'button',
    class: 'btn btn-danger btn-sm',
    'data-excluir-id': String(p.id),
    text: 'Excluir',
  }));

  return botoes;
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
  // Exibido como badge somente leitura (não é campo editável).
  const rotuloCargo = ehAdminLinha ? 'Admin' : 'Barbeiro';
  const campoCargo = criarElemento('div', { class: 'form-field' }, [
    criarElemento('span', { class: 'form-field-label', text: 'Cargo' }),
    criarElemento('span', { class: 'form-field-badge' }, [
      criarElemento('span', { class: `badge ${ehAdminLinha ? 'badge-accent' : 'badge-neutral'}`, text: rotuloCargo }),
    ]),
  ]);

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

  const form = criarElemento('form', { id: 'form-profissional' }, [
    criarCampoFormulario('Nome *', inputNome),
    criarCampoFormulario('Telefone', inputTelefone),
    campoCargo,
  ]);
  if (ehEdicao) form.append(campoAtivo);
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

    if (dados.telefone) {
      const erroTelefone = validarTelefoneBrasileiro(dados.telefone);
      if (erroTelefone) {
        msgErro.definir(erroTelefone);
        return;
      }
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

// ------------------------- Modal (criar acesso) -------------------------

function abrirModalCriarAcesso(profissional, aoFechar) {
  const msgErro = criarMensagem('danger');

  const inputEmail = criarElemento('input', {
    type: 'email',
    name: 'email',
    class: 'input',
    placeholder: 'email@exemplo.com',
    required: true,
  });
  const inputSenha = criarElemento('input', {
    type: 'password',
    name: 'senha',
    class: 'input',
    placeholder: 'Mínimo 8 caracteres',
    required: true,
  });

  const form = criarElemento('form', { id: 'form-criar-acesso' }, [
    criarCampoFormulario('E-mail de login *', inputEmail),
    criarCampoFormulario('Senha inicial *', inputSenha),
    criarElemento('p', { class: 'alert alert-info', text: 'O profissional usará este e-mail e senha para fazer login no sistema.' }),
    msgErro,
  ]);

  const btnCancelar = criarElemento('button', { type: 'button', class: 'btn btn-secondary', text: 'Cancelar' });
  const btnConfirmar = criarElemento('button', {
    type: 'button',
    class: 'btn btn-primary',
    text: 'Criar acesso',
  });

  const modal = abrirModal({
    titulo: `Criar acesso — ${profissional.nome}`,
    tamanho: 'md',
    corpo: [form],
    rodape: [btnCancelar, btnConfirmar],
    aoFechar,
  });

  async function salvar() {
    msgErro.limpar();

    const email = inputEmail.value.trim();
    const senha = inputSenha.value;

    if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      msgErro.definir('Informe um e-mail válido.');
      return;
    }
    if (!senha || senha.length < 8) {
      msgErro.definir('A senha deve ter pelo menos 8 caracteres.');
      return;
    }

    btnConfirmar.disabled = true;
    btnConfirmar.textContent = 'Criando acesso…';
    try {
      await criarAcessoProfissional(profissional.id, email, senha);
      modal.fechar();
    } catch (erro) {
      msgErro.definir(erro?.message || 'Não foi possível criar o acesso.');
      btnConfirmar.disabled = false;
      btnConfirmar.textContent = 'Criar acesso';
    }
  }

  btnCancelar.addEventListener('click', modal.fechar);
  btnConfirmar.addEventListener('click', salvar);
  form.addEventListener('submit', (evento) => {
    evento.preventDefault();
    salvar();
  });
}