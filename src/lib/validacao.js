// Validadores de negócio compartilhados pela aplicação.
//
// Centraliza regras usadas por mais de um módulo (ex.: telefone brasileiro) a
// fim de evitar duplicação e dependências circulares entre os services.

// Normaliza um telefone para apenas dígitos (DDD + número). Mantém a
// formatação opcional na interface; a validação sempre usa o número normalizado.
export function normalizarTelefone(telefone) {
  return String(telefone ?? '').replace(/\D/g, '');
}

// Valida um telefone brasileiro pela quantidade de dígitos (DDD + número):
// celular com 9 dígitos (11 totais) ou fixo com 8 dígitos (10 totais).
// Retorna a mensagem de erro ou null se válido. Não aceita vazio.
export function validarTelefoneBrasileiro(telefone) {
  const digitos = normalizarTelefone(telefone);
  if (!digitos) return 'Informe o telefone.';
  if (digitos.length !== 10 && digitos.length !== 11) {
    return 'Telefone inválido. Informe o DDD seguido do número (10 ou 11 dígitos).';
  }
  return null;
}
