import { supabase } from '../lib/supabase.js';

export async function testarConexao() {
  try {
    const { data } = await supabase.auth.getSession();
    if (!data.session) {
      return { conectado: true, autenticado: false, usuario: null };
    }

    const { data: usuario, error } = await supabase.auth.getUser();
    if (error) {
      return { conectado: false, autenticado: true, erro: error.message };
    }
    return { conectado: true, autenticado: true, usuario };
  } catch (erro) {
    return { conectado: false, autenticado: false, erro: erro.message };
  }
}