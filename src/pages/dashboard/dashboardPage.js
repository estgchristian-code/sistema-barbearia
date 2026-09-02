import { obterResumoDashboard } from '../../services/dashboardService.js';
import { criarElemento, textoClaro } from '../../lib/dom.js';

// Página Dashboard: cards em leitura somente dos dados da própria
// barbearia (obtidos via RLS). Nenhuma escrita ocorre aqui.
export async function renderizarDashboard(conteudo, contexto) {
  const { profissional, barbearia } = contexto;
  conteudo.innerHTML = '';

  const saudacao = criarElemento('header', { class: 'page-header' }, [
    criarElemento('div', {}, [
      criarElemento('h1', { text: `Olá, ${textoClaro(profissional?.nome) || 'usuário'}!` }),
      criarElemento('p', {
        text: [formatarDataHoje(), textoClaro(barbearia?.nome)].filter(Boolean).join(' · '),
      }),
    ]),
  ]);
  conteudo.append(saudacao);

  const grade = criarElemento('div', { class: 'dashboard-grade' });
  const estado = criarElemento('div', { class: 'dashboard-estado' });
  conteudo.append(grade, estado);

  const carregando = criarElemento('div', { class: 'loading' }, [
    criarElemento('span', { class: 'spinner' }),
    criarElemento('span', { text: 'Carregando resumo do dia…' }),
  ]);
  estado.append(carregando);

  let resumo = null;
  try {
    resumo = await obterResumoDashboard(profissional.barbearia_id);
  } catch (e) {
    estado.innerHTML = '';
    const msg = criarElemento('p', { class: 'alert alert-danger', text: erroMensagem(e) });
    estado.append(criarElemento('div', {}, [msg]));
    return;
  }

  estado.innerHTML = '';
  carregando.remove();

  const cards = [
    { titulo: 'Agendamentos de hoje', valor: String(resumo.hoje), sufixo: 'agendamentos', icone: '🗓', destaque: false },
    { titulo: 'Pendentes', valor: String(resumo.pendentes), sufixo: resumo.pendentes === 1 ? 'pendente' : 'pendentes', icone: '⏳', destaque: false },
    { titulo: 'Confirmados', valor: String(resumo.confirmados), sufixo: resumo.confirmados === 1 ? 'confirmado' : 'confirmados', icone: '✓', destaque: false },
    { titulo: 'Faturamento previsto de hoje', valor: resumo.faturamentoFormatado, sufixo: 'em serviços do dia', icone: 'R$', destaque: true },
  ];

  for (const card of cards) {
    grade.append(
      criarElemento('article', { class: `card dashboard-card${card.destaque ? ' destaque' : ''}` }, [
        criarElemento('div', { class: 'dashboard-card-topo' }, [
          criarElemento('span', { class: 'dashboard-card-rotulo', text: card.titulo }),
          criarElemento('span', { class: 'dashboard-card-icone', 'aria-hidden': 'true', text: card.icone }),
        ]),
        criarElemento('span', { class: 'dashboard-card-valor', text: card.valor }),
        criarElemento('span', { class: 'dashboard-card-sufixo', text: card.sufixo }),
      ])
    );
  }

  if (resumo.cancelados > 0) {
    estado.append(
      criarElemento('p', {
        class: 'dashboard-obs',
        text: `${resumo.cancelados} agendamento(s) cancelado(s) hoje não entram no faturamento previsto.`,
      })
    );
  }
}

function formatarDataHoje() {
  return new Intl.DateTimeFormat('pt-BR', {
    weekday: 'long',
    day: 'numeric',
    month: 'long',
    year: 'numeric',
  }).format(new Date());
}

function erroMensagem(erro) {
  const msg = textoClaro(erro?.message);
  if (msg.toLowerCase().includes('permission denied') || msg.toLowerCase().includes('row-level security')) {
    return 'Sem permissão para consultar os dados. Verifique se o usuário está vinculado à barbearia.';
  }
  return `Não foi possível carregar o resumo do dia. Detalhe: ${msg}`;
}