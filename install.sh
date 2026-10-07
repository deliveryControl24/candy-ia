#!/usr/bin/env bash
# CANDY IA — instalador oficial
#   curl -fsSL https://github.com/deliveryControl24/candy-ia/main/install.sh | bash
set -euo pipefail

REPO="deliveryControl24/candy-ia"
MODEL="llama3.2:3b"
OLLAMA_URL="https://ollama.com/download/ollama-darwin.tgz"

if [[ -t 1 ]]; then
  C_G=$'\033[32m'; C_C=$'\033[36m'; C_R=$'\033[31m'; C_Y=$'\033[33m'; C_0=$'\033[0m'
else
  C_G=""; C_C=""; C_R=""; C_Y=""; C_0=""
fi
ok()    { printf '  %s✔%s %s\n' "$C_G" "$C_0" "$1"; }
info()  { printf '  %s›%s %s\n' "$C_C" "$C_0" "$1"; }
warn()  { printf '  %s!%s %s\n' "$C_Y" "$C_0" "$1"; }
die()   { printf '  %s✘%s %s\n' "$C_R" "$C_0" "$1" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

printf '%sCANDY IA%s — instalador\n' "$C_C" "$C_0"

# 1 ── sistema
[[ "$(uname -s)" == "Darwin" ]] || die "Este instalador es solo para macOS."
MACOS_MAJOR="$(sw_vers -productversion | cut -d. -f1)"
[[ "$MACOS_MAJOR" =~ ^[0-9]+$ ]] || die "No pude leer la versión de macOS."
(( MACOS_MAJOR >= 14 )) || die "Se requiere macOS 14 o superior (tienes $(sw_vers -productversion))."
ARCH="$(uname -m)"
info "macOS $(sw_vers -productversion) · $ARCH"

# 2 ── descargar la app
info "Descargando CANDY IA…"
DL_URL="https://github.com/${REPO}/releases/latest/download/CandyIA.dmg"
if ! curl -fL --progress-bar "$DL_URL" -o "$TMP/CandyIA.dmg"; then
  die "No pude descargar $DL_URL — ¿existe una release publicada?"
fi
ok "Descarga completa"

# 3 ── instalar en /Applications
info "Instalando en /Applications…"
hdiutil attach "$TMP/CandyIA.dmg" -nobrowse -readonly -mountpoint "$TMP/mnt" >/dev/null || die "No pude montar el DMG."
rm -rf "/Applications/CandyIA.app"
cp -R "$TMP/mnt/CandyIA.app" "/Applications/"
hdiutil detach "$TMP/mnt" >/dev/null || true
xattr -dr com.apple.quarantine "/Applications/CandyIA.app" 2>/dev/null || true
codesign --verify --deep --strict "/Applications/CandyIA.app" 2>/dev/null \
  && ok "CANDY IA instalada en /Applications" \
  || warn "La app está instalada; puede pedir confirmación de seguridad en la primera apertura."

# 4 ── Ollama
HAVE_OLLAMA=0
if command -v ollama >/dev/null 2>&1 || [[ -x /usr/local/bin/ollama ]]; then
  HAVE_OLLAMA=1
fi
if (( HAVE_OLLAMA == 0 )); then
  info "Instalando Ollama (motor de IA local)…"
  curl -fL --progress-bar "$OLLAMA_URL" -o "$TMP/ollama.tgz"
  SUDO=""
  [[ "$EUID" -eq 0 ]] || SUDO="sudo"
  $SUDO mkdir -p /usr/local/lib/ollama
  $SUDO tar -xzf "$TMP/ollama.tgz" -C /usr/local/lib/ollama
  $SUDO ln -sf /usr/local/lib/ollama/ollama /usr/local/bin/ollama
  ok "Ollama instalado"
fi

OLLAMA_BIN="/usr/local/bin/ollama"
command -v ollama >/dev/null 2>&1 && OLLAMA_BIN="$(command -v ollama)"

# 5 ── servidor
if ! curl -s --max-time 2 http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
  info "Arrancando el servidor de Ollama…"
  nohup "$OLLAMA_BIN" serve >/dev/null 2>&1 &
  for _ in $(seq 1 15); do
    curl -s --max-time 1 http://127.0.0.1:11434/api/version >/dev/null 2>&1 && break
    sleep 1
  done
  ok "Servidor listo"
fi

# 6 ── modelo
# Respaldo IPv4: en redes sin ruta IPv6 el pull de Ollama falla
# ("network is unreachable"). Descarga los blobs con curl -4 e instala el manifiesto.
descargar_modelo_ipv4() {
  command -v python3 >/dev/null 2>&1 || return 1
  info "Reintentando la descarga del modelo con IPv4…"
  curl -fsSL "https://raw.githubusercontent.com/${REPO}/main/tools/seed_models.py" \
    -o "$TMP/seed_models.py" || return 1
  python3 "$TMP/seed_models.py" "$MODEL" >/dev/null 2>&1
}

if ! "$OLLAMA_BIN" list 2>/dev/null | grep -q "^llama3.2"; then
  info "Descargando el modelo $MODEL (~2 GB, la primera vez tarda)…"
  if "$OLLAMA_BIN" pull "$MODEL" >/dev/null 2>&1; then
    ok "Modelo $MODEL listo"
  elif descargar_modelo_ipv4; then
    ok "Modelo $MODEL listo (vía IPv4)"
  else
    warn "No pude descargar el modelo ahora; CANDY IA lo reintentará al abrir."
  fi
else
  ok "Modelo $MODEL ya instalado"
fi

# 7 ── abrir
info "Abriendo CANDY IA…"
open "/Applications/CandyIA.app" || true

printf '\n%s✔ Listo.%s Disfruta CANDY IA — escribe, o pulsa el micrófono y háblale.\n' "$C_G" "$C_0"
