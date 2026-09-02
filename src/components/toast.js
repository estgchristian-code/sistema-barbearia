// Toast de mensagens curtas (sucesso / erro / aviso / info).
// Renderiza pilha de notificações transitórias no canto inferior direito.
// Nunca exibe toast vazio: mensagens null/undefined/objetos são ignoradas.

import { criarElemento, textoClaro } from '../lib/dom.js';

const VARIANCAS = {
  success: 'success',
  erro: 'danger',
  aviso: 'warning',
  info: 'info',
};

function pilha() {
  let el = document.querySelector('.toast-pilha');
  if (!el) {
    el = criarElemento('div', {
      class: 'toast-pilha',
      role: 'region',
      'aria-live': 'polite',
      'aria-label': 'Notificações',
    });
    document.body.append(el);
  }
  return el;
}

export function mostrarMensagem(texto, tipo = 'info', duracao = 4000) {
  const limpo = textoClaro(texto);
  if (!limpo) return;

  const varianca = VARIANCAS[tipo] || 'info';
  const icone = {
    success: '✓',
    erro: '✕',
    aviso: '⚠',
    info: 'ℹ',
  }[varianca];

  const toast = criarElemento('div', { class: `toast toast-${varianca}`, role: 'status' }, [
    criarElemento('span', { class: 'toast-icone', 'aria-hidden': 'true', text: icone }),
    criarElemento('span', { class: 'toast-texto', text: limpo }),
  ]);

  const fechar = () => {
    toast.classList.add('saindo');
    setTimeout(() => toast.remove(), 220);
  };

  const botaoFechar = criarElemento('button', {
    type: 'button',
    class: 'toast-fechar btn-icon',
    'aria-label': 'Fechar notificação',
  }, [criarElemento('span', { text: '✕' })]);

  botaoFechar.addEventListener('click', fechar);
  toast.append(botaoFechar);
  pilha().append(toast);

  setTimeout(fechar, duracao);
  requestAnimationFrame(() => toast.classList.add('entrando'));
  return toast;
}

// Atalhos semânticos.
export const toastSucesso = (t) => mostrarMensagem(t, 'success');
export const toastErro = (t) => mostrarMensagem(t, 'erro');
export const toastAviso = (t) => mostrarMensagem(t, 'aviso');
export const toastInfo = (t) => mostrarMensagem(t, 'info');