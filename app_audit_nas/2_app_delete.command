#!/usr/bin/env bash
# delete_from_json.command — Bash 5.x, agit UNIQUEMENT sur le JSON sélectionné.
set -Eeuo pipefail

# ---------- Vérification / basculement Bash 5 ----------
REQUIRED_MAJOR=5

# Si le Bash actuel est plus vieux que 5
if (( BASH_VERSINFO[0] < REQUIRED_MAJOR )); then
  HOMEBREW_BASH="/opt/homebrew/bin/bash"
  if [[ -x "$HOMEBREW_BASH" ]]; then
    echo " Passage à Bash Homebrew (version récente)..."
    exec "$HOMEBREW_BASH" "$0" "$@"
  else
    osascript -e 'display alert "Version Bash obsolète" message "Votre macOS utilise une ancienne version Bash.  
Ouvrez le terminal de commande et installez une version récente avec :  brew install bash" as critical'
    exit 1
  fi
fi

# ---------- Détection de python3 ----------
PYTHON_BIN="$(command -v python3 || true)"
if [[ -z "${PYTHON_BIN}" ]]; then
  # chemins courants selon la machine
  for cand in /opt/homebrew/bin/python3 /usr/local/bin/python3 /Library/Frameworks/Python.framework/Versions/3.*/bin/python3; do
    PYTHON_BIN="$(ls -1d $cand 2>/dev/null | head -n1 || true)"
    [[ -n "${PYTHON_BIN}" ]] && break
  done
fi
if [[ -z "${PYTHON_BIN}" ]]; then
  osascript -e 'display alert "Python 3 introuvable" message "Installez Python 3 via Homebrew puis réessayez." as critical'
  exit 1
fi

# Script Python attendu : à côté du .command
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PY_SCRIPT="$SCRIPT_DIR/delete_from_json.py"
if [[ ! -f "$PY_SCRIPT" ]]; then
  osascript -e 'display alert "Fichier manquant" message "delete_from_json.py est introuvable à côté du .command." as critical'
  exit 1
fi

# ---------- Utilitaires AppleScript ----------
alert_warn() { osascript -e 'display alert "Info" message "'"$1"'" as warning'; }
notify()     { osascript -e 'display notification "'"$1"'" with title "delete_from_json"'; }

choose_json() {
  osascript <<'OSA'
    try
      set f to choose file with prompt "Sélectionne le fichier JSON (liste de chemins à supprimer)" of type {"public.json", "public.text"}
      return POSIX path of f
    on error number -128
      return ""
    end try
OSA
}

choose_mode() {
  osascript <<'OSA'
    try
      set dlg to display dialog "Choisis le mode d'exécution :" buttons {"Supprimer définitivement", "Simulation de suppression"} default button "Simulation de suppression" with icon note
      return button returned of dlg
    on error number -128
      return "CANCEL"
    end try
OSA
}

confirm_force() {
  osascript <<'OSA'
    try
      set dlg to display dialog "⚠️ Cette opération supprimera les fichiers listés dans le JSON.\n\nPour confirmer, écris OUI en majuscules." default answer "" buttons {"Annuler", "Confirmer"} default button "Annuler" with icon caution
      set t to text returned of dlg
      if t is "OUI" then
        return "OK"
      else
        return "NOK"
      end if
    on error number -128
      return "CANCEL"
    end try
OSA
}

# ---------- 1) Sélection du JSON ----------
JSON_PATH="$(choose_json)"
if [[ -z "$JSON_PATH" ]]; then
  alert_warn "Aucun fichier JSON sélectionné. Opération annulée."
  exit 0
fi
if [[ ! -r "$JSON_PATH" ]]; then
  osascript -e 'display alert "Erreur" message "Le fichier JSON sélectionné n’est pas lisible." as critical'
  exit 1
fi

# ---------- 2) Choix du mode & confirmation ----------
MODE="$(choose_mode)"
if [[ "$MODE" == "CANCEL" ]]; then
  alert_warn "Aucune opération effectuée."
  exit 0
fi
FORCE=0
if [[ "$MODE" == "Supprimer (--force)" ]]; then
  case "$(confirm_force)" in
    OK)  FORCE=1 ;;
    *)   alert_warn "Suppression réelle non confirmée. Opération annulée." ; exit 0 ;;
  esac
fi

# ---------- 3) Log à côté du JSON ----------
JSON_DIR="$(dirname "$JSON_PATH")"
JSON_BASE="$(basename "$JSON_PATH")"
TS="$(date +'%Y%m%d_%H%M%S')"
LOG_PATH="$JSON_DIR/${JSON_BASE%.*}_delete_log_${TS}.txt"

# ---------- 4) Exécution ----------
notify "Exécution en cours…"

echo "=== delete_from_json ==="
echo "JSON : $JSON_PATH"
if (( FORCE == 1 )); then
  echo "MODE : --force (suppression réelle)"
else
  echo "MODE : dry-run (simulation)"
fi
echo "LOG  : $LOG_PATH"
echo "-------------------------------------------"
echo ""

if (( FORCE == 1 )); then
  "$PYTHON_BIN" "$PY_SCRIPT" "$JSON_PATH" --force --log "$LOG_PATH" || true
else
  "$PYTHON_BIN" "$PY_SCRIPT" "$JSON_PATH" --log "$LOG_PATH" || true
fi

echo ""
echo "=== Fin ==="
echo "Log enregistré dans : $LOG_PATH"
notify "Exécution terminée."

read -p "Appuie sur [Entrée] pour fermer cette fenêtre..."
