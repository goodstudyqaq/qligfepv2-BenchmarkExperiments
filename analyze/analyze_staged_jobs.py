#!/usr/bin/env python3
"""Analyze current or legacy QGPU MPS FEP job results.

Current jobs keep the run tree under ``jobs/<job>/work``.  Older jobs stored
the same tree in ``jobs/<job>/staged_run.tar.gz``.  Both layouts are accepted.
"""

from __future__ import annotations

import argparse
import csv
import io
import json
import math
import re
import statistics
import tarfile
from pathlib import Path


BAR_HEADER = "# Part 6: BAR Bennet"
QFEP_PATH = re.compile(
    r"(?:^|/)(1\.water|2\.protein)/(FEP_[^/]+)/FEP1/([^/]+)/([^/]+)/qfep\.out$"
)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate QGPU .both jobs and calculate protein-water BAR ddG values."
    )
    parser.add_argument(
        "data_dir",
        type=Path,
        help="Directory containing jobs/, or the jobs/ directory itself",
    )
    parser.add_argument("--output", "-o", type=Path, help="Output directory (default: DATA_DIR/ddg_analysis)")
    parser.add_argument("--mapping", type=Path, default=Path("mapping.json"), help="Mapping JSON with experimental edge ddg_value values")
    parser.add_argument("--compare", type=Path, help="Optional previous ddg_summary.csv")
    parser.add_argument("--expected-replicates", type=int, default=10)
    return parser.parse_args()


def parse_bar(text: str, source: str) -> float:
    in_bar = False
    final_sum = None
    for line in text.splitlines():
        stripped = line.strip()
        if not in_bar:
            if stripped.startswith(BAR_HEADER):
                in_bar = True
            continue
        if stripped.startswith("# Part "):
            break
        fields = stripped.split()
        if len(fields) < 3:
            continue
        try:
            float(fields[0]); float(fields[1]); final_sum = float(fields[2])
        except ValueError:
            continue
    if final_sum is None:
        raise ValueError(f"No BAR sum(dG) found in {source}")
    return final_sum


def experimental_edges(path: Path) -> dict[str, float]:
    if not path.is_file():
        return {}
    with path.open() as handle:
        data = json.load(handle)
    result = {}
    for edge in data.get("edges", []):
        if "ddg_value" not in edge:
            continue
        left, right = str(edge["from"]), str(edge["to"])
        # Some historical mappings append an execution label to a ligand name.
        right = re.sub(r"_(?:gpu|spfp_test)$", "", right)
        result[f"FEP_{left}_{right}"] = float(edge["ddg_value"])
    return result


def read_old_summary(path: Path | None) -> tuple[dict[str, float], dict[str, float]]:
    if path is None or not path.is_file():
        return {}, {}
    result, experiments = {}, {}
    with path.open(newline="") as handle:
        for row in csv.DictReader(handle):
            value = row.get("Q_ddG_avg") or row.get("ddG_avg")
            if value not in (None, ""):
                result[row["fep_id"]] = float(value)
            exp_value = row.get("exp_ddG_from_minus_to") or row.get("exp_ddG")
            if exp_value not in (None, ""):
                experiments[row["fep_id"]] = float(exp_value)
    return result, experiments


def write_csv(path: Path, rows: list[dict[str, object]], fields: list[str]) -> None:
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def resolve_jobs_dir(data_dir: Path) -> Path:
    """Accept either the downloaded data root or its jobs directory."""
    data_dir = data_dir.expanduser().resolve()
    nested = data_dir / "jobs"
    if nested.is_dir():
        return nested
    if data_dir.is_dir() and data_dir.name == "jobs":
        return data_dir
    raise SystemExit(
        f"Jobs directory not found: expected {nested} or a directory named jobs"
    )


def qfep_outputs(job: Path) -> tuple[str, list[tuple[str, str]]]:
    """Return (layout, [(source, text), ...]) for one job.

    Prefer the current uncompressed work directory when it exists.  Falling
    back to the legacy archive keeps previously downloaded datasets usable.
    """
    work = job / "work"
    if work.is_dir():
        outputs = []
        for path in sorted(work.rglob("qfep.out")):
            if path.is_file() and QFEP_PATH.search(path.as_posix()):
                outputs.append(
                    (
                        str(path),
                        path.read_text(encoding="utf-8", errors="replace"),
                    )
                )
        return "work", outputs

    archive = job / "staged_run.tar.gz"
    if archive.is_file():
        outputs = []
        with tarfile.open(archive, "r:gz") as tar:
            for member in tar:
                if not member.isfile() or not QFEP_PATH.search(member.name):
                    continue
                extracted = tar.extractfile(member)
                if extracted is None:
                    continue
                text = io.TextIOWrapper(
                    extracted, encoding="utf-8", errors="replace"
                ).read()
                outputs.append((f"{archive}:{member.name}", text))
        return "archive", outputs

    return "missing", []


def job_metadata(job: Path) -> tuple[str, str]:
    """Return the wrapper exit code and validation status for one job."""
    exit_path = job / "exit_code.txt"
    exit_code = exit_path.read_text().strip() if exit_path.is_file() else "missing"
    status_rows = []
    if (job / "summary.tsv").is_file():
        with (job / "summary.tsv").open(newline="") as handle:
            status_rows = list(csv.DictReader(handle, delimiter="\t"))
    status = (
        "ok"
        if exit_code == "0"
        and len(status_rows) == 2
        and all(row.get("status") == "ok" for row in status_rows)
        else "check"
    )
    return exit_code, status


def mps_jobs_by_edge(jobs_dir: Path) -> dict[str, Path]:
    """Map FEP IDs to run_qgpu_mps_slurm result-metadata directories."""
    result: dict[str, Path] = {}
    for job in sorted(path for path in jobs_dir.iterdir() if path.is_dir()):
        run_info = job / "run_info.tsv"
        if not run_info.is_file():
            continue
        with run_info.open(newline="") as handle:
            rows = csv.DictReader(handle, delimiter="\t")
            info = {
                str(row.get("key", "")): str(row.get("value", ""))
                for row in rows
            }
        target = info.get("target", "")
        edge = target if target.startswith("FEP_") else Path(target).name
        if edge.startswith("FEP_"):
            result[edge] = job
    return result


def mps_qfep_outputs(data_root: Path) -> list[Path]:
    """Find qfep outputs written beside staged inputs by the MPS runner."""
    outputs = []
    for system_dir in ("1.water", "2.protein"):
        system_root = data_root / system_dir
        if system_root.is_dir():
            outputs.extend(system_root.glob("FEP_*/FEP1/*/*/qfep.out"))
    return sorted(path for path in outputs if path.is_file())


def append_edge_rows(
    edge: str,
    legs: dict[str, dict[str, float]],
    *,
    source_job: str,
    layout: str,
    exit_code: str,
    initial_status: str,
    expected_replicates: int,
    replicate_rows: list[dict[str, object]],
    job_rows: list[dict[str, object]],
) -> None:
    """Validate one edge and append its paired replicate and job rows."""
    reps = sorted(
        set(legs["water"]) & set(legs["protein"]),
        key=lambda value: int(value) if value.isdigit() else value,
    )
    status = initial_status
    if (
        set(legs["water"]) != set(legs["protein"])
        or len(reps) != expected_replicates
    ):
        status = "check"
    left, right = edge.removeprefix("FEP_").split("_", 1)
    for rep in reps:
        water, protein = legs["water"][rep], legs["protein"][rep]
        replicate_rows.append(
            {
                "fep_id": edge,
                "from": left,
                "to": right,
                "replicate": rep,
                "water_dGbar": f"{water:.6f}",
                "protein_dGbar": f"{protein:.6f}",
                "Q_ddG": f"{protein - water:.6f}",
                "source_job": source_job,
            }
        )
    job_rows.append(
        {
            "fep_id": edge,
            "job": source_job,
            "layout": layout,
            "exit_code": exit_code,
            "status": status,
            "water_replicates": len(legs["water"]),
            "protein_replicates": len(legs["protein"]),
        }
    )


def main() -> int:
    args = arguments()
    jobs_dir = resolve_jobs_dir(args.data_dir)
    data_root = jobs_dir.parent
    output = args.output or jobs_dir.parent / "ddg_analysis"
    output.mkdir(parents=True, exist_ok=True)
    exp_q_convention = experimental_edges(args.mapping)
    old, old_exp = read_old_summary(args.compare)
    # The previous summary is also a useful source when a working mapping JSON
    # contains only a subset/test edge.
    # A complete mapping takes precedence. Historical comparison summaries used
    # an oppositely oriented, misleadingly named experimental column.
    exp_q_convention = {**{edge: -value for edge, value in old_exp.items()}, **exp_q_convention}
    replicate_rows: list[dict[str, object]] = []
    job_rows: list[dict[str, object]] = []

    # The MPS wrapper writes FEP1 beside each staged input tree and stores only
    # metadata under jobs/. Prefer that layout when those top-level outputs are
    # present. The older per-job work/ and staged_run.tar.gz layouts remain
    # supported below.
    mps_outputs = mps_qfep_outputs(data_root)
    if mps_outputs:
        grouped: dict[str, dict[str, dict[str, float]]] = {}
        for path in mps_outputs:
            source = str(path)
            match = QFEP_PATH.search(path.as_posix())
            if match is None:
                continue
            system_dir, edge, _temperature, replicate = match.groups()
            value = parse_bar(
                path.read_text(encoding="utf-8", errors="replace"), source
            )
            system = "water" if system_dir == "1.water" else "protein"
            legs = grouped.setdefault(edge, {"water": {}, "protein": {}})
            if replicate in legs[system]:
                raise ValueError(
                    f"Duplicate {system} replicate {replicate} for {edge}"
                )
            legs[system][replicate] = value

        metadata = mps_jobs_by_edge(jobs_dir)
        for edge in sorted(grouped):
            job = metadata.get(edge)
            if job is None:
                exit_code, status, source_job = "missing", "check", "dataset-tree"
            else:
                exit_code, status = job_metadata(job)
                source_job = job.name
            append_edge_rows(
                edge,
                grouped[edge],
                source_job=source_job,
                layout="mps-dataset",
                exit_code=exit_code,
                initial_status=status,
                expected_replicates=args.expected_replicates,
                replicate_rows=replicate_rows,
                job_rows=job_rows,
            )
        analyzed_jobs = len(grouped)
    else:
        jobs = sorted(path for path in jobs_dir.glob("*.both") if path.is_dir())
        if not jobs:
            raise SystemExit(
                f"Found neither dataset-level MPS qfep.out files nor "
                f"*.both job directories under {data_root}"
            )

        for job in jobs:
            exit_code, status = job_metadata(job)
            legs: dict[str, dict[str, float]] = {"water": {}, "protein": {}}
            edge_ids = set()
            layout, outputs = qfep_outputs(job)
            if layout == "missing":
                raise FileNotFoundError(
                    f"{job}: found neither work/ nor staged_run.tar.gz"
                )
            if not outputs:
                raise ValueError(f"No qfep.out files found in {job / layout}")
            for source, text in outputs:
                match = QFEP_PATH.search(source)
                if match is None:
                    continue
                system_dir, edge, _temperature, replicate = match.groups()
                value = parse_bar(text, source)
                system = "water" if system_dir == "1.water" else "protein"
                legs[system][replicate] = value
                edge_ids.add(edge)
            if len(edge_ids) != 1:
                raise ValueError(
                    f"Expected one FEP edge in {job}, found {sorted(edge_ids)}"
                )
            edge = edge_ids.pop()
            append_edge_rows(
                edge,
                legs,
                source_job=job.name,
                layout=layout,
                exit_code=exit_code,
                initial_status=status,
                expected_replicates=args.expected_replicates,
                replicate_rows=replicate_rows,
                job_rows=job_rows,
            )
        analyzed_jobs = len(jobs)

    summary_rows = []
    for edge in sorted({r["fep_id"] for r in replicate_rows}):
        rows = [r for r in replicate_rows if r["fep_id"] == edge]
        values = [float(r["Q_ddG"]) for r in rows]
        avg = statistics.mean(values)
        std = statistics.stdev(values) if len(values) > 1 else 0.0
        experiment = exp_q_convention.get(str(edge))
        previous = old.get(str(edge))
        summary_rows.append({
            "fep_id": edge, "from": rows[0]["from"], "to": rows[0]["to"],
            "Q_ddG_avg": f"{avg:.6f}", "Q_ddG_std": f"{std:.6f}",
            "Q_ddG_sem": f"{std / math.sqrt(len(values)):.6f}", "n_replicates": len(values),
            "exp_ddG_Q_convention": "" if experiment is None else f"{experiment:.6f}",
            "Q_minus_exp": "" if experiment is None else f"{avg - experiment:.6f}",
            "previous_Q_ddG_avg": "" if previous is None else f"{previous:.6f}",
            "new_minus_previous": "" if previous is None else f"{avg - previous:.6f}",
        })

    write_csv(output / "ddg_replicates.csv", replicate_rows,
              ["fep_id", "from", "to", "replicate", "water_dGbar", "protein_dGbar", "Q_ddG", "source_job"])
    write_csv(output / "ddg_summary.csv", summary_rows,
              ["fep_id", "from", "to", "Q_ddG_avg", "Q_ddG_std", "Q_ddG_sem", "n_replicates",
               "exp_ddG_Q_convention", "Q_minus_exp",
               "previous_Q_ddG_avg", "new_minus_previous"])
    write_csv(output / "job_validation.csv", job_rows,
              ["fep_id", "job", "layout", "exit_code", "status", "water_replicates", "protein_replicates"])
    print(
        f"Analyzed {analyzed_jobs} jobs / "
        f"{len(replicate_rows)} paired replicates"
    )
    print(
        f"Edges with paired water/protein results: "
        f"{len(summary_rows)}/{len(job_rows)}"
    )
    print(f"Validation: {sum(r['status'] == 'ok' for r in job_rows)} ok, {sum(r['status'] != 'ok' for r in job_rows)} check")
    print(f"Results: {output / 'ddg_summary.csv'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
