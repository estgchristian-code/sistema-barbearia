import { supabase } from '../lib/supabase.js';

export async function loginComEmailSenha(email, senha) {
  const e = String(email || '').trim();
  const s = String(senha || '');

  if (!e) throw new Error('Informe o e-mail.');
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e)) throw new Error('Informe um e-mail válido.');
  if (!s) throw new Error('Informe a senha.');

  const { data, error } = await supabase.auth.signInWithPassword({ email: e, password: s });
  if (error) throw error;
  return data;
}

export async function logout() {
  const { error } = await supabase.auth.signOut();
  if (error) throw error;
}

export async function obterUsuarioAutenticado() {
  const { data, error } = await supabase.auth.getUser();
  if (error) return null;
  return data.user;
}

export function observarMudancasDeSessao(callback) {
  const { data } = supabase.auth.onAuthStateChange((evento, sessao) => {
    callback(evento, sessao);
  });
  return data.subscription.unsubscribe;
}