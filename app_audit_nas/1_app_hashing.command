#!/usr/bin/env bash
# hashing_app.command — Launcher cliquable pour reiss_hashes_scans_multi_incremental_blake3.sh
#
# Caractéristiques :
# - Valeurs par défaut silencieuses (jobs/batch/B3FLAGS/parallel : pas de boîtes)
# - Sélection des dossiers à scanner en plusieurs tours (OK pour ajouter, Annuler pour terminer)
# - Choix d’un dossier parent ; le launcher crée un sous-dossier dédié au run (Option A)
# - Lance le script dans Terminal avec une commande passée via variable d’environnement
#
# Résultat :
#   <DOSSIER_PARENT>/hashing_run_YYYYMMDD_HHMMSS/
#       ├─ audit_hashes.csv
#       ├─ audit_hashes.missing.csv
#       └─ audit_hashes.dirs.csv
#
# Remarques :
# - Le script Python archifiltre_like_visualization_echarts3.py doit être à côté de ce fichier .command.

echo " Début du test d'installation des dépendances"
echo "----------------------------------------------"

# Étape 1 — Homebrew
if command -v brew >/dev/null 2>&1; then
  echo " Homebrew est déjà installé à : $(command -v brew)"
else
  echo " Homebrew n'est pas installé. Installation en cours..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  echo "Ajout de /opt/homebrew/bin au PATH si nécessaire."
  export PATH="/opt/homebrew/bin:$PATH"
fi

# Étape 2 — b3sum
if command -v b3sum >/dev/null 2>&1; then
  echo " b3sum déjà présent : $(command -v b3sum)"
else
  echo " b3sum non trouvé. Installation en cours..."
  if command -v brew >/dev/null 2>&1; then
    brew install b3sum
  elif command -v apt >/dev/null 2>&1; then
    sudo apt install b3sum
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install b3sum
  elif command -v pacman >/dev/null 2>&1; then
    sudo pacman -S b3sum
  fi
fi

# Étape 3 — GNU parallel
if command -v parallel >/dev/null 2>&1; then
  echo " GNU parallel déjà présent : $(command -v parallel)"
else
  echo " GNU parallel non trouvé. Installation en cours..."
  if command -v brew >/dev/null 2>&1; then
    brew install parallel
  elif command -v apt >/dev/null 2>&1; then
    sudo apt install parallel
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install parallel
  elif command -v pacman >/dev/null 2>&1; then
    sudo pacman -S parallel
  else
    echo " Aucun gestionnaire de paquets compatible trouvé pour installer GNU parallel."
  fi
fi
# Eviter la demande de citation
# parallel --citation >/dev/null 2>&1 || true
parallel --citation <<<"will cite" >/dev/null 2>&1 || true


# Étape 4 — gsed
if command -v gsed >/dev/null 2>&1; then
  echo " gsed déjà présent : $(command -v gsed)"
else
  echo " gsed non trouvé. Installation en cours..."
  if command -v brew >/dev/null 2>&1; then
    brew install gsed
  elif command -v apt >/dev/null 2>&1; then
    sudo apt install gsed
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install gsed
  elif command -v pacman >/dev/null 2>&1; then
    sudo pacman -S gsed
  else
    echo " Aucun gestionnaire de paquets compatible trouvé pour installer gsed."
  fi
fi
# Étape 5 — Python 3.11
if command -v python3.11 >/dev/null 2>&1; then
  echo " Python 3.11 déjà présent : $(command -v python3.11)"
else
  echo " Python 3.11 non trouvé. Installation en cours..."
  if command -v brew >/dev/null 2>&1; then
    brew install python@3.11
  elif command -v apt >/dev/null 2>&1; then
    sudo apt update && sudo apt install -y python3.11 python3.11-venv python3.11-dev
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y python3.11 python3.11-devel
  elif command -v pacman >/dev/null 2>&1; then
    sudo pacman -Sy --noconfirm python
  else
    echo " Aucun gestionnaire de paquets compatible trouvé pour installer Python 3.11."
    echo " Veuillez installer Python 3.11 manuellement depuis https://www.python.org/downloads/."
  fi
fi
# Étape 6 — bash
if command -v bash >/dev/null 2>&1; then
  echo " bash déjà présent : $(command -v bash)"
else
  echo " bash non trouvé. Installation en cours..."
  if command -v brew >/dev/null 2>&1; then
    brew install bash
  elif command -v apt >/dev/null 2>&1; then
    sudo apt install bash
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install bash
  elif command -v pacman >/dev/null 2>&1; then
    sudo pacman -S bash
  else
    echo " Aucun gestionnaire de paquets compatible trouvé pour installer bash."
  fi
fi
# Étape 7 — Outils POSIX
echo " Vérification des outils système requis :"
for cmd in find stat awk xattr df mktemp wc grep ls sort; do
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "    $cmd : $(command -v "$cmd")"
  else
    echo "    $cmd est manquant (utilitaires système)."
  fi
done

echo "----------------------------------------------"
echo "  ===> Choisir l'emplacement du dossier d'audit"
echo

set -euo pipefail

# Réglages par défaut
JOBS_DEFAULT="2"
BATCH_DEFAULT="4"
B3FLAGS_DEFAULT="--num-threads 1 --no-mmap"
PARALLEL_DEFAULT='--bar --eta --joblog /tmp/reiss_joblog.'$(date +%s)'.tsv'
CSV_BASENAME_DEFAULT="audit_hashes.csv"
RUN_DIR_PREFIX="hashing_run_"

# Bash
BASH_BIN="/opt/homebrew/bin/bash"
[[ -x "$BASH_BIN" ]] || BASH_BIN="/bin/bash"

# Dossiers & scripts
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/hashes_scans.sh"
PY_SCRIPT="$HERE/three_visu.py"

# Vérifs script principal
if [[ ! -f "$SCRIPT" ]]; then
  osascript -e 'display dialog "Script principal introuvable :\n'"$SCRIPT"'" buttons {"OK"} with icon stop'
  exit 1
fi
if [[ ! -x "$SCRIPT" ]]; then
  chmod +x "$SCRIPT" 2>/dev/null || true
fi

# Choix du dossier parent
OUT_DIR_PARENT=$(osascript <<'APPLESCRIPT'
set theFolder to choose folder with prompt "Choisis le dossier parent où stocker les exports (un sous-dossier sera créé automatiquement)"
POSIX path of theFolder
APPLESCRIPT
) || exit 1

# Dossier de run
RUN_TAG="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${OUT_DIR_PARENT%/}/${RUN_DIR_PREFIX}${RUN_TAG}"
mkdir -p "$OUT_DIR"

# Chemins de sortie
OUT_PATH="$OUT_DIR/$CSV_BASENAME_DEFAULT"
HTML_OUT="$OUT_DIR/tree_paths.html"
TITLE="Audit hashing ${RUN_TAG}"

# Sélection des racines (multi-tours)
ROOTS=$(osascript <<'APPLESCRIPT'
set outList to {}
repeat
  try
    set picked to choose folder with prompt "Sélectionne les dossiers un à un sur le NAS (ne pas utiliser la sélection multiple avec Maj)" & return & "OK pour ajouter, Annuler pour terminer la sélection" with multiple selections allowed
    repeat with f in picked
      set end of outList to POSIX path of f
    end repeat
  on error number -128
    exit repeat
  end try
end repeat
return outList as string
APPLESCRIPT
) || exit 1

# IFS=$'\n' read -r -d '' -a ROOT_ARRAY < <(printf '%s\n' "$ROOTS" | tr ',' '\n' && printf '\0')

# Alternative plus sûre avec retours à la ligne
IFS=$'\n' read -r -d '' -a ROOT_ARRAY < <(
  printf '%s\n' "$ROOTS" | LC_ALL=C tr ',' '\n'
  printf '\0'
)


# ROOTS=$(osascript <<'APPLESCRIPT'
# set outList to {}
# repeat
#   try
#     set picked to choose folder with prompt "Sélectionne un ou plusieurs dossiers l'un après l'autre (Éviter MAJ + sélection multi-dossiers)" & return & "OK pour ajouter, Annuler pour terminer la sélection" with multiple selections allowed
#     repeat with f in picked
#       set end of outList to POSIX path of f
#     end repeat
#   on error number -128
#     exit repeat
#   end try
# end repeat

# -- Retourner la liste séparée par des retours à la ligne (plus sûr pour le shell)
# set oldDelims to AppleScript's text item delimiters
# set AppleScript's text item delimiters to linefeed
# set result to outList as string
# set AppleScript's text item delimiters to oldDelims
# return result
# APPLESCRIPT
# ) || exit 1

# # Remplit ROOT_ARRAY en respectant les retours à la ligne
# IFS=$'\n' read -r -d '' -a ROOT_ARRAY < <(printf '%s\0' "$ROOTS")


if [[ ${#ROOT_ARRAY[@]} -eq 0 ]]; then
  osascript -e 'display dialog "Aucune racine sélectionnée." buttons {"OK"} with icon caution'
  exit 1
fi

# Valeurs silencieuses
JOBS="$JOBS_DEFAULT"
BATCH="$BATCH_DEFAULT"
B3FLAGS="$B3FLAGS_DEFAULT"
PARALLEL_OPTS="$PARALLEL_DEFAULT"

# ---- Post-traitement : venv + exécution Python (HTML) ----------------
POST_SH="$(mktemp -t postviz.XXXXXX)"
cat > "$POST_SH" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

: "${HERE:?HERE manquant}"
: "${OUT_PATH:?OUT_PATH manquant}"
: "${HTML_OUT:?HTML_OUT manquant}"
: "${TITLE:?TITLE manquant}"
: "${PY_SCRIPT:?PY_SCRIPT manquant}"

cd "$HERE"

echo "[POST] Début post-traitement (HTML)…"
if [[ ! -f "$PY_SCRIPT" ]]; then
  echo "[POST][ERREUR] Script Python introuvable : $PY_SCRIPT"
  exit 1
fi

echo "[POST] Attente du CSV: $OUT_PATH"
attempts=0
while [[ ! -s "$OUT_PATH" ]]; do
  attempts=$((attempts+1))
  if (( attempts > 120 )); then
    echo "[POST][ERREUR] CSV introuvable ou vide après 120s: $OUT_PATH"
    exit 1
  fi
  sleep 1
done
echo "[POST] CSV OK"

#PY_BIN="$(command -v python3 || true)"
PY_BIN="$(command -v python3.11 || command -v python3.12 || command -v python3 || true)"
if [[ -z "${PY_BIN}" ]]; then
  echo "[POST][ERREUR] python3 introuvable. Installez-le (ex.: brew install python)."
  exit 1
fi

VENV_DIR="$HOME/Library/Caches/hashing_app/.venv"
VENV_PY="$VENV_DIR/bin/python"

mkdir -p "$HOME/Library/Caches/hashing_app"

if [[ ! -d "$VENV_DIR" ]]; then
  echo "[POST] Création de l'environnement virtuel local ($VENV_DIR)…"
  # --copies évite les liens symboliques fragiles sur certains systèmes
  "$PY_BIN" -m venv --copies "$VENV_DIR" || "$PY_BIN" -m venv "$VENV_DIR" || {
    echo "[POST][ERREUR] Échec de la création de l'environnement virtuel."
    exit 1
  }
fi

if [[ ! -x "$VENV_PY" ]]; then
  echo "[POST][ERREUR] Le Python du venv est introuvable : $VENV_PY"
  exit 1
fi

echo "[POST] Python dans le venv :"
"$VENV_PY" -V

if [[ -f "requirements.txt" ]]; then
  echo "[POST] Installation des dépendances (requirements.txt)…"
  "$VENV_PY" -m pip install --upgrade pip wheel setuptools >/dev/null
  "$VENV_PY" -m pip install -r requirements.txt
else
  echo "[POST] Installation minimale (pandas)…"
  "$VENV_PY" -m pip install --upgrade pip wheel setuptools >/dev/null
  "$VENV_PY" -m pip install pandas
fi

echo "[POST] Génération HTML -> $HTML_OUT"
set -x
"$VENV_PY" "$PY_SCRIPT" --csv "$OUT_PATH" --output "$HTML_OUT" --title "$TITLE"
status=$?
set +x

if (( status != 0 )); then
  echo "[POST][ERREUR] Exécution Python a échoué (code $status)."
  exit $status
fi
if [[ ! -s "$HTML_OUT" ]]; then
  echo "[POST][ERREUR] HTML non généré ou vide: $HTML_OUT"
  exit 1
fi
echo "[POST] Visualisation prête : $HTML_OUT"

if typeset -f deactivate >/dev/null 2>&1; then
  deactivate
fi
EOS
chmod +x "$POST_SH"
# ---------------------------------------------------------------------

# Commande hashing
CMD=(
  "B3FLAGS=$(printf '%q' "$B3FLAGS")"
  "PARALLEL=$(printf '%q' "$PARALLEL_OPTS")"
  "caffeinate -dimsu"
  "$(printf '%q' "$BASH_BIN")"
  "$(printf '%q' "$SCRIPT")"
  -o "$(printf '%q' "$OUT_PATH")"
  -j "$(printf '%q' "$JOBS")"
  -n "$(printf '%q' "$BATCH")"
)
for r in "${ROOT_ARRAY[@]}"; do
  CMD+=("$(printf '%q' "$r")")
done

# Appel du post-traitement SANS dépendre du code retour du hashing
ENV_WRAP=$(
  printf 'HERE=%q OUT_PATH=%q HTML_OUT=%q TITLE=%q PY_SCRIPT=%q %q' \
    "$HERE" "$OUT_PATH" "$HTML_OUT" "$TITLE" "$PY_SCRIPT" "$POST_SH"
)
CMD+=(";" "$ENV_WRAP")

CMD_STR="${CMD[*]}"

# export CMD_STR
# osascript <<'APPLESCRIPT'
# set cmd to do shell script "printenv CMD_STR"
# if cmd is "" then
#   display dialog "Impossible de recuperer la commande (ENV)." buttons {"OK"} with icon stop
#   error number -128
# end if
# tell application "Terminal"
#   activate
#   do script cmd & " ; echo ; echo 'Termine. Appuie sur Entree pour fermer.' ; read -n 1"
# end tell
# APPLESCRIPT

# Écrit la commande dans un fichier temporaire (évite la perte d'env entre shells)
TMP_CMD="$(mktemp -t cmd.XXXXXX)"
printf '%s\n' "$CMD_STR" > "$TMP_CMD"

osascript <<APPLESCRIPT
set cmd to do shell script "cat " & quoted form of POSIX path of "$TMP_CMD"
tell application "Terminal"
  activate
  do script cmd & " ; echo ; echo 'Termine. Appuie sur Entree pour fermer.' ; read -n 1"
end tell
APPLESCRIPT

rm -f "$TMP_CMD"

exit 0
