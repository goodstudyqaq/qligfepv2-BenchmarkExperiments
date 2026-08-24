#!/usr/bin/env python3
"""Generate a dashboard bundle containing PNG figures and metrics reports.

With one positional path, the dashboard is generated in place.  With a second
path, only the dashboard assets are copied to a new, portable directory first.
"""

from __future__ import annotations

import argparse
import html
import json
import os
import re
import shutil
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class Metric:
    label: str
    value: str
    note: str


@dataclass(frozen=True)
class Result:
    target: str
    folder: Path
    pngs: tuple[Path, ...]
    report: Path | None
    metrics: tuple[Metric, ...]
    file_count: int
    byte_count: int


def arguments() -> argparse.Namespace:
    repo_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(
        description=(
            "Generate an index.html dashboard for QligFEP results. If OUTPUT "
            "is supplied, PNG figures and metrics_report.html files are copied "
            "to OUTPUT first. Other result files are not copied."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=f"""examples:
  # Regenerate the dashboard directly in the repository's my_result directory:
  python3 {Path(__file__).name} {repo_root / 'my_result'}

  # Create a small portable bundle containing only figures and reports:
  python3 {Path(__file__).name} {repo_root / 'my_result'} /path/to/fep_results
""",
    )
    parser.add_argument(
        "source",
        nargs="?",
        type=Path,
        default=repo_root / "my_result",
        help="results root to scan (default: %(default)s)",
    )
    parser.add_argument(
        "output",
        nargs="?",
        type=Path,
        help="new portable bundle directory; omit to generate in SOURCE",
    )
    return parser.parse_args()


def human_size(size: int) -> str:
    value = float(size)
    units = ("B", "KiB", "MiB", "GiB", "TiB", "PiB")
    for unit in units:
        if value < 1024 or unit == units[-1]:
            if unit == "B":
                return f"{int(value)} {unit}"
            return f"{value:.1f} {unit}"
        value /= 1024
    raise AssertionError("unreachable")


def target_name(name: str) -> str:
    name = re.sub(r"_extracted$", "", name, flags=re.IGNORECASE)
    name = re.sub(r"_important_\d{8}_\d{6}$", "", name, flags=re.IGNORECASE)
    name = re.sub(r"_results$", "", name, flags=re.IGNORECASE)
    return name.replace("_", " ").upper()


def clean_text(fragment: str) -> str:
    without_tags = re.sub(r"<[^>]+>", "", fragment)
    return " ".join(html.unescape(without_tags).split())


def read_metrics(report: Path | None) -> tuple[Metric, ...]:
    if report is None:
        return ()
    try:
        content = report.read_text(encoding="utf-8", errors="replace")
    except OSError as error:
        print(f"warning: cannot read metrics from {report}: {error}", file=sys.stderr)
        return ()
    pattern = re.compile(
        r'<div\s+class=["\']metric["\']\s*>'
        r'.*?<div\s+class=["\']metric-label["\']\s*>(.*?)</div>'
        r'.*?<div\s+class=["\']metric-value["\']\s*>(.*?)</div>'
        r'.*?<div\s+class=["\']metric-note["\']\s*>(.*?)</div>',
        re.IGNORECASE | re.DOTALL,
    )
    return tuple(
        Metric(*(clean_text(value) for value in match.groups()))
        for match in pattern.finditer(content)
    )


def discover_results(root: Path) -> tuple[Result, ...]:
    results: list[Result] = []
    for folder in sorted(
        (path for path in root.iterdir() if path.is_dir()),
        key=lambda path: path.name.casefold(),
    ):
        pngs = tuple(
            sorted(folder.rglob("*.png"), key=lambda path: path.as_posix().casefold())
        )
        reports = sorted(
            folder.rglob("metrics_report.html"),
            key=lambda path: (len(path.parts), path.as_posix().casefold()),
        )
        report = reports[0] if reports else None
        if not pngs and report is None:
            continue
        assets = (*pngs, *((report,) if report else ()))
        results.append(
            Result(
                target=target_name(folder.name),
                folder=folder,
                pngs=pngs,
                report=report,
                metrics=read_metrics(report),
                file_count=len(assets),
                byte_count=sum(path.stat().st_size for path in assets),
            )
        )
    return tuple(results)


def relative(path: Path, root: Path) -> str:
    return path.relative_to(root).as_posix()


def result_data(result: Result, root: Path) -> dict[str, Any]:
    return {
        "target": result.target,
        "folder": relative(result.folder, root),
        "pngs": [relative(path, root) for path in result.pngs],
        "report": relative(result.report, root) if result.report else None,
        "metrics": [metric.__dict__ for metric in result.metrics],
        "file_count": result.file_count,
        "size": human_size(result.byte_count),
    }


def asset_paths(results: tuple[Result, ...]) -> tuple[Path, ...]:
    paths = {
        path
        for result in results
        for path in (*result.pngs, *((result.report,) if result.report else ()))
    }
    return tuple(sorted(paths, key=lambda path: path.as_posix().casefold()))


def manifest(root: Path, results: tuple[Result, ...], generated: str) -> dict[str, Any]:
    files: list[dict[str, Any]] = []
    total_bytes = 0
    for path in asset_paths(results):
        try:
            stat = path.stat()
        except OSError as error:
            print(f"warning: cannot add {path} to manifest: {error}", file=sys.stderr)
            continue
        total_bytes += stat.st_size
        files.append(
            {
                "path": relative(path, root),
                "size_bytes": stat.st_size,
                "modified": datetime.fromtimestamp(stat.st_mtime)
                .astimezone()
                .isoformat(timespec="seconds"),
            }
        )
    return {
        "schema_version": 1,
        "generated": generated,
        "source_directory_name": root.name,
        "file_count": len(files),
        "total_bytes": total_bytes,
        "files": files,
        "note": "Only PNG figures and metrics_report.html files are inventoried.",
    }


def dashboard_html(
    root: Path,
    results: tuple[Result, ...],
    inventory: dict[str, Any],
    generated: str,
) -> str:
    reports = sum(result.report is not None for result in results)
    images = sum(len(result.pngs) for result in results)
    data = {
        "generated": generated,
        "summary": {
            "targets": len(results),
            "images": images,
            "reports": reports,
            "files": inventory["file_count"],
            "size": human_size(inventory["total_bytes"]),
        },
        "results": [result_data(result, root) for result in results],
    }
    encoded = json.dumps(data, ensure_ascii=False).replace("<", "\\u003c")
    return HTML_TEMPLATE.replace("__DASHBOARD_DATA__", encoded)


def copy_bundle(source: Path, output: Path) -> Path:
    source = source.resolve()
    output = output.resolve()
    if output == source:
        return source
    if source in output.parents:
        raise SystemExit(
            "OUTPUT cannot be inside SOURCE (that would recurse while copying)"
        )
    if output in source.parents:
        raise SystemExit("SOURCE cannot be inside OUTPUT")
    if output.exists():
        raise SystemExit(
            f"OUTPUT already exists: {output}\n"
            "Choose a new directory, or omit OUTPUT to regenerate its dashboard in place."
        )
    output.parent.mkdir(parents=True, exist_ok=True)
    results = discover_results(source)
    if not results:
        raise SystemExit(
            f"No result directories containing PNGs or metrics_report.html found in {source}"
        )
    assets = asset_paths(results)
    source_bytes = sum(path.stat().st_size for path in assets)
    free_bytes = shutil.disk_usage(output.parent).free
    print(
        f"Copying {len(assets):,} dashboard assets "
        f"({human_size(source_bytes)}) to {output}",
        flush=True,
    )
    if free_bytes < source_bytes:
        raise SystemExit(
            f"Not enough free space: need {human_size(source_bytes)}, "
            f"have {human_size(free_bytes)} in {output.parent}"
        )
    temporary = output.with_name(f".{output.name}.partial-{os.getpid()}")
    if temporary.exists():
        raise SystemExit(f"Temporary output already exists: {temporary}")
    temporary.mkdir()
    try:
        for asset in assets:
            destination = temporary / relative(asset, source)
            destination.parent.mkdir(parents=True, exist_ok=True)
            print(f"  {relative(asset, source)}", flush=True)
            shutil.copy2(asset, destination)
        temporary.rename(output)
    except BaseException:
        print(
            f"Copy did not finish. Partial bundle retained at: {temporary}",
            file=sys.stderr,
        )
        raise
    return output


def generate(root: Path) -> None:
    generated = datetime.now().astimezone().isoformat(timespec="seconds")
    results = discover_results(root)
    if not results:
        raise SystemExit(
            f"No result directories containing PNGs or metrics_report.html found in {root}"
        )
    inventory = manifest(root, results, generated)
    manifest_path = root / "bundle_manifest.json"
    manifest_path.write_text(
        json.dumps(inventory, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    index_path = root / "index.html"
    index_path.write_text(
        dashboard_html(root, results, inventory, generated), encoding="utf-8"
    )
    print(f"Dashboard: {index_path}")
    print(f"Manifest:  {manifest_path}")
    print(
        f"Included:  {len(results)} targets, "
        f"{sum(len(result.pngs) for result in results)} PNGs, "
        f"{sum(result.report is not None for result in results)} reports, "
        f"{inventory['file_count']:,} assets "
        f"({human_size(inventory['total_bytes'])}); other files omitted"
    )


def main() -> int:
    args = arguments()
    source = args.source.expanduser().resolve()
    if not source.is_dir():
        raise SystemExit(f"SOURCE is not a directory: {source}")
    root = copy_bundle(source, args.output.expanduser()) if args.output else source
    generate(root)
    return 0


HTML_TEMPLATE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>FEP Results Dashboard</title>
<style>
:root{--bg:#f4f7f5;--panel:#fff;--ink:#17231d;--muted:#627068;--line:#dce5df;--accent:#087f5b;--accent2:#36b37e;--soft:#e6f5ef;--warn:#8a5a00;--warnbg:#fff2cd;--shadow:0 12px 38px rgba(24,48,36,.08)}
*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;color:var(--ink);background:var(--bg);font:14px/1.5 Inter,ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif}
button,input{font:inherit}.layout{display:grid;grid-template-columns:240px minmax(0,1fr);min-height:100vh}.side{position:sticky;top:0;height:100vh;padding:25px 18px;border-right:1px solid var(--line);background:#fbfdfc;overflow:auto}
.brand{display:flex;align-items:center;gap:10px;margin:0 8px 20px;font-weight:800;font-size:16px}.brand-mark{width:30px;height:30px;border-radius:9px;display:grid;place-items:center;color:#fff;background:linear-gradient(135deg,#073b30,var(--accent2))}
.nav{display:grid;gap:4px}.nav a{padding:8px 10px;color:#435249;text-decoration:none;border-radius:8px}.nav a:hover{color:var(--accent);background:var(--soft)}
.main{min-width:0;padding:32px clamp(18px,3vw,46px) 70px}.hero{padding:32px;border-radius:20px;color:#fff;background:linear-gradient(120deg,#073b30,#087f5b 62%,#23a879);box-shadow:var(--shadow)}
.hero h1{margin:0 0 8px;font-size:clamp(29px,4vw,48px);line-height:1.05;letter-spacing:-.035em}.hero p{margin:0;color:#d8f6e9}.stats{display:flex;flex-wrap:wrap;gap:10px;margin-top:22px}.stat{padding:9px 13px;border:1px solid rgba(255,255,255,.22);border-radius:10px;background:rgba(255,255,255,.1);backdrop-filter:blur(8px)}
.toolbar{position:sticky;top:0;z-index:5;display:flex;align-items:center;gap:12px;padding:14px 0;background:rgba(244,247,245,.92);backdrop-filter:blur(12px)}.search{width:min(440px,100%);padding:11px 14px;border:1px solid #cbd8d0;border-radius:10px;background:#fff;color:var(--ink);outline:none}.search:focus{border-color:var(--accent);box-shadow:0 0 0 3px rgba(8,127,91,.12)}.result-count{color:var(--muted);white-space:nowrap}
.bundle-panel,.result{padding:24px;border:1px solid var(--line);border-radius:18px;background:var(--panel);box-shadow:var(--shadow)}.bundle-panel{margin-bottom:22px}.bundle-panel h2{margin:0 0 5px}.bundle-panel p{margin:0;color:var(--muted)}
.results{display:grid;gap:22px}.result{scroll-margin-top:75px}.result-head{display:flex;align-items:start;justify-content:space-between;gap:20px;margin-bottom:18px}.result h2{margin:0;font-size:25px;letter-spacing:-.02em}.folder{margin-top:3px;color:var(--muted);font:12px ui-monospace,SFMono-Regular,Consolas,monospace;overflow-wrap:anywhere}
.badges{display:flex;flex-wrap:wrap;gap:8px;justify-content:flex-end}.badge{padding:5px 9px;border-radius:99px;color:#176044;background:var(--soft);font-size:12px;font-weight:700}.badge.missing{color:var(--warn);background:var(--warnbg)}
.metrics{display:grid;grid-template-columns:repeat(auto-fit,minmax(145px,1fr));gap:10px;margin-bottom:18px}.metric{min-width:0;padding:13px;border:1px solid var(--line);border-radius:11px;background:#fbfdfc}.metric-label{color:var(--muted);font-size:10px;font-weight:750;letter-spacing:.07em;text-transform:uppercase}.metric-value{margin-top:4px;font-size:18px;font-weight:750;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.metric-note{color:var(--muted);font-size:11px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.gallery{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,430px),1fr));gap:14px}.figure{margin:0;min-width:0;overflow:hidden;border:1px solid var(--line);border-radius:13px;background:#f8faf9}.figure button{display:block;width:100%;padding:0;border:0;background:none;cursor:zoom-in}.figure img{display:block;width:100%;height:auto;aspect-ratio:1.75/1;object-fit:contain;background:#fff}.figure figcaption{padding:9px 12px;color:var(--muted);font-size:12px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.empty{display:grid;place-items:center;min-height:120px;border:1px dashed #d6c58c;border-radius:12px;color:#80621d;background:#fffaf0}.actions{display:flex;flex-wrap:wrap;gap:9px;margin-top:16px}.action{padding:9px 12px;border:1px solid var(--line);border-radius:9px;color:var(--ink);background:#fff;text-decoration:none;cursor:pointer}.action:hover{border-color:#a8c9bc;color:var(--accent);background:#f7fcfa}.report-wrap{display:none;margin-top:12px;border:1px solid var(--line);border-radius:12px;overflow:hidden}.report-wrap.open{display:block}.report-frame{display:block;width:100%;height:min(78vh,900px);border:0;background:#fff}
.nothing{display:none;padding:50px;text-align:center;color:var(--muted)}dialog{width:min(96vw,1500px);padding:0;border:0;border-radius:15px;background:#fff;box-shadow:0 25px 90px rgba(0,0,0,.35)}dialog::backdrop{background:rgba(5,16,11,.76)}.modal-head{display:flex;align-items:center;justify-content:space-between;padding:10px 14px;border-bottom:1px solid var(--line)}.modal-title{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.close{width:34px;height:34px;border:0;border-radius:8px;background:#edf2ef;cursor:pointer;font-size:20px}.modal-img{display:block;max-width:96vw;max-height:88vh;margin:auto;object-fit:contain}
@media(max-width:820px){.layout{display:block}.side{position:static;width:auto;height:auto;padding:14px 18px;border:0;border-bottom:1px solid var(--line)}.brand{margin:0}.nav{display:none}.main{padding-top:18px}.hero{padding:25px 20px}.result,.bundle-panel{padding:18px}.result-head{display:block}.badges{justify-content:flex-start;margin-top:10px}.metrics{grid-template-columns:repeat(2,minmax(0,1fr))}}
@media print{.side,.toolbar,.actions,dialog{display:none!important}.layout{display:block}.main{padding:0}.hero,.result,.bundle-panel{box-shadow:none}.result{break-inside:avoid;margin:15px 0}}
</style>
</head>
<body>
<div class="layout">
  <aside class="side"><div class="brand"><span class="brand-mark">Q</span> FEP Results</div><nav class="nav" id="nav"></nav></aside>
  <main class="main">
    <header class="hero"><h1>FEP Results Dashboard</h1><p>Figures and metrics reports in one portable bundle.</p><div class="stats" id="stats"></div></header>
    <div class="toolbar"><input class="search" id="search" type="search" placeholder="Search targets or filenames…" aria-label="Search results"><span class="result-count" id="result-count"></span></div>
    <section class="bundle-panel"><h2>Bundle inventory</h2><p>This bundle contains only PNG figures and metrics reports. <a href="bundle_manifest.json" target="_blank">Open the JSON manifest ↗</a></p></section>
    <section class="results" id="results"></section><div class="nothing" id="nothing">No matching results</div>
  </main>
</div>
<dialog id="viewer"><div class="modal-head"><span class="modal-title" id="modal-title"></span><button class="close" aria-label="Close">×</button></div><img class="modal-img" id="modal-img" alt=""></dialog>
<script>
const DASHBOARD=__DASHBOARD_DATA__;
const DATA=DASHBOARD.results;
const escapeHtml=s=>String(s).replace(/[&<>'"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[c]));
const fileName=path=>path.split('/').pop();
function render(){
  const summary=DASHBOARD.summary;
  document.querySelector('#stats').innerHTML=[`${summary.targets} targets`,`${summary.images} images`,`${summary.reports} metric reports`,`${summary.files.toLocaleString()} assets · ${summary.size}`,`Updated ${DASHBOARD.generated}`].map(value=>`<span class="stat"><b>${escapeHtml(value)}</b></span>`).join('');
  const root=document.querySelector('#results'),nav=document.querySelector('#nav');
  DATA.forEach((item,index)=>{
    const id=`target-${index}`;
    nav.insertAdjacentHTML('beforeend',`<a href="#${id}">${escapeHtml(item.target)}</a>`);
    const metrics=item.metrics.map(m=>`<div class="metric" title="${escapeHtml(m.note)}"><div class="metric-label">${escapeHtml(m.label)}</div><div class="metric-value">${escapeHtml(m.value)}</div><div class="metric-note">${escapeHtml(m.note)}</div></div>`).join('');
    const images=item.pngs.length?item.pngs.map(path=>`<figure class="figure"><button class="image-button" data-path="${escapeHtml(path)}" data-title="${escapeHtml(item.target+' · '+fileName(path))}"><img src="${escapeHtml(path)}" loading="lazy" alt="${escapeHtml(item.target+' '+fileName(path))}"></button><figcaption title="${escapeHtml(path)}">${escapeHtml(fileName(path))}</figcaption></figure>`).join(''):'<div class="empty">No PNG images in this result folder</div>';
    const report=item.report?`<button class="action toggle-report" data-report="${escapeHtml(item.report)}">Expand metrics report</button><a class="action" href="${escapeHtml(item.report)}" target="_blank">Open report separately ↗</a>`:'<span class="badge missing">Missing metrics_report.html</span>';
    root.insertAdjacentHTML('beforeend',`<article class="result" id="${id}" data-search="${escapeHtml((item.target+' '+item.folder+' '+item.pngs.join(' ')).toLowerCase())}"><div class="result-head"><div><h2>${escapeHtml(item.target)}</h2><div class="folder">${escapeHtml(item.folder)}</div></div><div class="badges"><span class="badge">${item.pngs.length} PNG</span><span class="badge${item.report?'':' missing'}">${item.report?'Metrics report':'Missing report'}</span><span class="badge">${item.file_count.toLocaleString()} assets · ${escapeHtml(item.size)}</span></div></div>${metrics?`<div class="metrics">${metrics}</div>`:''}<div class="gallery">${images}</div><div class="actions">${report}</div>${item.report?`<div class="report-wrap"><iframe class="report-frame" title="${escapeHtml(item.target)} metrics report"></iframe></div>`:''}</article>`);
  });
  updateCount();
}
function updateCount(){const visible=[...document.querySelectorAll('.result')].filter(el=>!el.hidden).length;document.querySelector('#result-count').textContent=`Showing ${visible} / ${DATA.length}`;document.querySelector('#nothing').style.display=visible?'none':'block'}
document.addEventListener('click',event=>{
  const imageButton=event.target.closest('.image-button');
  if(imageButton){document.querySelector('#modal-img').src=imageButton.dataset.path;document.querySelector('#modal-title').textContent=imageButton.dataset.title;document.querySelector('#viewer').showModal();return}
  const toggle=event.target.closest('.toggle-report');
  if(toggle){const wrap=toggle.closest('.result').querySelector('.report-wrap'),frame=wrap.querySelector('iframe'),opening=!wrap.classList.contains('open');wrap.classList.toggle('open',opening);toggle.textContent=opening?'Collapse metrics report':'Expand metrics report';if(opening&&!frame.src)frame.src=toggle.dataset.report}
});
document.querySelector('.close').addEventListener('click',()=>document.querySelector('#viewer').close());
document.querySelector('#viewer').addEventListener('click',event=>{if(event.target===event.currentTarget)event.currentTarget.close()});
document.querySelector('#search').addEventListener('input',event=>{const q=event.target.value.trim().toLowerCase();document.querySelectorAll('.result').forEach(el=>el.hidden=q&&!el.dataset.search.includes(q));updateCount()});
render();
</script>
</body>
</html>
"""


if __name__ == "__main__":
    raise SystemExit(main())
