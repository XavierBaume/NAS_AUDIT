#!/usr/bin/env bash
# Attention : macOS-friendly

set -euo pipefail
ROOTS=()

# Paramètres & aide
usage() {
  cat <<'EOF'
Usage:
  ./reiss_hashes_scans_multi_incremental_blake3.sh \
    -o /chemin/vers/output.csv \
    -j <jobs_paralleles> \
    -n <taille_batch> \
    [--allow-dirs-only] \
    "/racine/1" "/racine/2" ...

Env vars utiles:
  B3FLAGS   : options b3sum (ex: "--num-threads 1 --no-mmap")
  PARALLEL  : options GNU parallel additionnelles (ex: "--bar --eta --joblog /tmp/xxx.tsv")

Notes:
  - Étape 1: sélection 
  - Étape 2: hash en parallèle 
  - Étape 3: export CSV 
  - Étape 4: empreintes de dossiers 
EOF
}

OUT_CSV=""
JOBS=2
BATCH=4
ALLOW_DIRS_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) OUT_CSV="$2"; shift 2 ;;
    -j) JOBS="$2"; shift 2 ;;
    -n) BATCH="$2"; shift 2 ;;
    --allow-dirs-only) ALLOW_DIRS_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "Option inconnue: $1" >&2; usage; exit 1 ;;
    *) break ;;
  esac
done

if [[ -z "${OUT_CSV}" || $# -lt 1 ]]; then
  usage; exit 1
fi

# --------- Exclusions (fichiers / dossiers) ---------
# Dossiers à ignorer (prune dans find + skip dans fingerprint)
EXCLUDE_DIRS=(
  "@eaDir"
  ".Spotlight-V100"
  ".fseventsd"
  ".Trashes"
  ".AppleDouble"
  ".git"
  "__pycache__"
  "node_modules"
)

# Motifs de fichiers à ignorer (extensions + fichiers spéciaux)
EXCLUDE_GLOBS=(
  "*.tmp" "*.bak" "*.log" "*.ini" "*.json" "*.xml" "*.yaml" "*.cfg"
  "*.db" "*.thm" "*.thumb" "*.cache" "*.old" "*.lock"
  "*.zip" "*.rar" "*.7z" "*.tar" "*.gz" "*.bz2" "*.xz" "*.tgz" "*.iso"
  ".DS_Store" "Thumbs.db" "desktop.ini"
  "._*"
)

# Test rapide pour savoir si un chemin doit être exclu (fichier)
should_exclude_file() {
  local p="${1##*/}"   # nom de base
  for g in "${EXCLUDE_GLOBS[@]}"; do
    [[ "$p" == $g ]] && return 0
  done
  return 1
}

# Test pour les dossiers (par nom de base uniquement)
should_exclude_dir() {
  local d="${1##*/}"
  for n in "${EXCLUDE_DIRS[@]}"; do
    [[ "$d" == "$n" ]] && return 0
  done
  return 1
}
# ----------------------------------------------------

# Normalise la liste des racines même si le lanceur a tout collé en un seul argument
normalize_roots() {
  local raw="$1"
  local normalized
  normalized="$(printf '%s' "$raw" | tr '\r\t' '\n' | sed 's#//#\n/#g')"

  ROOTS=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    ROOTS+=("$line")
  done <<< "$normalized"
}

if (( $# == 1 )); then
  if [[ "$1" == *"//"* || "$1" == *$'\n'* || "$1" == *$'\r'* || "$1" == *$'\t'* ]]; then
    normalize_roots "$1"
  else
    ROOTS=("$1")
  fi
else
  ROOTS=("$@")
fi

: "${ROOTS:=()}"
if (( ${#ROOTS[@]} == 0 )); then
  echo "Erreur : aucun dossier racine fourni. Passe au moins un chemin." >&2
  exit 2
fi

# (Optionnel) Debug
{
  echo "ARGV normalisés :"
  for a in "${ROOTS[@]-}"; do echo " - [$a]"; done
} >&2

# Keep-alive SMB/NFS (optionnel)
KEEPALIVE_ENABLE="${KEEPALIVE_ENABLE:-1}"
KEEPALIVE_INTERVAL="${KEEPALIVE_INTERVAL:-30}"
KEEPALIVE_CAFFEINATE="${KEEPALIVE_CAFFEINATE:-0}"

mountpoint_of() {
  df -P -- "$1" 2>/dev/null | awk 'NR==2 {print $NF}'
}

MOUNTS=()
for r in "${ROOTS[@]:-}"; do
  [[ -e "$r" ]] || continue
  mp="$(mountpoint_of "$r")"
  if [[ -n "${mp:-}" ]]; then
    already=0
    for m in "${MOUNTS[@]-}"; do
      [[ "$m" == "$mp" ]] && already=1 && break
    done
    [[ $already -eq 0 ]] && MOUNTS+=("$mp")
  fi
done

keepalive_loop() {
  while :; do
    for m in "${MOUNTS[@]-}"; do
      if [[ -d "$m" ]]; then
        stat -f %m -- "$m" >/dev/null 2>&1 || ls -ld  "$m" >/dev/null 2>&1 || true
      fi
    done
    sleep "$KEEPALIVE_INTERVAL"
  done
}

KEEPALIVE_PID=""
CAFFEINATE_PID=""

start_keepalive() {
  if [[ "$KEEPALIVE_CAFFEINATE" -eq 1 ]] && command -v caffeinate >/dev/null 2>&1; then
    caffeinate -dimsu &
    CAFFEINATE_PID="$!"
  fi
  keepalive_loop &
  KEEPALIVE_PID="$!"
}

stop_keepalive() {
  [[ -n "$KEEPALIVE_PID" ]] && kill "$KEEPALIVE_PID" 2>/dev/null || true
  [[ -n "$CAFFEINATE_PID" ]] && kill "$CAFFEINATE_PID" 2>/dev/null || true
}

_on_exit_actions=()
add_on_exit() { _on_exit_actions+=("$*"); }
run_on_exit() { for a in "${_on_exit_actions[@]-}"; do eval "$a"; done; }

if [[ "$KEEPALIVE_ENABLE" -eq 1 && "${#MOUNTS[@]}" -gt 0 ]]; then
  start_keepalive
  add_on_exit "stop_keepalive"
fi

# Dépendances & chemins
if ! command -v b3sum >/dev/null 2>&1; then
  echo "Erreur: b3sum introuvable. Installe b3sum (BLAKE3)." >&2
  exit 1
fi
HAS_PARALLEL=0
if command -v parallel >/dev/null 2>&1; then
  HAS_PARALLEL=1
fi

B3FLAGS="${B3FLAGS:-}"
PARALLEL_OPTS="${PARALLEL:-}"

# xattr
ATTR_HASH="com.uniris.blake3"
ATTR_STAMP="com.uniris.stamp"   # ex: "<size>:<mtime>"

# Dossier temporaire d’exécution
RUN_TMP="$(mktemp -d -t reiss_b3_XXXXXX)"
trap 'run_on_exit' EXIT
add_on_exit 'rm -rf "$RUN_TMP"'

TO_HASH_NUL="$RUN_TMP/to_hash.lst.nul"        # liste NUL des fichiers à (re)hasher
NEW_HASHES_TXT="$RUN_TMP/new_hashes.tsv"      # sortie TSV: hash \t size \t mtime \t path
PATH2HASH_TSV="$RUN_TMP/path2hash.tsv"        # mapping: hash \t path (tous fichiers connus)
: > "$TO_HASH_NUL"
: > "$NEW_HASHES_TXT"
: > "$PATH2HASH_TSV"

# Log des fichiers introuvables pendant le hash
MISS_LOG="$RUN_TMP/missing.tsv"               # TSV: timestamp \t reason \t path
: > "$MISS_LOG"

# Export des missings (CSV final)
MISS_CSV="${OUT_CSV%.csv}.missing.csv"

############################################
#              Utilitaires                 #
############################################
normpath() { echo "$1"; }

file_stamp() { # "<size>:<mtime>"
  local fp="$1"
  local sz mt
  sz="$(stat -f %z -- "$fp" 2>/dev/null)" || return 1
  mt="$(stat -f %m -- "$fp" 2>/dev/null)" || return 1
  printf "%s:%s" "$sz" "$mt"
}

get_xattr() {
  local key="$1" fp="$2"
  xattr -p "$key" -- "$fp" 2>/dev/null || true
}

set_xattr() {
  local key="$1" val="$2" fp="$3"
  xattr -w "$key" "$val" -- "$fp" 2>/dev/null || true
}

# --- Formatage des dates mtime ---
MTIME_FORMAT="${MTIME_FORMAT:-%Y-%m-%d %H:%M:%S}"  # Format lisible
MTIME_TZ="${MTIME_TZ:-UTC}"                        # "UTC" ou "LOCAL"

fmt_mtime() {
  local ts="$1"
  if [[ -z "$ts" ]]; then
    echo ""
    return 0
  fi
  if [[ "$MTIME_TZ" == "UTC" ]]; then
    date -u -r "$ts" "+$MTIME_FORMAT" 2>/dev/null || echo ""
  else
    date -r "$ts" "+$MTIME_FORMAT" 2>/dev/null || echo ""
  fi
}

############################################
#         Étape 1 — Sélection              #
############################################
echo " Étape 1/4: sélection fichiers et dossiers…"

file_count=0
dir_count=0

ALL_DIRS_NUL="$RUN_TMP/all_dirs.lst.nul"
: > "$ALL_DIRS_NUL"

for root in "${ROOTS[@]-}"; do
  if [[ ! -e "$root" ]]; then
    echo "️  Racine introuvable (ignorée): $root" >&2
    continue
  fi

  # Construit l’expression -prune pour BSD find (macOS)
  prune_expr=()
  for dname in "${EXCLUDE_DIRS[@]}"; do
    prune_expr+=(-name "$dname" -o)
  done

  # Dossiers (avec prune)
  if ((${#prune_expr[@]})); then
    # shellcheck disable=SC2206
    find "$root" \( ${prune_expr[@]} -false \) -prune -o -type d -print0 2>/dev/null >> "$ALL_DIRS_NUL" || true
  else
    find "$root" -type d -print0 2>/dev/null >> "$ALL_DIRS_NUL" || true
  fi

  # Fichiers candidats (avec prune + filtrage par glob)
  while IFS= read -r -d '' f; do
    # Exclut par motif (nom de base)
    if should_exclude_file "$f"; then
      continue
    fi

    ((file_count++))

    if [[ $ALLOW_DIRS_ONLY -eq 1 ]]; then
      continue
    fi

    st="$(file_stamp "$f" || true)" || true
    if [[ -z "${st}" ]]; then
      # Fichier devenu inaccessible entre-temps ; on laissera l’étape 2 gérer
      printf "%s\0" "$f" >> "$TO_HASH_NUL"
      continue
    fi

    old_st="$(get_xattr "$ATTR_STAMP" "$f")"
    if [[ "$st" == "$old_st" ]]; then
      :
    else
      printf "%s\0" "$f" >> "$TO_HASH_NUL"
    fi
  done < <(
    if ((${#prune_expr[@]})); then
      find "$root" \( ${prune_expr[@]} -false \) -prune -o -type f -print0 2>/dev/null
    else
      find "$root" -type f -print0 2>/dev/null
    fi
  ) || true
done

# Compte dossiers
if [[ -s "$ALL_DIRS_NUL" ]]; then
  dir_count=$(tr -cd '\0' < "$ALL_DIRS_NUL" | wc -c | awk '{print $1}')
fi

sel_count=0
if [[ -s "$TO_HASH_NUL" ]]; then
  sel_count=$(tr -cd '\0' < "$TO_HASH_NUL" | wc -c | awk '{print $1}')
fi

echo "   → $file_count fichiers recensés | $dir_count dossiers"
if [[ $ALLOW_DIRS_ONLY -eq 0 ]]; then
  echo "   → $sel_count fichiers retenus pour hash"
fi

############################################
#   Étape 2 — Incrémental & hash BLAKE3    #
############################################
echo " Étape 2/4: Processus de hashing ..."

HASHCMD="b3sum ${B3FLAGS}"

robust_worker() {
  for fp in "$@"; do
    if [[ ! -e "$fp" ]]; then
      sleep 0.1
      if [[ ! -e "$fp" ]]; then
        printf "%s\tENOENT\t%s\n" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$(normpath "$fp")" >> "$MISS_LOG"
        continue
      fi
    fi

    local sz mt
    sz="$(stat -f %z -- "$fp" 2>/dev/null)" || {
      printf "%s\tSTATFAIL\t%s\n" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$(normpath "$fp")" >> "$MISS_LOG"
      continue
    }
    mt="$(stat -f %m -- "$fp" 2>/dev/null)" || {
      printf "%s\tSTATFAIL\t%s\n" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$(normpath "$fp")" >> "$MISS_LOG"
      continue
    }

    local out h
    if ! out=$($HASHCMD -- "$fp" 2>&1); then
      if grep -qi "No such file or directory" <<<"$out"; then
        printf "%s\tENOENT\t%s\n" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$(normpath "$fp")" >> "$MISS_LOG"
      else
        printf "%s\tHASHERR\t%s\n" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$(normpath "$fp")" >> "$MISS_LOG"
      fi
      continue
    fi
    h="$(awk '{print $1}' <<<"$out")"

    set_xattr "$ATTR_HASH" "$h" "$fp"
    set_xattr "$ATTR_STAMP" "${sz}:${mt}" "$fp"

    # TSV: hash \t size \t mtime \t path
    printf "%s\t%s\t%s\t%s\n" "$h" "$sz" "$mt" "$(normpath "$fp")"
  done
}

export -f robust_worker
export ATTR_HASH ATTR_STAMP MISS_LOG HASHCMD B3FLAGS

hash_files_parallel() {
  if [[ $ALLOW_DIRS_ONLY -eq 1 ]]; then
    return 0
  fi

  if [[ $HAS_PARALLEL -eq 1 ]]; then
    export -f normpath file_stamp get_xattr set_xattr
    parallel -0 --quote -j "$JOBS" -n "$BATCH" $PARALLEL_OPTS \
      robust_worker <&0
  else
    xargs -0 -n "$BATCH" -P "$JOBS" bash -c 'robust_worker "$@"' _
  fi
}

# Lancement hash (redirige TSV)
hash_files_parallel < "$TO_HASH_NUL" > "$NEW_HASHES_TXT" || true

# Export CSV des "missings"
if [[ -s "$MISS_LOG" ]]; then
  {
    echo 'timestamp,reason,path'
    gsed -i '408,412c\
    awk -F'\''\t'\'' '\''BEGIN{OFS=","}\
      {\
        gsub(/"/, "\"\"", $3);\
        print $1, $2, "\"" $3 "\""\
      }'\'' "$MISS_LOG"' /Volumes/UNIRIS/89_PERSONNEL/Baume_Xavier/Audit_doublons/hashing_app/hashes_scans3.sh
  } > "$MISS_CSV"
  printf " Missings exportés: %s (%s lignes)\n" "$MISS_CSV" "$(($(wc -l < "$MISS_CSV")-1))"
else
  echo " Missings: 0 fichier"
fi

############################################
#   Étape 3 — Export CSV (fichiers)        #
############################################
echo " Étape 3/4: export CSV des fichiers..."

TMP_FILES_CSV="$RUN_TMP/files_export.csv"
: > "$TMP_FILES_CSV"

exported=0
progress_step=2000

{
  echo "path,type,size_bytes,mtime,hash"

  for root in "${ROOTS[@]-}"; do
    [[ -e "$root" ]] || continue

    # Reconstruit prune_expr localement
    prune_expr2=()
    for dname in "${EXCLUDE_DIRS[@]}"; do prune_expr2+=(-name "$dname" -o); done

    while IFS= read -r -d '' f; do
      # Ignore fichiers exclus
      if should_exclude_file "$f"; then
        continue
      fi

      h="$(get_xattr "$ATTR_HASH" "$f")"
      st="$(get_xattr "$ATTR_STAMP" "$f")"
      if [[ -z "$st" ]]; then
        st="$(file_stamp "$f" || true)" || true
      fi
      sz=""; mt=""; mt_str=""
      if [[ -n "$st" ]]; then
        sz="${st%%:*}"
        mt="${st##*:}"
        mt_str="$(fmt_mtime "$mt")"
      fi
      p="$(normpath "$f")"
      p_esc="${p//\"/\"\"}"

      echo "\"${p_esc}\",file,${sz},\"${mt_str}\",${h}"

      # Alimente path2hash.tsv si hash présent
      if [[ -n "${h:-}" ]]; then
        printf "%s\t%s\n" "$h" "$p" >> "$PATH2HASH_TSV"
      fi

      ((exported++))
      if (( exported % progress_step == 0 )); then
        printf "   → %d fichiers exportés…\n" "$exported" >&2
      fi
    done < <(
      if ((${#prune_expr2[@]})); then
        find "$root" \( ${prune_expr2[@]} -false \) -prune -o -type f -print0 2>/dev/null
      else
        find "$root" -type f -print0 2>/dev/null
      fi
    ) || true
  done
} > "$TMP_FILES_CSV"

echo "    Export fichiers: $exported lignes"

mkdir -p "$(dirname "$OUT_CSV")"
mv -f "$TMP_FILES_CSV" "$OUT_CSV"

# Si on a des nouveaux hashes calculés à l'étape 2, on complète PATH2HASH_TSV
# (utile si certains fichiers n'avaient pas encore d'xattr hash au moment de l'export)
if [[ -s "$NEW_HASHES_TXT" ]]; then
  awk -F'\t' 'BEGIN{OFS="\t"} {print $1, $4}' "$NEW_HASHES_TXT" >> "$PATH2HASH_TSV" || true
fi

############################################
# Étape 4 — Empreintes de dossiers         #
############################################
echo " Étape 4/4: empreintes de dossiers (append dans ${OUT_CSV})..."

dirs_done=0

dir_fingerprint_row() {
  local d="$1"

  local tmp="$RUN_TMP/_df_$$.tsv"
  : > "$tmp"

  shopt -s nullglob
  local f
  for f in "$d"/*; do
    [[ -f "$f" ]] || continue
    # Ignore fichiers exclus
    if should_exclude_file "$f"; then
      continue
    fi
    # Récupère le hash depuis PATH2HASH_TSV (si disponible)
    local h
    h="$(grep -F $'\t'"$f" "$PATH2HASH_TSV" | awk -F'\t' 'END{print $1}')" || true
    [[ -n "$h" ]] && echo "$h" >> "$tmp"
  done
  shopt -u nullglob

  # mtime du dossier
  local d_mt d_mt_str
  d_mt="$(stat -f %m -- "$d" 2>/dev/null || true)"
  d_mt_str=""
  [[ -n "$d_mt" ]] && d_mt_str="$(fmt_mtime "$d_mt")"

  local size_bytes=""
  local d_hash=""
  if [[ -s "$tmp" ]]; then
    d_hash="$(sort "$tmp" | b3sum ${B3FLAGS} | awk '{print $1}')"
  fi
  rm -f "$tmp"

  local p_esc
  p_esc="$(normpath "$d" | sed 's/"/""/g')"
  printf "\"%s\",directory,%s,\"%s\",%s\n" "$p_esc" "$size_bytes" "$d_mt_str" "$d_hash"
}

# Parcourt tous les dossiers collectés (en Step 1) et appende dans OUT_CSV
if [[ -s "$ALL_DIRS_NUL" ]]; then
  while IFS= read -r -d '' d; do
    # Skip dossiers exclus
    if should_exclude_dir "$d"; then
      continue
    fi
    dir_fingerprint_row "$d" >> "$OUT_CSV"
    ((dirs_done++))
  done < "$ALL_DIRS_NUL"
fi

echo "    Dossiers traités: $dirs_done"

# Fin
for r in "${ROOTS[@]-}"; do
  echo " Fini pour: $(normpath "$r")"
done
