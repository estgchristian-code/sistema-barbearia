import { supabase } from './supabaseClient.js';

const HORARIO_INICIO = 9;   // 09:00
const HORARIO_FIM = 19;     // 19:00 (último início)
const PASSO_MINUTOS = 30;
const STATUS_OCUPANTES = ['pendente', 'confirmado'];

const brl = new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' });
const $ = (sel) => document.querySelector(sel);

let barbeiros = [];
let servicos = [];
let barbeiroId = null;
let servicoId = null;
let dataSelecionada = null;
let horarioSelecionado = null;
let ocupados = [];

const barbeiroSelecionado = () => barbeiros.find((b) => b.id === barbeiroId) ?? null;
const servicoSelecionado = () => servicos.find((s) => s.id === servicoId) ?? null;

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

function slotEmMinutos(slot) {
  const [h, m] = slot.split(':').map(Number);
  return h * 60 + m;
}

function gerarSlots() {
  const slots = [];
  const fim = HORARIO_FIM * 60;
  for (let t = HORARIO_INICIO * 60; t < fim; t += PASSO_MINUTOS) {
    slots.push(
      `${String(Math.floor(t / 60)).padStart(2, '0')}:${String(t % 60).padStart(2, '0')}`
    );
  }
  return slots;
}

function slotDisponivel(slot) {
  const duracao = servicoSelecionado()?.duracao_minutos ?? PASSO_MINUTOS;
  const inicio = slotEmMinutos(slot);
  const fim = inicio + duracao;
  return !ocupados.some((o) => {
    const oIni = slotEmMinutos(o.hora);
    const oFim = oIni + (o.duracao || PASSO_MINUTOS);
    return inicio < oFim && oIni < fim;
  });
}

function slotNoPassado(slot) {
  if (dataSelecionada !== hojeLocal()) return false;
  const slotDate = new Date(`${dataSelecionada}T${slot}:00`);
  return slotDate < new Date();
}

async function carregarDados() {
  try {
    const [b, s] = await Promise.all([
      supabase.from('barbeiros').select('*').eq('ativo', true).order('nome'),
      supabase.from('servicos').select('*').eq('ativo', true).order('nome'),
    ]);
    if (b.error) throw b.error;
    if (s.error) throw s.error;
    barbeiros = b.data ?? [];
    servicos = s.data ?? [];
    renderizarBarbeiros();
    renderizarServicos();
  } catch (err) {
    const el = $('#erro-barbearia');
    el.hidden = false;
    el.textContent = `Erro ao carregar dados: ${err.message}`;
  }
}

async function carregarOcupados() {
  ocupados = [];
  if (!barbeiroId || !dataSelecionada) return;
  const inicio = new Date(`${dataSelecionada}T00:00:00`);
  const fim = new Date(inicio.getTime() + 24 * 60 * 60 * 1000);
  const { data, error } = await supabase
    .from('agendamentos')
    .select('data_hora, servicos(duracao_minutos)')
    .eq('barbeiro_id', barbeiroId)
    .in('status', STATUS_OCUPANTES)
    .gte('data_hora', inicio.toISOString())
    .lt('data_hora', fim.toISOString());
  if (error) {
    console.error(error);
    return;
  }
  ocupados = (data ?? []).map((a) => ({
    hora: new Date(a.data_hora).toLocaleTimeString('en-GB', {
      hour: '2-digit',
      minute: '2-digit',
    }),
    duracao: a.servicos?.duracao_minutos ?? PASSO_MINUTOS,
  }));
}

function renderizarBarbeiros() {
  const el = $('#barbeiros');
  if (!barbeiros.length) {
    el.innerHTML = '';
    return;
  }
  el.innerHTML = barbeiros
    .map((b) => {
      const ini = b.nome
        .split(' ')
        .map((p) => p[0])
        .slice(0, 2)
        .join('')
        .toUpperCase();
      return `
        <button type="button" class="opp ${barbeiroId === b.id ? 'selecionada' : ''}"
                data-id="${b.id}">
          <span class="avatar">${ini}</span>
          <span class="infos"><span class="nome">${b.nome}</span></span>
        </button>`;
    })
    .join('');
  el.querySelectorAll('.opp').forEach((btn) => {
    btn.addEventListener('click', () => selecionarBarbeiro(Number(btn.dataset.id)));
  });
}

function renderizarServicos() {
  const el = $('#servicos');
  el.innerHTML = servicos
    .map((s) => `
      <button type="button" class="opp ${servicoId === s.id ? 'selecionada' : ''}"
              data-id="${s.id}">
        <span class="infos">
          <span class="nome">${s.nome}</span>
          <span class="detalhe">${s.duracao_minutos} min</span>
        </span>
        <span class="preco">${brl.format(Number(s.preco))}</span>
      </button>`)
    .join('');
  el.querySelectorAll('.opp').forEach((btn) => {
    btn.addEventListener('click', () => selecionarServico(Number(btn.dataset.id)));
  });
}

function renderizarHorarios() {
  const el = $('#horarios');
  const dica = $('#dica-horarios');
  if (!barbeiroId || !servicoId || !dataSelecionada) {
    el.innerHTML = '';
    dica.textContent = 'Escolha barbeiro, serviço e data para ver os horários.';
    return;
  }
  dica.textContent = 'Horários livres para esse dia:';
  el.innerHTML = gerarSlots()
    .map((slot) => {
      const livre = slotDisponivel(slot) && !slotNoPassado(slot);
      const sel = horarioSelecionado === slot;
      return `<button type="button" class="hora ${sel ? 'selecionada' : ''}"
        ${livre ? '' : 'disabled'}>${slot}</button>`;
    })
    .join('');
  el.querySelectorAll('.hora:not(:disabled)').forEach((btn) => {
    btn.addEventListener('click', () => selecionarHorario(btn.textContent));
  });
}

function selecionarBarbeiro(id) {
  barbeiroId = id;
  horarioSelecionado = null;
  renderizarBarbeiros();
  renderizarHorarios();
  carregarOcupados().then(() => {
    renderizarHorarios();
    renderizarResumo();
    atualizarEstadoBotao();
  });
}

function selecionarServico(id) {
  servicoId = id;
  horarioSelecionado = null;
  renderizarServicos();
  renderizarHorarios();
  renderizarResumo();
  atualizarEstadoBotao();
}

function selecionarHorario(slot) {
  horarioSelecionado = slot;
  renderizarHorarios();
  renderizarResumo();
  atualizarEstadoBotao();
}

function renderizarResumo() {
  const svc = servicoSelecionado();
  const barbeiro = barbeiroSelecionado();
  const el = $('#resumo');
  if (!svc || !barbeiro || !dataSelecionada || !horarioSelecionado) {
    el.hidden = true;
    return;
  }
  const dt = new Date(`${dataSelecionada}T${horarioSelecionado}:00`);
  const dataFmt = dt.toLocaleDateString('pt-BR', { day: '2-digit', month: '2-digit' });
  const horaFmt = dt.toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' });
  el.hidden = false;
  el.innerHTML =
    `<strong>${svc.nome}</strong> com ${barbeiro.nome} · ` +
    `${brl.format(Number(svc.preco))} · ${dataFmt} às ${horaFmt}`;
}

function mostrarMensagem(texto, tipo) {
  const el = $('#mensagem');
  el.hidden = false;
  el.className = `mensagem ${tipo}`;
  el.textContent = texto;
}

function montarWhatsApp(dataHora, nome, whatsapp) {
  const barbeiro = barbeiroSelecionado();
  const svc = servicoSelecionado();
  const numero = limparTelefone(barbeiro?.telefone);
  if (!numero) return null;

  const dataFmt = dataHora.toLocaleDateString('pt-BR', {
    weekday: 'long',
    day: '2-digit',
    month: 'long',
  });
  const horaFmt = dataHora.toLocaleTimeString('pt-BR', {
    hour: '2-digit',
    minute: '2-digit',
  });

  const texto = [
    `Olá, ${barbeiro.nome}!`,
    'Acabei de agendar um horário na barbearia. Segue o resumo:',
    '',
    `Data: ${dataFmt}`,
    `Horário: ${horaFmt}`,
    `Serviço: ${svc.nome}`,
    `Valor: ${brl.format(Number(svc.preco))}`,
    `Cliente: ${nome}`,
    `WhatsApp: ${whatsapp}`,
    '',
    'Por favor, confirme meu agendamento. Obrigado!',
  ].join('\n');

  return `https://wa.me/${numero}?text=${encodeURIComponent(texto)}`;
}

async function confirmar() {
  const nome = $('#nome').value.trim();
  const whatsapp = $('#whatsapp').value.trim();

  if (!barbeiroId || !servicoId || !dataSelecionada || !horarioSelecionado) {
    mostrarMensagem('Selecione barbeiro, serviço, data e horário.', 'aviso');
    return;
  }
  if (!nome) {
    $('#nome').focus();
    mostrarMensagem('Informe seu nome.', 'aviso');
    return;
  }
  if (!whatsapp) {
    $('#whatsapp').focus();
    mostrarMensagem('Informe seu WhatsApp para o barbeiro confirmar.', 'aviso');
    return;
  }

  const dataHora = new Date(`${dataSelecionada}T${horarioSelecionado}:00`);
  const btn = $('#btn-confirmar');
  const win = window.open('', '_blank');

  btn.disabled = true;
  btn.textContent = 'Salvando...';

  const { error } = await supabase.from('agendamentos').insert({
    cliente_nome: nome,
    cliente_whatsapp: whatsapp,
    barbeiro_id: barbeiroId,
    servico_id: servicoId,
    data_hora: dataHora.toISOString(),
    status: 'pendente',
  });

  if (error) {
    win?.close();
    btn.disabled = false;
    btn.textContent = 'Confirmar Agendamento';
    mostrarMensagem(`Erro ao salvar: ${error.message}`, 'erro');
    return;
  }

  const url = montarWhatsApp(dataHora, nome, whatsapp);
  if (url) {
    win.location.href = url;
  } else {
    win?.close();
    mostrarMensagem(
      'Agendamento salvo, mas o barbeiro não cadastrou o WhatsApp.',
      'aviso'
    );
  }

  $('#formulario').reset();
  btn.disabled = false;
  btn.textContent = 'Confirmar Agendamento';
  mostrarMensagem('Agendamento confirmado! Abrimos o WhatsApp para enviar a mensagem.', 'ok');
}

function atualizarEstadoBotao() {
  $('#btn-confirmar').disabled = !(
    barbeiroId && servicoId && dataSelecionada && horarioSelecionado
  );
}

$('#data').min = hojeLocal();
$('#data').addEventListener('change', async (e) => {
  dataSelecionada = e.target.value;
  horarioSelecionado = null;
  await carregarOcupados();
  renderizarHorarios();
  renderizarResumo();
  atualizarEstadoBotao();
});

$('#btn-confirmar').addEventListener('click', confirmar);

atualizarEstadoBotao();
carregarDados();