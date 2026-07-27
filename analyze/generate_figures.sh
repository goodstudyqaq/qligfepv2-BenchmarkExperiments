#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BENCHMARK_ROOT=$(cd -- "$ROOT/.." && pwd)

if [[ $# -ne 2 ]]; then
    printf 'Usage: %s DATA_DIR TARGET\n' "$(basename -- "$0")" >&2
    printf 'Example: %s /path/to/new_data_in_hb cdk2\n' "$(basename -- "$0")" >&2
    exit 2
fi

if [[ ! -d "$1/jobs" ]]; then
    printf 'Missing jobs directory: %s\n' "$1/jobs" >&2
    exit 1
fi
NEW_DATA=$(cd -- "$1" && pwd)
TARGET=$2
if [[ ! "$TARGET" =~ ^[A-Za-z0-9._-]+$ ]]; then
    printf 'Invalid target name: %s\n' "$TARGET" >&2
    exit 2
fi

ANALYSIS="$NEW_DATA/ddg_analysis"
REFERENCE_ROOT="$BENCHMARK_ROOT/results/$TARGET"
FORTRAN_JSON="$REFERENCE_ROOT/${TARGET}_FEP_results.json"
MAPPING="$REFERENCE_ROOT/mapping_ddG.json"

if [[ ! -f "$FORTRAN_JSON" && -d "$REFERENCE_ROOT" ]]; then
    shopt -s nullglob
    candidates=("$REFERENCE_ROOT"/*_FEP_results.json)
    shopt -u nullglob
    if [[ ${#candidates[@]} -eq 1 ]]; then
        FORTRAN_JSON=${candidates[0]}
    fi
fi

QGPU_FIGURE="$NEW_DATA/${TARGET}_fortran_gpu_ddgbar_comparison.png"
EXPERIMENT_FIGURE="$NEW_DATA/${TARGET}_experiment_correlations_ddgbar.png"
JOINED_FORTRAN="$ANALYSIS/fortran_gpu_correlation_rows.csv"
JOINED_EXPERIMENT="$ANALYSIS/experiment_vs_qgpu_fortran_ddgbar.csv"
EXPERIMENT_STATS="$ANALYSIS/experiment_correlation_stats.csv"

for required in \
    "$ROOT/analyze_staged_jobs.py" \
    "$ROOT/correlate_fortran_gpu.py" \
    "$ROOT/correlate_experiment.py" \
    "$FORTRAN_JSON" \
    "$MAPPING"; do
    if [[ ! -f "$required" ]]; then
        printf 'Missing required file: %s\n' "$required" >&2
        exit 1
    fi
done

printf '1/4 Analyzing QGPU jobs...\n'
python3 "$ROOT/analyze_staged_jobs.py" "$NEW_DATA" \
    --mapping "$MAPPING"

printf '2/4 Plotting QGPU versus Fortran...\n'
python3 "$ROOT/correlate_fortran_gpu.py" \
    --from-json \
    --fortran-json "$FORTRAN_JSON" \
    --gpu-summary "$ANALYSIS/ddg_summary.csv" \
    --figure "$QGPU_FIGURE" \
    --out "$JOINED_FORTRAN"

printf '3/4 Building experiment/QGPU/Fortran table...\n'
python3 - "$ANALYSIS/ddg_summary.csv" "$JOINED_FORTRAN" "$JOINED_EXPERIMENT" <<'PY'
import csv
import sys
from pathlib import Path

summary_path, fortran_path, output_path = map(Path, sys.argv[1:])

with summary_path.open(newline="") as handle:
    summaries = {row["fep_id"]: row for row in csv.DictReader(handle)}
with fortran_path.open(newline="") as handle:
    fortran = {row["fep_id"]: row for row in csv.DictReader(handle)}

common = sorted(set(summaries) & set(fortran))
if not common:
    raise SystemExit("No common FEP IDs between QGPU and Fortran tables")

fields = [
    "fep_id", "from", "to", "exp_ddG", "hpc_ddGbar", "fortran_ddGbar",
    "hpc_minus_exp", "fortran_minus_exp", "hpc_sem", "fortran_sem",
]
rows = []
for fep_id in common:
    q = summaries[fep_id]
    f = fortran[fep_id]
    exp_text = q.get("exp_ddG_Q_convention", "")
    if not exp_text:
        raise SystemExit(f"Missing sign-aligned experimental ddG for {fep_id}")
    exp = float(exp_text)
    qgpu = float(q["Q_ddG_avg"])
    fort = float(f["fortran"])
    rows.append({
        "fep_id": fep_id,
        "from": q["from"],
        "to": q["to"],
        "exp_ddG": f"{exp:.6f}",
        "hpc_ddGbar": f"{qgpu:.6f}",
        "fortran_ddGbar": f"{fort:.6f}",
        "hpc_minus_exp": f"{qgpu - exp:.6f}",
        "fortran_minus_exp": f"{fort - exp:.6f}",
        "hpc_sem": q.get("Q_ddG_sem", ""),
        "fortran_sem": f.get("fortran_sem", ""),
    })

with output_path.open("w", newline="") as handle:
    writer = csv.DictWriter(handle, fieldnames=fields)
    writer.writeheader()
    writer.writerows(rows)
print(f"Wrote {len(rows)} joined edges to {output_path}")
PY

printf '4/4 Plotting QGPU and Fortran versus experiment...\n'
python3 "$ROOT/correlate_experiment.py" \
    --input "$JOINED_EXPERIMENT" \
    --figure "$EXPERIMENT_FIGURE" \
    --stats "$EXPERIMENT_STATS"

printf '\nGenerated figures:\n'
printf '  %s\n' "$QGPU_FIGURE"
printf '  %s\n' "$EXPERIMENT_FIGURE"
