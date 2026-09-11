import './style.css';

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL;
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY;

const app = document.getElementById('app');

if (!supabaseUrl || !supabaseAnonKey) {
  app.classList.add('auth-app');
  app.innerHTML = `
    <p class="auth-aviso">
      <strong>Configuração pendente</strong>
    </p>
    <div class="auth-card">
      <h1>Ajuste o arquivo <code>.env</code></h1>
      <p>
        As variáveis <code>VITE_SUPABASE_URL</code> e
        <code>VITE_SUPABASE_ANON_KEY</code> não foram encontradas.
      </p>
      <p>Para acessar o sistema:</p>
      <ol class="auth-passos">
        <li>Copie <code>.env.example</code> para <code>.env</code> na raiz do projeto.</li>
        <li>Preencha com a URL e a <em>anon key</em> (pública) do seu projeto
            em Supabase Dashboard &gt; Settings &gt; API.
            A anon key não é um segredo e é segura para o frontend.</li>
        <li>Reinicie o servidor de desenvolvimento (<code>npm run dev</code>) e
            recarregue esta página.</li>
      </ol>
      <p class="auth-dado-aviso" style="padding:10px 12px;border-radius:8px">
        Nunca coloque a <em>service_role key</em> aqui — ela deve ficar
        apenas no servidor.
      </p>
    </div>
  `;
} else {
  iniciarApp();
}

async function iniciarApp() {
  const {
    obterProfissionalAutenticado,
  } = await import('./services/profissionalService.js');
  const { observarMudancasDeSessao, logout } = await import('./services/authService.js');
  const { renderizarPainelAdmin } = await import('./layout/adminLayout.js');
  const { renderizarLogin } = await import('./pages/auth/loginPage.js');
  const { renderizarDashboard } = await import('./pages/dashboard/dashboardPage.js');
  const { renderizarServicos } = await import('./pages/servicos/servicosPage.js');
  const { renderizarClientes } = await import('./pages/clientes/clientesPage.js');
  const { renderizarAgenda } = await import('./pages/agenda/agendaPage.js');
  const { renderizarConfiguracoes } = await import('./pages/configuracoes/configuracoesPage.js');
  const { renderizarProfissionais } = await import('./pages/profissionais/profissionaisPage.js');

  // Mapa de rotas do painel. dashboard, servicos, clientes, agenda,
  // configuracoes e profissionais são funcionais.
  const paginas = {
    dashboard: renderizarDashboard,
    servicos: renderizarServicos,
    clientes: renderizarClientes,
    agenda: renderizarAgenda,
    configuracoes: renderizarConfiguracoes,
    profissionais: renderizarProfissionais,
  };

  function mostrarLogin() {
    renderizarLogin(app, {
      onAutenticado: () => entrarNoPainel(),
    });
  }

  async function entrarNoPainel() {
    const profissional = await obterProfissionalAutenticado();
    // Profissional ausente ou excluído (soft delete): limpa a sessão Auth
    // antes de voltar ao login — evita que token permaneça no localStorage.
    if (!profissional || profissional.deleted_at) {
      try { await logout(); } catch { /* ignora erro de rede/logout */ }
      mostrarLogin();
      return;
    }
    const { obterBarbearia } = await import('./services/dashboardService.js');
    const barbearia = await obterBarbearia(profissional.barbearia_id);
    renderizarPainelAdmin(
      app,
      { profissional, barbearia },
      paginas,
      { onSair: () => mostrarLogin() }
    );
  }

  function rotearInicial() {
    obterProfissionalAutenticado().then((profissional) => {
      if (profissional) entrarNoPainel();
      else mostrarLogin();
    });
  }

  // Se a sessão for encerrada (logout ou expiração), volta ao login.
  observarMudancasDeSessao((evento) => {
    if (evento === 'SIGNED_OUT') {
      mostrarLogin();
    }
  });

  rotearInicial();
}
