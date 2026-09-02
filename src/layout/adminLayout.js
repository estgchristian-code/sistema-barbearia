// Layout administrativo: sidebar (desktop) + drawer (mobile) + topbar.
// No desktop a navegação fica fixa à esquerda; no mobile vira um drawer
// lateral com sombra de cortina e fechamento por toque fora do menu.

import { logout } from '../services/authService.js';
import { criarElemento, textoClaro } from '../lib/dom.js';

const ITENS_NAVEGACAO = [
  { chave: 'dashboard', rotulo: 'Dashboard', icone: '▦' },
  { chave: 'agenda', rotulo: 'Agenda', icone: '🗓' },
  { chave: 'clientes', rotulo: 'Clientes', icone: '👤' },
  { chave: 'servicos', rotulo: 'Serviços', icone: '✂' },
  { chave: 'profissionais', rotulo: 'Profissionais', icone: '🪒' },
  { chave: 'configuracoes', rotulo: 'Configurações', icone: '⚙' },
];

export function renderizarPainelAdmin(container, contexto, paginas, callbacks = {}) {
  const { profissional, barbearia } = contexto;
  const { onSair = () => {} } = callbacks;

  container.classList.remove('auth-app');
  container.classList.add('admin-app');
  container.innerHTML = '';

  function montarMarca(classeExtra) {
    const marca = criarElemento('div', { class: `admin-marca ${classeExtra}`.trim() }, [
      criarElemento('span', { class: 'admin-marca-icone', 'aria-hidden': 'true', text: '💈' }),
      criarElemento('span', { class: 'admin-marca-nome', text: textoClaro(barbearia?.nome) || 'Barbearia' }),
    ]);
    return marca;
  }

  const botaoMenu = criarElemento('button', {
    type: 'button',
    class: 'admin-menu-botao',
    'aria-label': 'Abrir menu de navegação',
    'aria-expanded': 'false',
    'aria-controls': 'nav-admin',
  }, [criarElemento('span', { 'aria-hidden': 'true', text: '☰' })]);

  // ---- Navegação ----
  const navLista = criarElemento('ul', { class: 'admin-nav-lista', role: 'tablist' });
  for (const item of ITENS_NAVEGACAO) {
    const botao = criarElemento('button', {
      type: 'button',
      class: 'admin-nav-item',
      'data-page': item.chave,
      'aria-label': item.rotulo,
    }, [
      criarElemento('span', { class: 'admin-nav-icone', 'aria-hidden': 'true', text: item.icone }),
      criarElemento('span', { text: item.rotulo }),
    ]);
    navLista.append(criarElemento('li', {}, [botao]));
  }

  const nav = criarElemento('nav', { class: 'admin-nav', 'aria-label': 'Menu principal' }, [navLista]);

  // ---- Sidebar (desktop) / drawer (mobile) ----
  const lateral = criarElemento('aside', { id: 'nav-admin', class: 'admin-lateral' }, [
    montarMarca('admin-marca-lateral'),
    nav,
    criarElemento('div', { class: 'admin-lateral-rodape' }, [
      criarElemento('span', { class: 'admin-rodape-texto', text: 'Sistema de gestão de barbearia' }),
      criarElemento('span', { class: 'admin-rodape-versao', text: 'v1.0' }),
    ]),
  ]);

  // ---- Usuário + sair ----
  const botaoSair = criarElemento('button', {
    type: 'button',
    class: 'btn btn-ghost btn-sm',
    text: 'Sair',
  });

  const usuarioInfo = criarElemento('div', { class: 'admin-usuario' }, [
    criarElemento('div', { class: 'admin-usuario-texto' }, [
      criarElemento('span', { class: 'admin-usuario-nome', text: textoClaro(profissional?.nome) || '—' }),
      criarElemento('span', { class: 'admin-usuario-cargo', text: cargoLegivel(profissional?.cargo) }),
    ]),
    botaoSair,
  ]);

  const topo = criarElemento('header', { class: 'admin-topo' }, [
    botaoMenu,
    montarMarca('admin-marca-mobile'),
    criarElemento('div', { class: 'admin-topo-direita' }, [usuarioInfo]),
  ]);

  // ---- Conteúdo ----
  const conteudo = criarElemento('main', { class: 'admin-conteudo' });

  const principal = criarElemento('div', { class: 'admin-principal' }, [topo, conteudo]);
  const cortina = criarElemento('div', { class: 'admin-nav-sombra', hidden: true });

  const corpo = criarElemento('div', { class: 'admin-corpo' }, [lateral, principal]);
  container.append(corpo, cortina);

  // ---- Drawer mobile ----
  let navAberta = false;
  function alternarNav(forcar) {
    const proximo = typeof forcar === 'boolean' ? forcar : !navAberta;
    navAberta = proximo;
    lateral.classList.toggle('aberta', navAberta);
    cortina.hidden = !navAberta;
    botaoMenu.setAttribute('aria-expanded', navAberta ? 'true' : 'false');
    if (navAberta) {
      navLista.querySelector('button').focus();
    }
  }

  botaoMenu.addEventListener('click', () => alternarNav());
  cortina.addEventListener('click', () => alternarNav(false));
  lateral.addEventListener('click', (evento) => {
    if (evento.target.closest('button[data-page]')) alternarNav(false);
  });

  // ---- Troca de página ----
  const renderizarPagina = (chave) => {
    const fn = paginas[chave];
    if (typeof fn === 'function') fn(conteudo, contexto);
    else renderizarPlaceholder(conteudo, chave);
  };

  navLista.addEventListener('click', (evento) => {
    const botao = evento.target.closest('button[data-page]');
    if (!botao) return;
    ativarPagina(botao.dataset.page);
  });

  function ativarPagina(chave) {
    navLista.querySelectorAll('button[data-page]').forEach((btn) => {
      const ativo = btn.dataset.page === chave;
      btn.classList.toggle('ativo', ativo);
      btn.setAttribute('aria-selected', ativo ? 'true' : 'false');
    });
    renderizarPagina(chave);
  }

  // ---- Sair ----
  botaoSair.addEventListener('click', async (e) => {
    const btn = e.currentTarget;
    btn.disabled = true;
    btn.textContent = 'Saindo…';
    try {
      await logout();
    } catch {
      // segue para a tela de login mesmo assim
    } finally {
      onSair();
    }
  });

  ativarPagina('dashboard');
}

function cargoLegivel(cargo) {
  if (cargo === 'admin') return 'Administrador';
  if (cargo === 'barbeiro') return 'Barbeiro';
  return textoClaro(cargo) || '—';
}

function renderizarPlaceholder(conteudo, chave) {
  conteudo.innerHTML = '';
  const titulo = textoClaro(chave).charAt(0).toUpperCase() + textoClaro(chave).slice(1);
  const estadoVazio = criarElemento('div', { class: 'empty-state' }, [
    criarElemento('span', { class: 'empty-state-icone', 'aria-hidden': 'true', text: '🏗' }),
    criarElemento('h3', { class: 'empty-state-titulo', text: titulo }),
    criarElemento('p', { text: 'Funcionalidade em construção. Este menu ainda não está disponível nesta etapa.' }),
  ]);
  conteudo.append(estadoVazio);
}