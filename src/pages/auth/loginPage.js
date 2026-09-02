import { loginComEmailSenha } from '../../services/authService.js';
import { criarElemento, textoClaro } from '../../lib/dom.js';

function montarErroAmigavel(erro) {
  const codigoErro = erro?.code || erro?.status;
  const mensagem = textoClaro(erro?.message);
  const mapeamento = {
    invalid_credentials: 'E-mail ou senha incorretos.',
    email_not_confirmed: 'E-mail ainda não confirmado. Verifique sua caixa de entrada.',
    user_not_found: 'Nenhuma conta encontrada com este e-mail.',
    over_request_rate_limit: 'Muitas tentativas. Aguarde alguns instantes.',
  };
  if (mapeamento[codigoErro]) return mapeamento[codigoErro];
  if (mensagem.toLowerCase().includes('invalid login credentials')) {
    return 'E-mail ou senha incorretos.';
  }
  return mensagem || 'Não foi possível entrar.';
}

// Renderiza apenas o formulário de login. O controle de sessão/roteamento
// é responsabilidade do app (src/main.js). "callbacks.onAutenticado" é
// chamado após login bem-sucedido.
export function renderizarLogin(container, callbacks = {}) {
  const { onAutenticado = () => {} } = callbacks;
  container.classList.remove('admin-app');
  container.classList.add('auth-app');
  container.innerHTML = '';

  const aviso = criarElemento('p', { class: 'auth-aviso' }, [
    criarElemento('strong', { text: 'Acesso administrativo' }),
    criarElemento('span', { text: ' Faça login para abrir o painel.' }),
  ]);

  const form = criarElemento('form', { id: 'form-login', class: 'auth-form' });

  const campoEmail = criarElemento('label', { class: 'auth-campo' }, [
    criarElemento('span', { text: 'E-mail' }),
    criarElemento('input', {
      type: 'email',
      name: 'email',
      required: true,
      autocomplete: 'username',
      placeholder: 'voce@exemplo.com',
    }),
  ]);

  const campoSenha = criarElemento('label', { class: 'auth-campo' }, [
    criarElemento('span', { text: 'Senha' }),
    criarElemento('input', {
      type: 'password',
      name: 'senha',
      required: true,
      autocomplete: 'current-password',
      placeholder: '••••••••',
    }),
  ]);

  const btnEntrar = criarElemento('button', {
    type: 'submit',
    class: 'auth-botao',
    text: 'Entrar',
  });

  const msgErro = criarElemento('p', { class: 'auth-erro', role: 'alert' });
  const card = criarElemento('div', { class: 'auth-card' }, [
    criarElemento('div', { class: 'auth-market' }, [
      criarElemento('span', { class: 'auth-market-icone', 'aria-hidden': 'true', text: '💈' }),
      criarElemento('h1', { text: 'Barbearia' }),
    ]),
    criarElemento('p', { class: 'auth-subtitulo', text: 'Acesse o painel de gestão da barbearia.' }),
    form,
    criarElemento('p', { class: 'auth-rodape' }, [
      criarElemento('span', { 'aria-hidden': 'true', text: '🔒' }),
      criarElemento('span', { text: 'Acesso restrito aos profissionais da barbearia' }),
    ]),
  ]);

  form.append(campoEmail, campoSenha, btnEntrar, msgErro);
  container.append(aviso, card);

  form.addEventListener('submit', async (evento) => {
    evento.preventDefault();
    msgErro.textContent = '';
    btnEntrar.disabled = true;
    btnEntrar.textContent = 'Entrando…';
    const email = form.email.value.trim();
    const senha = form.senha.value;
    try {
      await loginComEmailSenha(email, senha);
      await onAutenticado();
    } catch (erro) {
      msgErro.textContent = montarErroAmigavel(erro);
    } finally {
      btnEntrar.disabled = false;
      btnEntrar.textContent = 'Entrar';
    }
  });

  return form;
}