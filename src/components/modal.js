// Componente de modal compartilhado por TODAS as telas.
// Foco inicial, trap de Tab, fechamento por Esc, fechamento por backdrop/botão,
// role="dialog" + aria-modal, foco devolvido ao elemento que abriu o modal,
// scroll interno e layout responsivo.

import { criarElemento, textoClaro } from '../lib/dom.js';

const SELETOR_FOCUSAVEIS =
  'button:not(:disabled), [href], input:not(:disabled), select:not(:disabled), textarea:not(:disabled), [tabindex]:not([tabindex="-1"])';

// Área de mensagem (alerta) que só tem aparência quando há texto real.
// Usada dentro de modais para nunca exibir caixa vermelha vazia.
export function criarMensagem(tipo = 'info') {
  const el = criarElemento('div', { class: `alert alert-${tipo}`, role: 'alert' });
  el.hidden = true;
  el.definir = (texto) => {
    const limpo = textoClaro(texto);
    el.textContent = limpo;
    el.hidden = !limpo;
  };
  el.limpar = () => el.definir('');
  return el;
}

// Abre um modal padrão.
// Opções:
//   titulo   — string do cabeçalho
//   corpo    — nó(ais) DOM anexados ao corpo do modal
//   rodape   — nó(ais) DOM anexados ao rodapé (opcional)
//   tamanho  — 'sm' | 'md' | 'lg'
//   aoFechar — função chamada ao fechar (após remover o modal)
// Retorna { fechar, backdrop, caixa, corpo, rodape }.
export function abrirModal({ titulo = '', corpo = null, rodape = null, tamanho = 'md', aoFechar = null }) {
  const elementoAnterior = document.activeElement;
  const idTitulo = `titulo-modal-${Math.random().toString(36).slice(2, 9)}`;

  const botaoFechar = criarElemento('button', {
    type: 'button',
    class: 'btn btn-ghost btn-sm modal-fechar',
    'aria-label': 'Fechar',
  }, [criarElemento('span', { text: '✕' })]);

  const cabecalho = criarElemento('header', { class: 'modal-header' }, [
    criarElemento('h2', { id: idTitulo, class: 'modal-titulo', text: textoClaro(titulo) || 'Diálogo' }),
    botaoFechar,
  ]);

  const corpoEl = criarElemento('div', { class: 'modal-body' });
  anexarConteudo(corpoEl, corpo);

  const caixa = criarElemento('div', {
    class: `modal modal-${tamanho}`,
    role: 'dialog',
    'aria-modal': 'true',
    'aria-labelledby': idTitulo,
  });

  caixa.append(cabecalho, corpoEl);

  if (rodape) {
    const rodapeEl = criarElemento('footer', { class: 'modal-footer' });
    anexarConteudo(rodapeEl, rodape);
    caixa.append(rodapeEl);
  }

  const backdrop = criarElemento('div', { class: 'modal-backdrop' });
  backdrop.append(caixa);
  document.body.append(backdrop);

  function fechar() {
    backdrop.remove();
    document.removeEventListener('keydown', lidarTecla, true);
    // Devolve o foco a quem abriu o modal.
    if (elementoAnterior && typeof elementoAnterior.focus === 'function') {
      try {
        elementoAnterior.focus();
      } catch {
        // ignora
      }
    }
    if (typeof aoFechar === 'function') aoFechar();
  }

  function lidarTecla(evento) {
    if (evento.key === 'Escape') {
      evento.preventDefault();
      fechar();
      return;
    }
    if (evento.key !== 'Tab') return;

    const focaiveis = Array.from(caixa.querySelectorAll(SELETOR_FOCUSAVEIS)).filter(
      (f) => f.offsetParent !== null || f === document.activeElement
    );
    if (!focaiveis.length) {
      evento.preventDefault();
      return;
    }
    const primeiro = focaiveis[0];
    const ultimo = focaiveis[focaiveis.length - 1];
    const atual = document.activeElement;

    if (evento.shiftKey && atual === primeiro) {
      evento.preventDefault();
      ultimo.focus();
    } else if (!evento.shiftKey && atual === ultimo) {
      evento.preventDefault();
      primeiro.focus();
    }
  }

  botaoFechar.addEventListener('click', fechar);
  backdrop.addEventListener('click', (evento) => {
    if (evento.target === backdrop) fechar();
  });
  caixa.addEventListener('click', (evento) => evento.stopPropagation());
  document.addEventListener('keydown', lidarTecla, true);

  // Foco inicial: primeiro elemento focável ou o próprio modal.
  requestAnimationFrame(() => {
    const alvoFoco = caixa.querySelector(SELETOR_FOCUSAVEIS) || caixa;
    alvoFoco.focus();
  });

  return { fechar, backdrop, caixa, corpo: corpoEl, rodape: caixa.querySelector('.modal-footer') };
}

function anexarConteudo(alvo, conteudo) {
  if (!conteudo) return;
  for (const item of [].concat(conteudo)) {
    if (item === null || item === undefined || item === false) continue;
    if (item instanceof Node) alvo.append(item);
    else alvo.append(document.createTextNode(textoClaro(item)));
  }
}

// Modal genérico de confirmação (excluir, desativar, remover...).
// Retorna o controle do modal (para testes/controle fino quando necessário).
export function abrirModalConfirmacao({
  titulo,
  mensagem,
  rotuloConfirmar = 'Confirmar',
  variante = 'danger',
  aoConfirmar,
  aoFechar = null,
}) {
  const msgErro = criarMensagem('danger');
  const btnConfirmar = criarElemento('button', { type: 'button', class: `btn btn-${variante}`, text: rotuloConfirmar });
  const btnCancelar = criarElemento('button', { type: 'button', class: 'btn btn-secondary', text: 'Cancelar' });

  const modal = abrirModal({
    titulo,
    tamanho: 'sm',
    corpo: [criarElemento('p', { class: 'modal-texto', text: mensagem }), msgErro],
    rodape: [btnCancelar, btnConfirmar],
    aoFechar,
  });

  btnCancelar.addEventListener('click', modal.fechar);

  btnConfirmar.addEventListener('click', async () => {
    msgErro.limpar();
    btnConfirmar.disabled = true;
    btnConfirmar.textContent = 'Processando…';
    try {
      await aoConfirmar();
      modal.fechar();
    } catch (erro) {
      const msg = textoClaro(erro?.message) || 'Não foi possível concluir a operação.';
      msgErro.definir(msg);
      btnConfirmar.disabled = false;
      btnConfirmar.textContent = rotuloConfirmar;
    }
  });

  return modal;
}