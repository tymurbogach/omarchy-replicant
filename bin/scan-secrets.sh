#!/bin/bash
# Único sitio donde viven los patrones de credencial. Lo usan .githooks/pre-commit
# (sobre el contenido preparado para el commit) y bin/backup.sh (sobre lo que acaba
# de copiar del sistema). Antes cada uno tenía su lista y ya habían divergido.
#
#   bin/scan-secrets.sh config state        escanea rutas
#   ... | bin/scan-secrets.sh --stdin RUTA  escanea la entrada, etiquetada como RUTA
#
# Sale 1 si encuentra algo. secrets/ no se escanea nunca: ahí van credenciales
# reales por decisión explícita (CLAUDE.md § Regla 0).

set -uo pipefail

# Marcadores que indican "esto es un hueco, no un secreto real".
PLACEHOLDER='<[^>]+>|REDACTED|EJEMPLO|EXAMPLE|xxxxx|\.\.\.|PON_AQUI|TU_'

# patrón:descripción
PATTERNS=(
  'ghp_[A-Za-z0-9]{36}:token clásico de GitHub'
  'github_pat_[A-Za-z0-9_]{22,}:token fine-grained de GitHub'
  'AIza[0-9A-Za-z_-]{35}:API key de Google'
  'GOCSPX-[A-Za-z0-9_-]{20,}:client secret de Google OAuth'
  'sk-ant-[A-Za-z0-9_-]{20,}:API key de Anthropic'
  'BEGIN [A-Z ]*PRIVATE KEY:clave privada'
  'APP_KEY=base64:[A-Za-z0-9+/=]{40,}:APP_KEY de Laravel'
  '^[[:space:]]*password[[:space:]]*=[[:space:]]*[^<[:space:]].*:contraseña en claro'
  'aws_secret_access_key[[:space:]]*=[[:space:]]*[A-Za-z0-9/+]{20,}:secret de AWS'
)

fail=0

# Imprime los aciertos de un patrón y marca el fallo. La cabecera lleva la etiqueta
# de dónde vino: en modo --stdin es la ruta; escaneando rutas ya la trae cada línea.
reportar() {
  local cabecera=$1 hits=$2
  [[ -n $hits ]] || return 0
  echo "✗ $cabecera"
  printf '%s\n' "$hits" | sed 's/^/    /'
  fail=1
}

if [[ ${1:-} == --stdin ]]; then
  etiqueta=${2:-entrada}
  contenido=$(cat)

  for entry in "${PATTERNS[@]}"; do
    hits=$(printf '%s\n' "$contenido" | grep -nE "${entry%:*}" | grep -vE "$PLACEHOLDER") || true
    reportar "$etiqueta — ${entry##*:}" "$hits"
  done
else
  (( $# )) || { echo "uso: $0 RUTA... | $0 --stdin RUTA" >&2; exit 2; }

  for entry in "${PATTERNS[@]}"; do
    hits=$(grep -rnE --exclude-dir=.git --exclude-dir=secrets "${entry%:*}" "$@" 2>/dev/null \
      | grep -vE "$PLACEHOLDER") || true
    reportar "${entry##*:}" "$hits"
  done
fi

exit $fail
