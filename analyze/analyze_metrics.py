#!/usr/bin/env python3
"""Build a self-contained HTML resource report from downloaded QGPU metrics.

Current result directories contain:

    jobs/<job>.both/metrics/qgpu_mps_summary.tsv  (MPS)
    jobs/<job>.both/metrics/qgpu_batch_summary.tsv  (batch)
    jobs/<job>.both/metrics/raw/*

The older consolidated ``metrics/<job>.both`` layout is also accepted.

Only the Python standard library is required.
"""

from __future__ import annotations

import argparse
import csv
import html
import math
import re
import statistics
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Iterable


DONE_RE = re.compile(
    r"DONE\s+fep=(?P<fep>\S+)\s+system=(?P<system>\S+)\s+rep=(?P<rep>\d+)"
    r"\s+step=(?P<step>\S+)\s+wall_sec=(?P<wall>\d+(?:\.\d+)?)"
    r"\s+exit_code=(?P<exit>-?\d+)"
)


def arguments() -> argparse.Namespace:
    repo_root = Path(__file__).resolve().parents[1]
    default_data = repo_root / "my_result" / "cmet"
    parser = argparse.ArgumentParser(
        description="Analyze QGPU timing, CPU, memory, GPU, and power metrics."
    )
    parser.add_argument(
        "data_dir",
        nargs="?",
        type=Path,
        default=default_data,
        help=f"Downloaded or extracted result directory (default: {default_data})",
    )
    parser.add_argument(
        "--output",
        "-o",
        type=Path,
        help="HTML output path (default: DATA_DIR/metrics_report.html)",
    )
    return parser.parse_args()


def number(value: object, default: float = math.nan) -> float:
    try:
        return float(str(value).strip())
    except (TypeError, ValueError):
        return default


def integer(value: object, default: int = 0) -> int:
    try:
        return int(float(str(value).strip()))
    except (TypeError, ValueError):
        return default


def finite(values: Iterable[float]) -> list[float]:
    return [value for value in values if math.isfinite(value)]


def mean(values: Iterable[float]) -> float:
    clean = finite(values)
    return statistics.fmean(clean) if clean else math.nan


def maximum(values: Iterable[float]) -> float:
    clean = finite(values)
    return max(clean) if clean else math.nan


def percentile(values: Iterable[float], fraction: float) -> float:
    clean = sorted(finite(values))
    if not clean:
        return math.nan
    position = (len(clean) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return clean[lower]
    return clean[lower] + (clean[upper] - clean[lower]) * (position - lower)


def fmt(value: float, digits: int = 1, suffix: str = "") -> str:
    if not math.isfinite(value):
        return "—"
    return f"{value:,.{digits}f}{suffix}"


def duration(seconds: float) -> str:
    if not math.isfinite(seconds):
        return "—"
    seconds = max(0, round(seconds))
    hours, remainder = divmod(seconds, 3600)
    minutes, secs = divmod(remainder, 60)
    if hours:
        return f"{hours}h {minutes:02d}m"
    if minutes:
        return f"{minutes}m {secs:02d}s"
    return f"{secs}s"


def parse_time(value: str) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value)
    except ValueError:
        return None


def read_dicts(path: Path, delimiter: str) -> list[dict[str, str]]:
    try:
        with path.open(newline="", encoding="utf-8", errors="replace") as handle:
            return list(csv.DictReader(handle, delimiter=delimiter))
    except (OSError, csv.Error):
        return []


@dataclass
class SystemRun:
    job: str
    fep_id: str
    system: str
    status: str
    start: datetime | None
    end: datetime | None
    wall_sec: float
    replicates: int
    cpu_avg_cores_pct: float = math.nan
    cpu_peak_cores_pct: float = math.nan
    cpu_avg_node_pct: float = math.nan
    cpu_peak_node_pct: float = math.nan
    rss_avg_mb: float = math.nan
    rss_peak_mb: float = math.nan
    gpu_avg_pct: float = math.nan
    gpu_peak_pct: float = math.nan
    gpu_mem_avg_mb: float = math.nan
    gpu_mem_peak_mb: float = math.nan
    gpu_mem_total_mb: float = math.nan
    gpu_power_avg_w: float = math.nan
    gpu_power_peak_w: float = math.nan
    cpu_samples: int = 0
    gpu_samples: int = 0
    source_warnings: list[str] = field(default_factory=list)

    @property
    def cpu_core_hours(self) -> float:
        return self.cpu_avg_cores_pct / 100 * self.wall_sec / 3600

    @property
    def gpu_hours(self) -> float:
        return self.wall_sec / 3600

    @property
    def gpu_energy_kwh(self) -> float:
        return self.gpu_power_avg_w * self.wall_sec / 3_600_000


@dataclass
class StepMetric:
    step: str
    system: str
    wall_sec: float
    exit_code: int


def matching_raw(raw_dir: Path, system: str, suffix: str) -> Path | None:
    matches = sorted(raw_dir.glob(f"*.{system}.{suffix}"))
    return matches[0] if matches else None


def load_cpu(run: SystemRun, path: Path | None) -> None:
    rows = read_dicts(path, ",") if path else []
    if not rows:
        run.source_warnings.append(f"missing {run.system} CPU/RSS samples")
        return
    run.cpu_samples = len(rows)
    run.cpu_avg_cores_pct = mean(number(row.get("cpu_pct_cores")) for row in rows)
    run.cpu_peak_cores_pct = maximum(number(row.get("cpu_pct_cores")) for row in rows)
    run.cpu_avg_node_pct = mean(number(row.get("cpu_pct_node")) for row in rows)
    run.cpu_peak_node_pct = maximum(number(row.get("cpu_pct_node")) for row in rows)
    run.rss_avg_mb = mean(number(row.get("rss_mb")) for row in rows)
    run.rss_peak_mb = maximum(number(row.get("rss_mb")) for row in rows)


def load_gpu(run: SystemRun, path: Path | None) -> None:
    rows = read_dicts(path, ",") if path else []
    if not rows:
        run.source_warnings.append(f"missing {run.system} GPU samples")
        return
    run.gpu_samples = len(rows)
    run.gpu_avg_pct = mean(number(row.get("gpu_util_pct")) for row in rows)
    run.gpu_peak_pct = maximum(number(row.get("gpu_util_pct")) for row in rows)
    run.gpu_mem_avg_mb = mean(number(row.get("gpu_mem_used_mb")) for row in rows)
    run.gpu_mem_peak_mb = maximum(number(row.get("gpu_mem_used_mb")) for row in rows)
    run.gpu_mem_total_mb = maximum(number(row.get("gpu_mem_total_mb")) for row in rows)
    run.gpu_power_avg_w = mean(number(row.get("gpu_power_w")) for row in rows)
    run.gpu_power_peak_w = maximum(number(row.get("gpu_power_w")) for row in rows)


def find_metric_jobs(data_dir: Path) -> list[Path]:
    """Locate current job-local metrics or the legacy metrics tree."""
    jobs_dir = data_dir / "jobs"
    if jobs_dir.is_dir():
        jobs = sorted(
            path / "metrics"
            for path in jobs_dir.iterdir()
            if path.is_dir() and (path / "metrics").is_dir()
        )
        if jobs:
            return jobs

    metrics_dir = data_dir / "metrics"
    if metrics_dir.is_dir():
        jobs = sorted(path for path in metrics_dir.iterdir() if path.is_dir())
        if jobs:
            return jobs

    if data_dir.is_dir() and data_dir.name == "jobs":
        jobs = sorted(
            path / "metrics"
            for path in data_dir.iterdir()
            if path.is_dir() and (path / "metrics").is_dir()
        )
        if jobs:
            return jobs

    raise SystemExit(
        f"No job metrics found under {data_dir / 'jobs'} or {data_dir / 'metrics'}"
    )


def load_metrics(data_dir: Path) -> tuple[list[SystemRun], list[StepMetric], list[str]]:
    jobs = find_metric_jobs(data_dir)

    runs: list[SystemRun] = []
    steps: list[StepMetric] = []
    warnings: list[str] = []

    for job_dir in jobs:
        job_name = job_dir.parent.name if job_dir.name == "metrics" else job_dir.name
        summaries = [
            job_dir / "qgpu_mps_summary.tsv",
            job_dir / "qgpu_batch_summary.tsv",
        ]
        summary = next((path for path in summaries if path.is_file()), summaries[0])
        rows = read_dicts(summary, "\t")
        if not rows:
            warnings.append(
                f"{job_name}: missing or empty qgpu_mps_summary.tsv/qgpu_batch_summary.tsv"
            )
            continue
        raw_dir = job_dir / "raw"
        for row in rows:
            system = row.get("system", "unknown").strip()
            wall = number(row.get("wall_sec"))
            start = parse_time(row.get("start_time", ""))
            end = parse_time(row.get("end_time", ""))
            if not math.isfinite(wall) and start and end:
                wall = (end - start).total_seconds()
            run = SystemRun(
                job=job_name,
                fep_id=row.get("fep_id", job_name).strip(),
                system=system,
                status=row.get("status", "unknown").strip(),
                start=start,
                end=end,
                wall_sec=wall,
                replicates=integer(row.get("replicates_done")),
            )
            load_cpu(run, matching_raw(raw_dir, system, "cpu_mem.csv"))
            load_gpu(run, matching_raw(raw_dir, system, "gpu.csv"))
            runs.append(run)

        for log_path in sorted(raw_dir.glob("*.runner.log")):
            try:
                text = log_path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                warnings.append(f"{job_name}: could not read {log_path.name}")
                continue
            for match in DONE_RE.finditer(text):
                steps.append(
                    StepMetric(
                        step=match.group("step"),
                        system=match.group("system"),
                        wall_sec=float(match.group("wall")),
                        exit_code=int(match.group("exit")),
                    )
                )
    return runs, steps, warnings


def weighted(runs: Iterable[SystemRun], attribute: str, weight: str = "wall_sec") -> float:
    pairs = []
    for run in runs:
        value = getattr(run, attribute)
        weight_value = getattr(run, weight)
        if math.isfinite(value) and math.isfinite(weight_value) and weight_value > 0:
            pairs.append((value, weight_value))
    total = sum(item[1] for item in pairs)
    return sum(value * item_weight for value, item_weight in pairs) / total if total else math.nan


def esc(value: object) -> str:
    return html.escape(str(value), quote=True)


def metric_card(label: str, value: str, note: str) -> str:
    return (
        '<div class="metric">'
        f'<div class="metric-label">{esc(label)}</div>'
        f'<div class="metric-value">{esc(value)}</div>'
        f'<div class="metric-note">{esc(note)}</div>'
        "</div>"
    )


def bar_chart(title: str, items: list[tuple[str, float, str]], unit: str) -> str:
    if not items:
        return ""
    max_value = max((value for _, value, _ in items), default=1) or 1
    bars = []
    for label, value, detail in items:
        width = max(0.5, value / max_value * 100)
        bars.append(
            '<div class="bar-row">'
            f'<div class="bar-label" title="{esc(label)}">{esc(label)}</div>'
            '<div class="bar-track">'
            f'<div class="bar-fill" style="width:{width:.2f}%"></div>'
            "</div>"
            f'<div class="bar-value">{fmt(value, 1, unit)}<small>{esc(detail)}</small></div>'
            "</div>"
        )
    return f'<section class="panel"><h2>{esc(title)}</h2><div class="bars">{"".join(bars)}</div></section>'


def aggregate_steps(steps: list[StepMetric]) -> list[dict[str, object]]:
    grouped: dict[tuple[str, str], list[StepMetric]] = defaultdict(list)
    for step in steps:
        grouped[(step.system, step.step)].append(step)
    rows = []
    for (system, step_name), values in grouped.items():
        times = [step.wall_sec for step in values]
        rows.append(
            {
                "system": system,
                "step": step_name,
                "count": len(values),
                "mean": mean(times),
                "p50": percentile(times, 0.50),
                "p95": percentile(times, 0.95),
                "max": maximum(times),
                "total": sum(times),
                "failures": sum(step.exit_code != 0 for step in values),
            }
        )
    return sorted(rows, key=lambda row: float(row["total"]), reverse=True)


def table_header(columns: list[tuple[str, str]]) -> str:
    return "<thead><tr>" + "".join(
        f'<th data-key="{esc(key)}">{esc(label)} <span class="sort">↕</span></th>'
        for key, label in columns
    ) + "</tr></thead>"


def system_comparison(runs: list[SystemRun]) -> str:
    rows = []
    for system in sorted({run.system for run in runs}):
        subset = [run for run in runs if run.system == system]
        rows.append(
            "<tr>"
            f"<td>{esc(system)}</td>"
            f'<td data-sort="{sum(run.wall_sec for run in subset):.6f}">{duration(sum(run.wall_sec for run in subset))}</td>'
            f'<td data-sort="{mean(run.wall_sec for run in subset):.6f}">{duration(mean(run.wall_sec for run in subset))}</td>'
            f'<td data-sort="{weighted(subset, "cpu_avg_cores_pct"):.6f}">{fmt(weighted(subset, "cpu_avg_cores_pct") / 100, 1)}</td>'
            f'<td data-sort="{maximum(run.rss_peak_mb for run in subset):.6f}">{fmt(maximum(run.rss_peak_mb for run in subset) / 1024, 2, " GiB")}</td>'
            f'<td data-sort="{weighted(subset, "gpu_avg_pct"):.6f}">{fmt(weighted(subset, "gpu_avg_pct"), 1, "%")}</td>'
            f'<td data-sort="{weighted(subset, "gpu_mem_avg_mb"):.6f}">{fmt(weighted(subset, "gpu_mem_avg_mb") / 1024, 2, " GiB")}</td>'
            f'<td data-sort="{weighted(subset, "gpu_power_avg_w"):.6f}">{fmt(weighted(subset, "gpu_power_avg_w"), 1, " W")}</td>'
            "</tr>"
        )
    columns = [
        ("system", "System"),
        ("total", "Total wall"),
        ("mean", "Mean / run"),
        ("cpu", "Mean CPU cores"),
        ("rss", "Peak RSS"),
        ("gpu", "Mean GPU"),
        ("vram", "Mean VRAM"),
        ("power", "Mean power"),
    ]
    return (
        '<section class="panel"><h2>Protein vs water</h2>'
        '<div class="table-wrap"><table class="sortable">'
        f"{table_header(columns)}<tbody>{''.join(rows)}</tbody></table></div></section>"
    )


def job_table(runs: list[SystemRun]) -> str:
    grouped: dict[str, list[SystemRun]] = defaultdict(list)
    for run in runs:
        grouped[run.job].append(run)
    rows = []
    for job, job_runs in grouped.items():
        wall = sum(run.wall_sec for run in job_runs)
        peak_rss = maximum(run.rss_peak_mb for run in job_runs)
        peak_vram = maximum(run.gpu_mem_peak_mb for run in job_runs)
        status = "ok" if all(run.status == "ok" for run in job_runs) else "check"
        systems = {run.system: run for run in job_runs}
        water = systems.get("water")
        protein = systems.get("protein")
        warning_count = sum(len(run.source_warnings) for run in job_runs)
        rows.append(
            "<tr>"
            f'<td class="job-name" title="{esc(job)}">{esc(job)}</td>'
            f'<td><span class="status {status}">{status}</span></td>'
            f'<td data-sort="{wall:.6f}">{duration(wall)}</td>'
            f'<td data-sort="{water.wall_sec if water else -1:.6f}">{duration(water.wall_sec) if water else "—"}</td>'
            f'<td data-sort="{protein.wall_sec if protein else -1:.6f}">{duration(protein.wall_sec) if protein else "—"}</td>'
            f'<td data-sort="{weighted(job_runs, "cpu_avg_cores_pct"):.6f}">{fmt(weighted(job_runs, "cpu_avg_cores_pct") / 100, 1)}</td>'
            f'<td data-sort="{peak_rss:.6f}">{fmt(peak_rss / 1024, 2, " GiB")}</td>'
            f'<td data-sort="{weighted(job_runs, "gpu_avg_pct"):.6f}">{fmt(weighted(job_runs, "gpu_avg_pct"), 1, "%")}</td>'
            f'<td data-sort="{peak_vram:.6f}">{fmt(peak_vram / 1024, 2, " GiB")}</td>'
            f'<td data-sort="{sum(run.gpu_energy_kwh for run in job_runs):.6f}">{fmt(sum(run.gpu_energy_kwh for run in job_runs), 3, " kWh")}</td>'
            f'<td data-sort="{warning_count}">{warning_count or "—"}</td>'
            "</tr>"
        )
    columns = [
        ("job", "Job"),
        ("status", "Status"),
        ("total", "Total wall"),
        ("water", "Water"),
        ("protein", "Protein"),
        ("cpu", "CPU cores"),
        ("rss", "Peak RSS"),
        ("gpu", "GPU avg"),
        ("vram", "Peak VRAM"),
        ("energy", "GPU energy"),
        ("warnings", "Missing data"),
    ]
    return (
        '<section class="panel wide"><div class="section-heading"><h2>All jobs</h2>'
        '<input id="job-filter" type="search" placeholder="Filter jobs…" aria-label="Filter jobs"></div>'
        '<div class="table-wrap tall"><table id="jobs" class="sortable">'
        f"{table_header(columns)}<tbody>{''.join(rows)}</tbody></table></div></section>"
    )


def step_table(steps: list[StepMetric]) -> str:
    rows = []
    for row in aggregate_steps(steps):
        rows.append(
            "<tr>"
            f"<td>{esc(row['system'])}</td><td>{esc(row['step'])}</td>"
            f'<td data-sort="{row["count"]}">{row["count"]}</td>'
            f'<td data-sort="{row["mean"]:.6f}">{duration(float(row["mean"]))}</td>'
            f'<td data-sort="{row["p50"]:.6f}">{duration(float(row["p50"]))}</td>'
            f'<td data-sort="{row["p95"]:.6f}">{duration(float(row["p95"]))}</td>'
            f'<td data-sort="{row["max"]:.6f}">{duration(float(row["max"]))}</td>'
            f'<td data-sort="{row["total"]:.6f}">{duration(float(row["total"]))}</td>'
            f'<td data-sort="{row["failures"]}">{row["failures"] or "—"}</td>'
            "</tr>"
        )
    columns = [
        ("system", "System"),
        ("step", "Step"),
        ("n", "Samples"),
        ("mean", "Mean"),
        ("p50", "P50"),
        ("p95", "P95"),
        ("max", "Max"),
        ("total", "Replicate total"),
        ("failures", "Failures"),
    ]
    return (
        '<section class="panel wide"><div class="section-heading"><div><h2>Step timing</h2>'
        '<p class="subtle">Replicates run concurrently; “replicate total” is compute-time summed across replicas, not elapsed campaign time.</p></div>'
        '<input id="step-filter" type="search" placeholder="Filter steps…" aria-label="Filter steps"></div>'
        '<div class="table-wrap tall"><table id="steps" class="sortable">'
        f"{table_header(columns)}<tbody>{''.join(rows)}</tbody></table></div></section>"
    )


def make_html(
    data_dir: Path, runs: list[SystemRun], steps: list[StepMetric], load_warnings: list[str]
) -> str:
    jobs = sorted({run.job for run in runs})
    total_wall = sum(run.wall_sec for run in runs)
    cpu_core_hours = sum(run.cpu_core_hours for run in runs if math.isfinite(run.cpu_core_hours))
    gpu_hours = sum(run.gpu_hours for run in runs if math.isfinite(run.gpu_hours))
    energy_kwh = sum(run.gpu_energy_kwh for run in runs if math.isfinite(run.gpu_energy_kwh))
    raw_warnings = [f"{run.job}: {warning}" for run in runs for warning in run.source_warnings]
    warnings = load_warnings + raw_warnings
    ok_runs = sum(run.status == "ok" for run in runs)
    peak_rss = maximum(run.rss_peak_mb for run in runs)
    peak_vram = maximum(run.gpu_mem_peak_mb for run in runs)
    gpu_avg = weighted(runs, "gpu_avg_pct")
    cpu_cores_avg = weighted(runs, "cpu_avg_cores_pct") / 100
    power_avg = weighted(runs, "gpu_power_avg_w")
    gpu_mem_total = maximum(run.gpu_mem_total_mb for run in runs)

    cards = "".join(
        [
            metric_card("Jobs", str(len(jobs)), f"{ok_runs}/{len(runs)} system runs OK"),
            metric_card("Summed wall time", duration(total_wall), f"{gpu_hours:.1f} GPU-hours"),
            metric_card("CPU work", f"{cpu_core_hours:.1f} core-h", f"{cpu_cores_avg:.1f} average cores"),
            metric_card("GPU utilization", fmt(gpu_avg, 1, "%"), f"{fmt(power_avg, 0, ' W')} average power"),
            metric_card("GPU energy", fmt(energy_kwh, 2, " kWh"), "estimate from sampled board power"),
            metric_card("Peak host memory", fmt(peak_rss / 1024, 2, " GiB"), "maximum combined process RSS"),
            metric_card(
                "Peak GPU memory",
                fmt(peak_vram / 1024, 2, " GiB"),
                f"of {fmt(gpu_mem_total / 1024, 1, ' GiB')} available",
            ),
        ]
    )

    slowest = sorted(runs, key=lambda run: run.wall_sec, reverse=True)[:10]
    slow_chart = bar_chart(
        "Slowest system runs",
        [(f"{run.fep_id} · {run.system}", run.wall_sec / 60, f" {run.system}") for run in slowest],
        " min",
    )
    memory = sorted(runs, key=lambda run: run.rss_peak_mb, reverse=True)[:10]
    memory_chart = bar_chart(
        "Highest host-memory runs",
        [(f"{run.fep_id} · {run.system}", run.rss_peak_mb / 1024, f" {run.system}") for run in memory],
        " GiB",
    )
    warning_html = ""
    if warnings:
        warning_html = (
            '<section class="panel warning"><h2>Data warnings</h2><ul>'
            + "".join(f"<li>{esc(warning)}</li>" for warning in warnings)
            + "</ul></section>"
        )
    else:
        warning_html = (
            '<section class="panel success"><h2>Data quality</h2>'
            f"<p>All {len(runs)} system summaries have readable CPU/RSS and GPU samples.</p></section>"
        )

    generated = datetime.now().astimezone().isoformat(timespec="seconds")
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>QGPU metrics report</title>
<style>
:root {{ --bg:#f3f6f4; --panel:#fff; --ink:#17231d; --muted:#627068; --line:#dce5df;
  --accent:#087f5b; --accent2:#36b37e; --warn:#9a6700; --shadow:0 10px 30px rgba(20,40,30,.07); }}
* {{ box-sizing:border-box; }}
body {{ margin:0; color:var(--ink); background:var(--bg); font:14px/1.45 Inter,ui-sans-serif,system-ui,-apple-system,sans-serif; }}
.shell {{ max-width:1500px; margin:auto; padding:36px 28px 64px; }}
header {{ padding:32px; color:#fff; background:linear-gradient(120deg,#073b30,#087f5b 60%,#23a879); border-radius:18px; box-shadow:var(--shadow); }}
h1 {{ margin:0 0 8px; font-size:clamp(28px,4vw,46px); line-height:1.05; letter-spacing:-.035em; }}
header p {{ margin:5px 0; color:#d7f5e8; }} header code {{ color:#fff; overflow-wrap:anywhere; }}
.metrics {{ display:grid; grid-template-columns:repeat(4,minmax(0,1fr)); gap:14px; margin:18px 0; }}
.metric,.panel {{ background:var(--panel); border:1px solid var(--line); border-radius:14px; box-shadow:var(--shadow); }}
.metric {{ padding:20px; min-height:130px; }}
.metric-label {{ color:var(--muted); text-transform:uppercase; letter-spacing:.08em; font-size:11px; font-weight:700; }}
.metric-value {{ margin:10px 0 4px; font-size:25px; font-weight:750; letter-spacing:-.025em; }}
.metric-note,.subtle {{ color:var(--muted); font-size:12px; }}
.grid {{ display:grid; grid-template-columns:1fr 1fr; gap:18px; margin:18px 0; }}
.panel {{ padding:22px; min-width:0; }} .panel.wide {{ margin:18px 0; }}
h2 {{ margin:0 0 16px; font-size:18px; letter-spacing:-.01em; }}
.success {{ border-left:4px solid var(--accent2); }} .warning {{ border-left:4px solid #e3a008; }}
.warning ul {{ max-height:180px; overflow:auto; margin-bottom:0; }}
.bars {{ display:grid; gap:9px; }}
.bar-row {{ display:grid; grid-template-columns:minmax(145px,1.35fr) 2fr 105px; align-items:center; gap:10px; }}
.bar-label {{ white-space:nowrap; overflow:hidden; text-overflow:ellipsis; color:#34443b; }}
.bar-track {{ height:12px; background:#e8efeb; border-radius:99px; overflow:hidden; }}
.bar-fill {{ height:100%; border-radius:99px; background:linear-gradient(90deg,var(--accent),var(--accent2)); }}
.bar-value {{ text-align:right; font-variant-numeric:tabular-nums; font-weight:650; }}
.bar-value small {{ display:block; color:var(--muted); font-weight:400; }}
.section-heading {{ display:flex; align-items:start; justify-content:space-between; gap:20px; }}
.section-heading h2 {{ margin-bottom:4px; }} .section-heading p {{ margin:0 0 12px; }}
input {{ width:min(290px,100%); border:1px solid #cbd8d0; border-radius:9px; padding:9px 12px; background:#fbfdfc; color:var(--ink); }}
.table-wrap {{ overflow:auto; border:1px solid var(--line); border-radius:10px; }} .table-wrap.tall {{ max-height:590px; }}
table {{ width:100%; border-collapse:collapse; font-variant-numeric:tabular-nums; }}
th,td {{ padding:10px 12px; text-align:right; border-bottom:1px solid #e8eeea; white-space:nowrap; }}
th:first-child,td:first-child, #steps th:nth-child(2),#steps td:nth-child(2) {{ text-align:left; }}
th {{ position:sticky; top:0; z-index:1; background:#f7faf8; color:#506159; font-size:11px; text-transform:uppercase; letter-spacing:.055em; cursor:pointer; }}
tbody tr:hover {{ background:#f5faf7; }} tbody tr:last-child td {{ border-bottom:0; }}
.job-name {{ max-width:440px; overflow:hidden; text-overflow:ellipsis; }}
.sort {{ color:#a0ada5; }} .status {{ display:inline-block; padding:2px 8px; border-radius:99px; font-size:11px; font-weight:700; text-transform:uppercase; }}
.status.ok {{ color:#087252; background:#dff6ec; }} .status.check {{ color:#8a5a00; background:#fff2cd; }}
footer {{ color:var(--muted); text-align:center; margin-top:28px; font-size:12px; }}
@media (max-width:1000px) {{ .metrics {{ grid-template-columns:repeat(2,1fr); }} .grid {{ grid-template-columns:1fr; }} }}
@media (max-width:620px) {{ .shell {{ padding:16px 10px 40px; }} header {{ padding:24px 20px; }} .metrics {{ grid-template-columns:1fr; }}
  .section-heading {{ display:block; }} .section-heading input {{ margin-bottom:12px; }} .bar-row {{ grid-template-columns:120px 1fr 82px; }} }}
@media print {{ body {{ background:#fff; }} .shell {{ max-width:none; padding:0; }} .metric,.panel,header {{ box-shadow:none; }} input {{ display:none; }} .table-wrap.tall {{ max-height:none; }} }}
</style>
</head>
<body><main class="shell">
<header>
  <h1>QGPU metrics report</h1>
  <p>Timing, CPU, host memory, GPU utilization, VRAM, power, and per-step performance.</p>
  <p><code>{esc(data_dir.resolve())}</code></p>
</header>
<section class="metrics">{cards}</section>
<div class="grid">{system_comparison(runs)}{warning_html}</div>
<div class="grid">{slow_chart}{memory_chart}</div>
{job_table(runs)}
{step_table(steps)}
<footer>Generated {esc(generated)} · Raw sample statistics are recomputed from the downloaded CSV files · Hover and click table headers to sort.</footer>
</main>
<script>
function cellValue(row, index) {{
  const cell = row.cells[index];
  const explicit = cell.dataset.sort;
  if (explicit !== undefined && explicit !== "") return Number(explicit);
  const text = cell.textContent.trim().toLowerCase();
  const number = Number(text.replace(/[^0-9.+-]/g, ""));
  return Number.isFinite(number) && /\\d/.test(text) ? number : text;
}}
document.querySelectorAll("table.sortable").forEach(table => {{
  table.querySelectorAll("th").forEach((header, index) => {{
    header.addEventListener("click", () => {{
      const body = table.tBodies[0];
      const ascending = header.dataset.direction !== "asc";
      table.querySelectorAll("th").forEach(th => delete th.dataset.direction);
      header.dataset.direction = ascending ? "asc" : "desc";
      [...body.rows].sort((a,b) => {{
        const x=cellValue(a,index), y=cellValue(b,index);
        const cmp = typeof x === "number" && typeof y === "number" ? x-y : String(x).localeCompare(String(y));
        return ascending ? cmp : -cmp;
      }}).forEach(row => body.appendChild(row));
    }});
  }});
}});
function bindFilter(inputId, tableId) {{
  const input=document.getElementById(inputId), rows=document.querySelectorAll(`#${{tableId}} tbody tr`);
  input.addEventListener("input", () => {{
    const query=input.value.toLowerCase();
    rows.forEach(row => row.hidden = !row.textContent.toLowerCase().includes(query));
  }});
}}
bindFilter("job-filter","jobs"); bindFilter("step-filter","steps");
</script>
</body></html>
"""


def main() -> int:
    args = arguments()
    data_dir = args.data_dir.expanduser().resolve()
    result_root = data_dir.parent if data_dir.name == "jobs" else data_dir
    default_output = result_root / "metrics_report.html"
    output = (args.output or default_output).expanduser().resolve()
    runs, steps, warnings = load_metrics(data_dir)
    if not runs:
        raise SystemExit(f"No system metrics could be loaded from {data_dir}")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(make_html(data_dir, runs, steps, warnings), encoding="utf-8")
    print(f"Analyzed {len({run.job for run in runs})} jobs / {len(runs)} system runs")
    print(f"System status: {sum(run.status == 'ok' for run in runs)} ok, {sum(run.status != 'ok' for run in runs)} check")
    print(f"Raw samples: {sum(run.cpu_samples for run in runs):,} CPU/RSS, {sum(run.gpu_samples for run in runs):,} GPU")
    print(f"Step records: {len(steps):,}")
    print(f"Report: {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
