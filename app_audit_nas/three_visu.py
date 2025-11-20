#!/usr/bin/env python
import argparse
import json
from collections import defaultdict
from pathlib import PurePosixPath

import pandas as pd


def format_size(bytes_value):
    if pd.isna(bytes_value):
        return "0 MB"
    mb = float(bytes_value) / (1024 * 1024)
    return f"{mb:.2f} MB"


def format_date(date_value):
    if pd.isna(date_value):
        return "N/A"
    try:
        if isinstance(date_value, str):
            date_value = pd.to_datetime(date_value, errors="coerce")
        return date_value.strftime("%Y-%m-%d %H:%M:%S")
    except Exception:
        return "N/A"


def split_parts(p: str):
    p = str(PurePosixPath(p))
    return [part for part in p.split("/") if part not in ("", ".")]


def build_aggregates(df: pd.DataFrame):
    counts = defaultdict(int)
    parents = {}
    labels = {}
    sizes = defaultdict(float)
    dates = {}
    types = {}
    path_to_hash = {}

    for _, row in df.iterrows():
        path = row["path"]
        parts = split_parts(path)
        if not parts:
            continue

        size = row.get("size_bytes", float("nan"))
        mtime = row.get("mtime", pd.NaT)
        element_type = row.get("type", "N/A")
        file_hash = row.get("hash") if "hash" in df.columns else None

        for i in range(1, len(parts) + 1):
            node = "/".join(parts[:i])
            parent = "/".join(parts[:i - 1]) if i > 1 else ""
            counts[node] += 1
            sizes[node] += 0 if pd.isna(size) else float(size)
            parents[node] = parent
            labels[node] = parts[i - 1]

            if i == len(parts):
                types[node] = element_type
                if file_hash and isinstance(file_hash, str) and file_hash.strip():
                    path_to_hash[node] = file_hash.strip().lower()
            else:
                types[node] = "directory"
            # if i == len(parts):
            #     types[node] = element_type
            #     if element_type.lower() == "file" and file_hash and isinstance(file_hash, str) and file_hash.strip():
            #         path_to_hash[node] = file_hash.strip().lower()
            # else:
            #     types[node] = "directory"

            if not pd.isna(mtime):
                prev_date = dates.get(node)
                if pd.isna(prev_date) or (mtime > prev_date):
                    dates[node] = mtime

    return counts, parents, labels, sizes, dates, types, path_to_hash


def compute_duplicates(path_to_hash: dict):
    hash_to_paths = defaultdict(list)
    for path, sha in path_to_hash.items():
        if not sha:
            continue
        hash_to_paths[sha].append("/" + path)

    duplicate_paths = set()
    path_to_other_duplicates = {}
    for sha, paths in hash_to_paths.items():
        if len(paths) > 1:
            for p in paths:
                duplicate_paths.add(p)
                path_to_other_duplicates[p] = [op for op in paths if op != p]

    return duplicate_paths, path_to_other_duplicates


def build_flat_indexes(counts, parents, labels, sizes, dates, types,
                       duplicate_paths, path_to_other_duplicates):
    """
    Construit :
      - flat_nodes: { id -> {name, id, type, sizeStr, dateStr, count, isDuplicate, duplicateOthers, itemStyle} }
      - children_index: { parent_id -> [child_id, ...] }
    Sans arborescence imbriquée : le chargement (et la profondeur visible) se fera côté JS.
    """
    flat_nodes = {}
    children_index = defaultdict(list)

    # Racine
    flat_nodes["/"] = {
        "name": "ROOT",
        "id": "/",
        "type": "directory",
        "sizeStr": format_size(sizes.get("", 0.0)),
        "dateStr": format_date(dates.get("", pd.NaT)),
        "count": int(counts.get("", 0)),
        "isDuplicate": False,
        "duplicateOthers": [],
        "itemStyle": {}
    }

    for node_id in labels.keys():
        abs_path = "/" + node_id
        parent_id = "/" + parents.get(node_id, "") if parents.get(node_id, "") else "/"
        is_file = (types.get(node_id, "").lower() == "file")
        is_dup = is_file and (abs_path in duplicate_paths)
        other_dups = path_to_other_duplicates.get(abs_path, []) if is_dup else []

        if is_dup:
            color = "rgba(220,20,60,0.9)"  # Rouge pour les fichiers doublons
        elif is_file:
            color = "rgba(46,92,255,0.78)"    # Vert pour les fichiers non doublons
        else:
            color = "rgba(135,206,250,0.78)"  # Bleu clair pour les dossiers

      # Enregistrer le nœud dans l'index plat
        flat_nodes[abs_path] = {
            "name": labels[node_id],
            "id": abs_path,
            "type": types.get(node_id, "N/A"),
            "sizeStr": format_size(sizes.get(node_id, 0.0)),
            "dateStr": format_date(dates.get(node_id, pd.NaT)),
            "count": int(counts.get(node_id, 0)),
            "isDuplicate": is_dup,
            "duplicateOthers": other_dups,
            "itemStyle": {"color": color}
        }

        children_index[parent_id].append(abs_path)
    
    def mark_duplicate_dirs(flat_nodes, children_index):
        def recurse(node_id):
            children = children_index.get(node_id, [])
            if not children:
                # Pas d'enfants => renvoie simplement si le nœud est un doublon
                return flat_nodes[node_id]["isDuplicate"]
    
            all_dup = True
            for child in children:
                if not recurse(child):  # Descend récursivement
                    all_dup = False
    
            if all_dup and flat_nodes[node_id]["type"] == "directory":
                flat_nodes[node_id]["itemStyle"] = {"color": "rgba(220, 21, 61, 0.52)"}
                return True
            return False
    
        # Appel sur la racine
        recurse("/")

    mark_duplicate_dirs(flat_nodes, children_index)

    for pid in children_index:
        children_index[pid].sort()

    return flat_nodes, children_index


def write_html_echarts(flat_nodes: dict, children_index: dict, output_html: str, title: str):
    """
    Génère une page HTML avec :
      - ECharts 'tree' (roam: true) ;
      - Sidebar + fil d’Ariane ;
      - Chargement paresseux (lazy) ;
      - Sélection de fichiers/dossiers (Ctrl+clic) ;
      - Export JSON de la liste des chemins sélectionnés.
    """
    html_template = r"""
<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>%%TITLE%%</title>
  <style>
    :root { --h-header: 48px; --w-sidebar: 290px; }
    html, body { height: 100%; margin: 0; }
    body { font-family: system-ui,-apple-system,Segoe UI,Roboto,Arial,sans-serif; }
    #app {
      display: grid;
      grid-template-columns: var(--w-sidebar) 1fr;
      grid-template-rows: var(--h-header) 1fr;
      height: 100vh;
      width: 100vw;
    }
    #sidebar {
      grid-row: 1 / span 2;
      grid-column: 1;
      border-right: 1px solid #eee;
      overflow: auto;
      display: flex;
      flex-direction: column;
    }
    #sidebar .top {
      position: sticky;
      top: 0;
      background: #fff;
      z-index: 2;
      padding: 10px;
      border-bottom: 1px solid #eee;
    }
    #sidebar input[type="text"] {
      width: 100%;
      padding: 6px 8px;
      box-sizing: border-box;
      border: 1px solid #ddd;
      border-radius: 6px;
    }
    #side-tree {
      flex: 1 1 auto;
      overflow-y: auto;
      padding: 4px 0 8px 0;
    }
    #sidebar ul { list-style: none; padding-left: 8px; margin: 0; }
    #sidebar li { cursor: pointer; padding: 4px 8px; border-radius: 6px; }
    #sidebar li:hover { background: #f5f5f5; }
    #breadcrumb {
      grid-row: 1;
      grid-column: 2;
      display: flex;
      align-items: center;
      gap: 6px;
      padding: 0 12px;
      border-bottom: 1px solid #eee;
      white-space: nowrap;
      overflow: auto;
      font-size: 13px;
    }
    #breadcrumb a {
      text-decoration: none;
      color: #0366d6;
    }
    #breadcrumb a:hover { text-decoration: underline; }
    #chart {
      grid-row: 2;
      grid-column: 2;
      width: 100%;
      height: calc(100vh - var(--h-header));
    }
    .badge {
      font-size: 11px;
      opacity: 0.75;
      margin-left: 6px;
    }
    .dup { color: #DC143C; font-weight: 600; }
    .sep { opacity: .65; }
    .smallhint {
      font-size: 11px;
      color: #666;
      margin-top: 6px;
      line-height: 1.3;
    }
    #selection-panel {
      border-top: 1px solid #eee;
      padding: 8px 10px;
      background: #fafafa;
      flex: 0 0 auto;
    }
    #selection-panel header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 6px;
      margin-bottom: 4px;
      font-size: 13px;
      font-weight: 600;
    }
    #selection-panel button {
      border-radius: 6px;
      border: 1px solid #ccc;
      padding: 3px 8px;
      font-size: 12px;
      cursor: pointer;
      background: #fff;
    }
    #selection-panel button:hover {
      background: #f0f0f0;
    }
    #selection-list {
      max-height: 110px;
      overflow-y: auto;
      margin: 4px 0 0 0;
      padding-left: 0;
    }
    #selection-list li {
      font-size: 11px;
      padding: 2px 0;
      cursor: pointer;
      word-break: break-all;
    }
    #selection-list li:hover {
      text-decoration: underline;
    }
  </style>
  <script src="https://cdn.jsdelivr.net/npm/echarts@5.5.0/dist/echarts.min.js"></script>
</head>
<body>
  <div id="app">
    <aside id="sidebar">
      <div class="top">
        <div style="font-weight:600; margin-bottom:8px;">Navigation</div>
        <input id="search" type="text" placeholder="Rechercher un dossier/fichier…" />
        <div class="smallhint">
          Clic = naviguer dans l'arbre <br/> <br/>
          ⌘+clic (ou Alt+clic) = (dé)sélectionner pour suppression potentielle.
        </div>
      </div>
      <div id="side-tree"></div>
      <div id="selection-panel">
        <header>
          <span>Sélection (<span id="selection-count">0</span>)</span>
          <button id="export-selection">Exporter JSON</button>
        </header>
        <div class="smallhint">
          La sélection est exportée dans un fichier <code>paths_to_delete.json</code>,
          à utiliser ensuite avec un script Python de suppression. <br/><br/>
          Clic sur un élément de la liste pour le retirer de la sélection.
        </div>
        <ul id="selection-list"></ul>
      </div>
    </aside>
    <nav id="breadcrumb"></nav>
    <div id="chart"></div>
  </div>

  <script>
    // ====== Données plates (lazy) ======
    const flatNodes = %%FLAT_NODES%%;       // { id: {name, id, type, sizeStr, dateStr, count, ...} }
    const childrenIndex = %%CHILD_INDEX%%;  // { parent_id: [child_id, ...] }

    // Racine
    const ROOT_ID = '/';

    // ====== Gestion de la sélection ======
    const selectedPaths = new Set();

    function updateSelectionPanel() {
      const countSpan = document.getElementById('selection-count');
      const list = document.getElementById('selection-list');
      const items = Array.from(selectedPaths);
      countSpan.textContent = items.length.toString();

      list.innerHTML = '';
      items.forEach(id => {
        const li = document.createElement('li');
        li.textContent = id;
        li.title = '⌘+clic (ou Alt+clic) pour retirer de la sélection';
        li.onclick = (e) => {
          e.preventDefault();
          toggleSelection(id);
        };
        list.appendChild(li);
      });
    }

    function toggleSelection(id) {
      if (id === ROOT_ID) {
        // on évite toute "sélection" de la racine par sécurité
        return;
      }
      if (selectedPaths.has(id)) {
        selectedPaths.delete(id);
      } else {
        selectedPaths.add(id);
      }
      updateSelectionPanel();
    }

    function exportSelection() {
      if (!selectedPaths.size) {
        alert('Aucun chemin sélectionné.');
        return;
      }
      const arr = Array.from(selectedPaths);
      const blob = new Blob([JSON.stringify(arr, null, 2)], { type: 'application/json' });
      const a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = 'paths_to_delete.json';
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      URL.revokeObjectURL(a.href);
    }

    document.getElementById('export-selection').addEventListener('click', exportSelection);

    // ====== Helpers pour (re)construire un sous-arbre à la volée ======
    function cloneNodeCore(n) {
      return {
        name: n.name,
        id: n.id,
        type: n.type,
        sizeStr: n.sizeStr,
        dateStr: n.dateStr,
        count: n.count,
        isDuplicate: !!n.isDuplicate,
        duplicateOthers: Array.isArray(n.duplicateOthers) ? n.duplicateOthers.slice() : [],
        itemStyle: n.itemStyle || {}
      };
    }

    function buildSubtree(id, maxDepth = 2) {
      const n = flatNodes[id];
      if (!n) return null;
      const node = cloneNodeCore(n);

      if (maxDepth <= 0) {
        node.children = [];
        return node;
      }

      const childIds = childrenIndex[id] || [];
      node.children = childIds.map(cid => {
        const cn = flatNodes[cid];
        if (!cn) return null;
        const child = cloneNodeCore(cn);
        if (maxDepth - 1 > 0) {
          child.children = (childrenIndex[cid] || []).map(gcId => {
            const gcn = flatNodes[gcId];
            return gcn ? cloneNodeCore(gcn) : null;
          }).filter(Boolean);
        } else {
          child.children = [];
        }
        return child;
      }).filter(Boolean);

      return node;
    }

    // ====== ECharts ======
    const chart = echarts.init(document.getElementById('chart'), null, { renderer: 'canvas' });

    let zoomLevel = 1;
    function adaptLabels() {
      const showLabels = zoomLevel > 0.85;
      const fontSize = showLabels ? 10 : 0;
      chart.setOption({
        series: [{
          label: { show: showLabels, fontSize: fontSize },
          leaves: { label: { show: showLabels, fontSize: fontSize } },
          animation: false
        }]
      }, { partialUpdate: true });
    }

    const baseSeries = {
      type: 'tree',
      orient: 'LR',
      left: '3%', right: '1%', top: 60, bottom: '5%',
      symbol: 'rect',
      symbolSize: [80, 18],
      itemStyle: {
        color: 'rgba(46, 92, 255, 0.78)',
        borderColor: 'rgba(0,0,0,1)',
        borderWidth: 0.5
      },
      label: {
        position: 'left',
        verticalAlign: 'middle',
        align: 'right',
        fontSize: 10
      },
      leaves: {
        label: {
          position: 'right',
          verticalAlign: 'middle',
          align: 'left',
          fontSize: 10
        }
      },
      expandAndCollapse: true,
      initialTreeDepth: 2,
      animationDuration: 250,
      animationDurationUpdate: 250,
      roam: true,
      scaleLimit: { min: 0.6, max: 10 }
    };

    const option = {
      title: { text: '%%TITLE%%' },
      tooltip: {
        confine: true,
        className: 'echarts-tooltip',
        formatter: function (info) {
          const d = info.data || {};
          const typeStr = (d.type === 'directory')
            ? 'Dossier'
            : (d.type === 'file' ? 'Fichier' : 'N/A');
          const dup = (d.isDuplicate && Array.isArray(d.duplicateOthers) && d.duplicateOthers.length)
            ? ('<br><b style="color:#DC143C">Doublons détectés</b><br>' + d.duplicateOthers.join('<br>'))
            : '';
          const hint = '<br><span style="font-size:11px;color:#666;">⌘+clic (ou Alt+clic) sur le nœud pour l’ajouter/retirer de la sélection.</span>';
          return (
            '<b>Chemin absolu :</b> ' + (d.id || '/') + '<br>' +
            '<b>Type :</b> ' + typeStr + '<br>' +
            "<b>Nombre d\\'éléments :</b> " + (d.count || 0) + '<br>' +
            '<b>Taille totale :</b> ' + (d.sizeStr || '') + '<br>' +
            '<b>Dernière modification :</b> ' + (d.dateStr || '') + dup + hint
          );
        }
      },
      toolbox: {
        top: 10, right: 10,
        feature: { saveAsImage: {}, restore: {} }
      },
      series: [Object.assign({}, baseSeries, { data: [buildSubtree(ROOT_ID, 2)] })]
    };

    chart.setOption(option);
    window.addEventListener('resize', () => chart.resize());

    chart.getZr().on('mousewheel', (e) => {
      const step = 1.25;
      const factor = e.wheelDelta > 0 ? step : 1 / step;
      zoomLevel = Math.max(0.1, Math.min(10, zoomLevel * factor));
      adaptLabels();
    });

    function getAncestorPaths(id) {
      const chain = ['/'];
      if (id === '/' || !id) return chain;
      const parts = id.split('/').filter(Boolean);
      let acc = '';
      for (const part of parts) {
        acc = acc ? acc + '/' + part : '/' + part;
        if (flatNodes[acc]) chain.push(acc);
      }
      return chain;
    }

    function renderBreadcrumb(id) {
      const bc = document.getElementById('breadcrumb');
      bc.innerHTML = '';

      const paths = getAncestorPaths(id);
      paths.forEach((p, i) => {
        const a = document.createElement('a');
        a.href = '#';
        const n = flatNodes[p];
        a.textContent = (p === '/') ? 'ROOT' : (n?.name || p.split('/').filter(Boolean).pop());
        a.onclick = (ev) => { ev.preventDefault(); focusOn(p); };
        bc.appendChild(a);

        if (i < paths.length - 1) {
          const sep = document.createElement('span');
          sep.textContent = '›';
          sep.className = 'sep';
          sep.style.margin = '0 6px';
          bc.appendChild(sep);
        }
      });
    }

    function focusOn(id) {
      const sub = buildSubtree(id, 2);
      if (!sub) return;

      renderBreadcrumb(id);

      chart.clear();
      chart.setOption({
        title: { text: '%%TITLE%%' },
        tooltip: option.tooltip,
        toolbox: option.toolbox,
        series: [Object.assign({}, baseSeries, { data: [sub] })]
      }, { notMerge: true, lazyUpdate: false });

      zoomLevel = 1;
      adaptLabels();
    }

    // Clic dans le graphe :
    // - clic normal = naviguer / recentrer
    // - ⌘+clic / Ctrl+clic / Alt+clic = (dé)sélectionner le chemin
    chart.on('click', params => {
        if (!params?.data?.id) return;
        const ev = params.event && params.event.event;

        // macOS : metaKey = ⌘ Command
        const isSelectClick = ev && (ev.metaKey || ev.ctrlKey || ev.altKey);

        if (isSelectClick) {
            toggleSelection(params.data.id);
        } else {
            focusOn(params.data.id);
        }
    });

    // Flèche gauche = remonter d'un cran
    window.addEventListener('keydown', (e) => {
      if (e.key !== 'ArrowLeft') return;
      const bc = document.getElementById('breadcrumb');
      const links = bc.querySelectorAll('a');
      if (links.length > 1) {
        links[links.length - 2].click();
      }
    });

    // ====== Sidebar (lazy) ======
    function buildSidebarList(parentId = ROOT_ID, depth = 0) {
      const ul = document.createElement('ul');
      const childIds = childrenIndex[parentId] || [];
      childIds.forEach(cid => {
        const n = flatNodes[cid];
        if (!n) return;
        const li = document.createElement('li');
        li.style.paddingLeft = (depth * 12 + 6) + 'px';
        const hasChildren = (childrenIndex[cid] || []).length > 0;
        li.innerHTML = `
          ${hasChildren ? '▸ ' : '• '}
          <span class="label">${n.name}</span>
          <span class="badge">${n.count || 0}</span>
          ${n.isDuplicate ? '<span class="badge dup">dup</span>' : ''}
        `;

        li.onclick = (e) => {
            e.stopPropagation();
            const isSelectClick = e.metaKey || e.ctrlKey || e.altKey;
            if (isSelectClick) {
                toggleSelection(cid);
            } else {
                focusOn(cid);
            }
        };

        li.oncontextmenu = (e) => {
          e.preventDefault();
          const existing = li.querySelector(':scope > ul');
          if (existing) {
            existing.remove();
          } else if (hasChildren) {
            li.appendChild(buildSidebarList(cid, depth + 1));
          }
        };

        ul.appendChild(li);
      });
      return ul;
    }

    function renderSidebarFullList() {
      const sideTree = document.getElementById('side-tree');
      sideTree.innerHTML = '';
      sideTree.appendChild(buildSidebarList(ROOT_ID, 0));
    }

    function renderSidebarSearchList(q) {
      const sideTree = document.getElementById('side-tree');
      sideTree.innerHTML = '';
      const ul = document.createElement('ul');
      const matches = [];
      for (const [id, n] of Object.entries(flatNodes)) {
        if (!n.name) continue;
        if (n.name.toLowerCase().includes(q)) matches.push(n);
      }
      matches.sort((a,b) => (b.count||0)-(a.count||0));
      matches.slice(0, 200).forEach(n => {
        const li = document.createElement('li');
        li.innerHTML = `• <span class="label">${n.name}</span> <span class="badge">${n.count || 0}</span> ${n.isDuplicate ? '<span class="badge dup">dup</span>' : ''}`;
        li.onclick = (e) => {
            e.stopPropagation();
            const isSelectClick = e.metaKey || e.ctrlKey || e.altKey;
            if (isSelectClick) {
                toggleSelection(n.id);
            } else {
                focusOn(n.id);
            }
        };
        ul.appendChild(li);
      });
      sideTree.appendChild(ul);
    }

    function setupSidebar() {
      renderSidebarFullList();
      const input = document.getElementById('search');
      let searchTimer = null;
      input.addEventListener('input', () => {
        clearTimeout(searchTimer);
        searchTimer = setTimeout(() => {
          const q = input.value.trim().toLowerCase();
          if (!q) renderSidebarFullList();
          else renderSidebarSearchList(q);
        }, 200);
      });
      updateSelectionPanel();
    }

    setupSidebar();
    renderBreadcrumb(ROOT_ID);
    focusOn(ROOT_ID);
  </script>
</body>
</html>
"""
    html = (
        html_template
        .replace("%%TITLE%%", title)
        .replace("%%FLAT_NODES%%", json.dumps(flat_nodes, ensure_ascii=False, separators=(",", ":")))
        .replace("%%CHILD_INDEX%%", json.dumps(children_index, ensure_ascii=False, separators=(",", ":")))
    )
    with open(output_html, "w", encoding="utf-8") as f:
        f.write(html)


def main():
    parser = argparse.ArgumentParser(
        description=(
            "Visualisation arborescente (ECharts) avec lazy load JS, "
            "détection des doublons et sélection de chemins pour suppression "
            "(export JSON)."
        )
    )
    parser.add_argument(
        "--csv",
        required=True,
        help="CSV d’entrée: colonnes 'path','size_bytes','mtime' + optionnels 'type','hash'"
    )
    parser.add_argument(
        "--output",
        default="tree_paths.html",
        help="Nom du fichier HTML de sortie"
    )
    parser.add_argument(
        "--title",
        default="Tree vizu",
        help="Titre de la visualisation"
    )
    args = parser.parse_args()

    usecols = ["path", "size_bytes", "mtime", "type", "hash"]
    dtypes = {
        "path": "string",
        "size_bytes": "float64",
        "type": "string",
        "hash": "string",
    }

    df = pd.read_csv(
        args.csv,
        usecols=[c for c in usecols if c],
        dtype=dtypes,
        parse_dates=["mtime"],
        na_values=["nan", "NaN", ""],
        keep_default_na=True,
        low_memory=True,
        engine="c",
    )

    for col in ["path", "size_bytes", "mtime"]:
        if col not in df:
            raise ValueError(f"Le fichier CSV doit contenir la colonne '{col}'.")

    df["path"] = df["path"].astype(str)
    df["size_bytes"] = pd.to_numeric(df["size_bytes"], errors="coerce")
    df["mtime"] = pd.to_datetime(df["mtime"], errors="coerce")

    if "hash" in df.columns:
        df["hash"] = df["hash"].astype(str).str.strip().str.lower()
    if "type" in df.columns:
        df["type"] = df["type"].astype(str).str.strip().str.lower()

    counts, parents, labels, sizes, dates, types, path_to_hash = build_aggregates(df)
    duplicate_paths, path_to_other_duplicates = compute_duplicates(path_to_hash)

    flat_nodes, children_index = build_flat_indexes(
        counts, parents, labels, sizes, dates, types,
        duplicate_paths, path_to_other_duplicates
    )

    write_html_echarts(flat_nodes, children_index, args.output, args.title)
    print(f"Fichier interactif sauvegardé : {args.output}")
    print("Ouvre ce fichier dans ton navigateur (Google Chrome de préférence).")


if __name__ == "__main__":
    main()
