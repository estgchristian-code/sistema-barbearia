import { supabase } from './supabaseClient.js';

const brl = new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' });
const $ = (sel) => document.querySelector(sel);

const STATUS_LABEL = {
  pendente: 'Pendente',
  confirmado: 'Confirmado',
  concluido: 'Concluído',
  cancelado: 'Cancelado',
};

let agendamentos = [];
let usuario = null;

function hojeLocal() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

function limparTelefone(numero) {
  if (!numero) return null;
  const d = numero.replace(/\D/g, '');
  if (!d) return null;
  return d.startsWith('55') ? d : `55${d}`;
}

function mostrarLogin() {
  $('#tela-login').hidden = false;
  $('#tela-painel').hidden = true;
}

function mostrarPainel() {
  $('#tela-login').hidden = true;
  $('#tela-painel').hidden = false;
}

function msgLogin(texto, tipo) {
  const el = $('#msg-login');
  el.hidden = false;
  el.className = `mensagem ${tipo}`;
  el.textContent = texto;
}

function msgLista(texto, tipo) {
  const el = $('#msg-lista');
  el.hidden = false;
  el.className = `mensagem ${tipo}`;
  el.textContent = texto;
}

async function entrarPainel() {
  mostrarPainel();
  $('#data-hoje').textContent = new Date().toLocaleDateString('pt-BR', {
    weekday: 'long',
    day: '2-digit',
    month: 'long',
  });
  await carregarAgendamentos();
}

async function carregarAgendamentos() {
  const hoje = hojeLocal();
  const inicio = new Date(`${hoje}T00:00:00`);
  const fim = new Date(inicio.getTime() + 24 * 60 * 60 * 1000);

  const { data, error } = await supabase
    .from('agendamentos')
    .select('*, barbeiros(nome), servicos(nome, preco)')
    .gte('data_hora', inicio.toISOString())
    .lt('data_hora', fim.toISOString())
    .order('data_hora', { ascending: true });

  if (error) {
    msgLista(`Erro ao carregar: ${error.message}`, 'erro');
    return;
  }
  agendamentos = data ?? [];
  renderizar();
}

function cardHTML(a) {
  const hora = new Date(a.data_hora).toLocaleTimeString('pt-BR', {
    hour: '2-digit',
    minute: '2-digit',
  });

  const statuses = Object.keys(STATUS_LABEL).filter((s) => s !== a.status);
  const botoes = statuses
    .map(
      (s) =>
        `<button type="button" class="mini ${s}" data-id="${a.id}" data-status="${s}">${STATUS_LABEL[s]}</button>`
    )
    .join('');

  const whats = a.cliente_whatsapp
    ? (() => {
        const numero = limparTelefone(a.cliente_whatsapp);
        if (!numero) return '';
        const texto = `Olá, ${a.cliente_nome}! Seu agendamento de ${a.servicos?.nome ?? 'serviço'} hoje às ${hora} foi ${STATUS_LABEL[a.status].toLowerCase()}.`;
        return `<a class="mini whatsapp" href="https://wa.me/${numero}?text=${encodeURIComponent(texto)}" target="_blank">WhatsApp</a>`;
      })()
    : '';

  return `
    <div class="agenda ${a.status}">
      <div class="agenda-topo">
        <span class="hora">${hora}</span>
        <span class="badge ${a.status}">${STATUS_LABEL[a.status]}</span>
      </div>
      <div class="agenda-nome">${a.cliente_nome}</div>
      <div class="agenda-info">${a.servicos?.nome ?? '—'} · ${brl.format(Number(a.servicos?.preco ?? 0))}</div>
      <div class="agenda-info">Barbeiro: ${a.barbeiros?.nome ?? '—'}</div>
      <div class="acoes">${whats}${botoes}</div>
    </div>`;
}

function renderizar() {
  const concluidos = agendamentos.filter((a) => a.status === 'concluido');
  const faturamento = concluidos.reduce(
    (acc, a) => acc + Number(a.servicos?.preco ?? 0),
    0
  );

  $('#total-agendamentos').textContent = agendamentos.length;
  $('#total-concluidos').textContent = concluidos.length;
  $('#faturamento').textContent = brl.format(faturamento);

  const lista = $('#lista');
  if (!agendamentos.length) {
    lista.innerHTML = '';
    msgLista('Nenhum agendamento para hoje.', 'ok');
    return;
  }
  $('#msg-lista').hidden = true;
  lista.innerHTML = agendamentos.map(cardHTML).join('');

  lista.querySelectorAll('[data-status]').forEach((btn) => {
    btn.addEventListener('click', () => mudarStatus(Number(btn.dataset.id), btn.dataset.status));
  });
}

async function mudarStatus(id, status) {
  const btn = document.querySelector(`[data-id="${id}"][data-status="${status}"]`);
  if (btn) btn.disabled = true;

  const { error } = await supabase
    .from('agendamentos')
    .update({ status })
    .eq('id', id);

  if (error) {
    msgLista(`Erro ao atualizar: ${error.message}`, 'erro');
    return;
  }
  await carregarAgendamentos();
}

$('#form-login').addEventListener('submit', async (e) => {
  e.preventDefault();
  const email = $('#email').value.trim();
  const senha = $('#senha').value;
  const btn = $('#btn-entrar');

  if (!email || !senha) {
    msgLogin('Informe e-mail e senha.', 'erro');
    return;
  }

  btn.disabled = true;
  btn.textContent = 'Entrando...';
  const { error } = await supabase.auth.signInWithPassword({ email, password: senha });
  btn.disabled = false;
  btn.textContent = 'Entrar';

  if (error) {
    msgLogin('E-mail ou senha incorretos.', 'erro');
  }
});

$('#btn-sair').addEventListener('click', async () => {
  await supabase.auth.signOut();
  mostrarLogin();
});

(async () => {
  const { data } = await supabase.auth.getSession();
  if (data?.session?.user) {
    usuario = data.session.user;
    await entrarPainel();
  } else {
    mostrarLogin();
  }

  supabase.auth.onAuthStateChange((_evento, sessao) => {
    usuario = sessao?.user ?? null;
    if (usuario) entrarPainel();
    else mostrarLogin();
  });
})();