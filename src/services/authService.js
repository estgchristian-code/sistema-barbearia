import { supabase } from '../lib/supabase.js';

export async function loginComEmailSenha(email, senha) {
  const { data, error } = await supabase.auth.signInWithPassword({ email, password: senha });
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