#!/usr/bin/env python3
import json
import os
import sys
import unicodedata
from pathlib import Path
from datetime import datetime

def normalize_variants(raw: str):
    raw = raw.strip()
    nfc = unicodedata.normalize("NFC", raw)
    nfd = unicodedata.normalize("NFD", raw)
    return [nfc, nfd] if nfc != nfd else [nfc]

def is_under_root(path: Path, root: Path | None) -> bool:
    if root is None:
        return True
    try:
        path = path.resolve(strict=False)
        root = root.resolve(strict=True)
        return root in path.parents or path == root
    except Exception:
        return False

def load_paths(json_path: Path):
    with open(json_path, "r", encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, list) or not all(isinstance(x, str) for x in data):
        raise ValueError("Le JSON doit être une liste de chaînes (chemins).")
    # déduplique en conservant l'ordre
    seen, out = set(), []
    for s in data:
        if s not in seen:
            seen.add(s); out.append(s)
    return out

def delete_files_from_json(json_path, dry_run=True, log_path="delete_log.txt", root_dir: str | None = None):
    json_path = Path(json_path)
    if not json_path.exists():
        print(f"Fichier JSON introuvable : {json_path}")
        sys.exit(1)

    try:
        paths = load_paths(json_path)
    except Exception as e:
        print(f"Erreur de lecture/validation du JSON : {e}")
        sys.exit(1)

    root = Path(root_dir) if root_dir else None
    if root and (not root.exists() or not root.is_dir()):
        print(f"Racine invalide ou inexistante : {root}")
        sys.exit(1)

    log_entries = []
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"\n=== Suppression lancée à {ts} (dry_run={dry_run}) ===\n")

    errs = 0
    for raw_path in paths:
        variants = normalize_variants(raw_path)

        # périmètre
        if root and not any(is_under_root(Path(v), root) for v in variants):
            msg = f"Refusé (hors racine): {raw_path}"
            print("ATTENTION", msg)
            log_entries.append(f"[REFUSED] {msg}")
            errs += 1
            continue

        # existence (essaie NFC puis NFD)
        found = next((Path(v) for v in variants if Path(v).exists()), None)
        probe = Path(variants[0])

        if found is None:
            msg = f"Fichier introuvable : {probe}"
            print("ATTENTION", msg)
            log_entries.append(f"[WARN] {msg}")
            continue

        # symlink: on ne suit pas, on refuse (plus sûr sur serveur)
        if found.is_symlink():
            msg = f"Refusé (symlink) : {found}"
            print("⚠️", msg)
            log_entries.append(f"[REFUSED] {msg}")
            errs += 1
            continue

        if not found.is_file():
            msg = f"Non supprimé (pas un fichier) : {found}"
            print("⚠️", msg)
            log_entries.append(f"[WARN] {msg}")
            continue

        # permissions dossier parent
        if not os.access(found.parent, os.W_OK):
            msg = f"Permission refusée sur le dossier parent : {found.parent}"
            print("ERREUR", msg)
            log_entries.append(f"[ERR] {msg}")
            errs += 1
            continue

        try:
            if dry_run:
                msg = f"Simulation {found}"
                print("", msg)
                log_entries.append(f"[DRY] {msg}")
            else:
                found.unlink()
                msg = f"Supprimé : {found}"
                print("SUPPRESSION VALIDÉE", msg)
                log_entries.append(f"[OK] {msg}")
        except Exception as e:
            msg = f"Erreur lors de la suppression de {found} : {e}"
            print("ERREUR", msg)
            log_entries.append(f"[ERR] {msg}")
            errs += 1

    with open(log_path, "a", encoding="utf-8") as log_file:
        log_file.write(f"\n--- {ts} ---\n")
        for entry in log_entries:
            log_file.write(entry + "\n")

    print(f"\nLog enregistré dans : {log_path}")
    print(f"Fin du script. erreurs={errs}\n")
    sys.exit(0 if errs == 0 else 2)

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage : python delete_from_json.py <fichier.json> [--force] [--root /chemin/racine] [--log delete_log.txt]")
        sys.exit(1)

    json_file = sys.argv[1]
    dry = "--force" not in sys.argv
    # options simples sans casser l'interface d’origine
    root = None
    log = "delete_log.txt"
    if "--root" in sys.argv:
        i = sys.argv.index("--root")
        if i + 1 < len(sys.argv):
            root = sys.argv[i + 1]
    if "--log" in sys.argv:
        i = sys.argv.index("--log")
        if i + 1 < len(sys.argv):
            log = sys.argv[i + 1]

    # confirmation minimale si on quitte le dry-run
    if not dry:
        resp = input("⚠️ Vous n'êtes PAS en dry-run. Confirmer la suppression (oui/N) : ").strip().lower()
        if resp not in ("o", "oui", "y", "yes"):
            print("Annulé.")
            sys.exit(0)

    delete_files_from_json(json_file, dry_run=dry, log_path=log, root_dir=root)
