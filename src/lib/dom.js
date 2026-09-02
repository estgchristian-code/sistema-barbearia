// Helpers de DOM usados por toda a aplicação.
//
// O objetivo central deste módulo é eliminar uma classe de bugs já vista neste
// projeto: valores inesperados (null, undefined, objetos, [object Object])
// aparecendo como texto na interface. Aqui todo valor convertido para texto é
// tratado explicitamente.

// Propriedades de "estado" que são aplicadas como atributo booleano presente.
// Um valor vazio ("") também liga o atributo — padrão usado para <p hidden>.
const PROPS_ESTADO = new Set([
  'hidden',
  'disabled',
  'checked',
  'selected',
  'readonly',
  'required',
  'open',
]);

// Converte qualquer valor para texto de interface. Retorna '' para valores
// ausentes. Objetos arbitrários NÃO são transformados silenciosamente em texto
// (evita [object Object]); dados de data são convertidos de forma explícita.
export function textoClaro(valor) {
  if (valor === null || valor === undefined) return '';
  if (typeof valor === 'boolean') return valor ? 'true' : 'false';
  if (typeof valor === 'number') {
    if (Number.isNaN(valor)) return '';
    return String(valor);
  }
  if (typeof valor === 'object') {
    if (valor instanceof Date) return valor.toISOString();
    console.warn('[dom] valor de objeto usado como texto — ignorado.', valor);
    return '';
  }
  return String(valor);
}

// Separador de rótulo opcional quando não há um rótulo (aria-label ausente).
function atributoSeguro(valor) {
  if (valor === null || valor === undefined) return '';
  if (typeof valor === 'object') return JSON.stringify(valor);
  return String(valor);
}

// Cria um elemento DOM de forma declarativa.
//
//   criarElemento('button', { type: 'submit', class: 'btn btn-primary', text: 'Salvar' })
//
// Regras:
// - "text"  -> textContent (sempre sanitizado por textoClaro);
// - "class" -> el.className;
// - "value" -> el.value (form controls);
// - "style" -> objeto aplicado em el.style;
// - "dataset" -> objeto aplicado em el.dataset;
// - chaves de PROPS_ESTADO -> atributo booleano presente/ausente;
// - "html"  -> innerHTML (usar SOMENTE para conteúdo confiável);
// - atributo booleano (true) -> setAttribute;
// - demais  -> setAttribute.
//
// Filhos: valores falsy (null/undefined/false) são ignorados; strings são
// inseridas como nós de texto (seguro contra [object Object]); nós DOM são
// anexados.
export function criarElemento(tag, props = {}, filhos = []) {
  const el = document.createElement(tag);

  for (const [chave, valor] of Object.entries(props)) {
    if (chave === 'class') {
      el.className = atributoSeguro(valor);
    } else if (chave === 'text') {
      el.textContent = textoClaro(valor);
    } else if (chave === 'value') {
      el.value = valor ?? '';
    } else if (chave === 'style' && valor && typeof valor === 'object') {
      Object.assign(el.style, valor);
    } else if (chave === 'dataset' && valor && typeof valor === 'object') {
      Object.assign(el.dataset, valor);
    } else if (chave === 'html') {
      el.innerHTML = valor;
    } else if (PROPS_ESTADO.has(chave)) {
      const ligado = valor === '' || valor === true || valor === 'true';
      if (ligado) el.setAttribute(chave, '');
      else el.removeAttribute(chave);
    } else if (typeof valor === 'boolean') {
      if (valor) el.setAttribute(chave, '');
    } else if (
      typeof valor === 'string' ||
      typeof valor === 'number'
    ) {
      el.setAttribute(chave, atributoSeguro(valor));
    }
    // null/undefined de atributos: ignora (não insere atributo inválido).
  }

  for (const filho of [].concat(filhos)) {
    if (filho === null || filho === undefined || filho === false) continue;
    if (filho instanceof Node) {
      el.append(filho);
    } else if (typeof filho === 'object') {
      console.warn('[dom] filho de objeto não anexado.', filho);
    } else {
      el.append(document.createTextNode(textoClaro(filho)));
    }
  }

  return el;
}

// Cria um campo de formulário com rótulo e controle, pronto para modal.
export function criarCampoFormulario(rotulo, controle) {
  if (controle instanceof HTMLElement && controle.tagName === 'TEXTAREA') {
    const rotuloEl = criarElemento('span', { class: 'form-field-label', text: rotulo });
    const campo = criarElemento('div', { class: 'form-field' }, [rotuloEl, controle]);
    return campo;
  }
  return criarElemento('label', { class: 'form-field' }, [
    criarElemento('span', { class: 'form-field-label', text: rotulo }),
    controle,
  ]);
}

// Converte um NodeList/array em array real (pequeno utilitário).
export function paraArray(lista) {
  return Array.from(lista || []);
}

// Estado de carregamento reutilizável (spinner + rótulo opcional).
export function criarEstado(texto) {
  return criarElemento('div', { class: 'loading' }, [
    criarElemento('span', { class: 'spinner' }),
    criarElemento('span', { text: texto }),
  ]);
}