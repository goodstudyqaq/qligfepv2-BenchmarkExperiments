#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BENCHMARK_ROOT=$(cd -- "$ROOT/.." && pwd)

usage() {
    printf 'Usage:\n' >&2
    printf '  %s DATA_DIR TARGET\n' "$(basename -- "$0")" >&2
    printf '  %s TARGET_important_TIMESTAMP.tar.zst [TARGET]\n' \
        "$(basename -- "$0")" >&2
    printf '\nExamples:\n' >&2
    printf '  %s /path/to/new_data_in_hb cdk2\n' "$(basename -- "$0")" >&2
    printf '  %s cdk2_important_20260730_140949.tar.zst\n' \
        "$(basename -- "$0")" >&2
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
    usage
    exit 2
fi

INPUT=$1
TARGET=${2:-}

if [[ -f "$INPUT" && "$INPUT" == *.tar.zst ]]; then
    for command_name in tar unzstd; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            printf 'Missing required command for .tar.zst input: %s\n' \
                "$command_name" >&2
            exit 1
        fi
    done

    ARCHIVE_DIR=$(cd -- "$(dirname -- "$INPUT")" && pwd)
    ARCHIVE="$ARCHIVE_DIR/$(basename -- "$INPUT")"
    ARCHIVE_NAME=$(basename -- "$ARCHIVE" .tar.zst)

    if [[ -z "$TARGET" ]]; then
        if [[ "$ARCHIVE_NAME" =~ ^(.+)_important_[0-9]{8}_[0-9]{6}$ ]]; then
            TARGET=${BASH_REMATCH[1]}
        else
            printf 'Cannot infer target from archive name: %s\n' \
                "$(basename -- "$ARCHIVE")" >&2
            printf 'Pass the target explicitly as the second argument.\n' >&2
            exit 2
        fi
    fi

    EXTRACT_DIR="${ARCHIVE%.tar.zst}_extracted"
    EXTRACT_MARKER="$EXTRACT_DIR/.qgpu_archive_extracted"
    if [[ -f "$EXTRACT_MARKER" ]]; then
        printf 'Reusing extracted archive: %s\n' "$EXTRACT_DIR"
        if ! find "$EXTRACT_DIR" -path '*/metrics/*' -type f \
            -print -quit | grep -q .; then
            printf 'Adding metrics missing from the existing extraction cache.\n'
            if ! tar --use-compress-program=unzstd \
                --no-same-owner --no-same-permissions \
                --wildcards --no-anchored \
                -xf "$ARCHIVE" -C "$EXTRACT_DIR" '*metrics/*'; then
                printf 'Could not add metrics to %s\n' "$EXTRACT_DIR" >&2
                exit 1
            fi
        fi
    elif [[ -e "$EXTRACT_DIR" ]]; then
        printf 'Extraction directory exists but is incomplete: %s\n' \
            "$EXTRACT_DIR" >&2
        printf 'Move it aside or choose a fresh archive copy before retrying.\n' >&2
        exit 1
    else
        printf 'Extracting analysis files from %s\n' "$ARCHIVE"
        printf 'Extracting qfep outputs, job metadata, and resource metrics.\n'
        printf 'Raw .en files remain in the archive and are not extracted.\n'
        mkdir -- "$EXTRACT_DIR"
        if ! tar --use-compress-program=unzstd \
            --no-same-owner --no-same-permissions \
            --wildcards --no-anchored \
            -xf "$ARCHIVE" -C "$EXTRACT_DIR" \
            '1.water/FEP_*/FEP1/*/*/qfep.out' \
            '2.protein/FEP_*/FEP1/*/*/qfep.out' \
            'jobs/*/run_info.tsv' \
            'jobs/*/exit_code.txt' \
            'jobs/*/summary.tsv' \
            '*metrics/*'; then
            printf 'Archive extraction failed; partial data remains in %s\n' \
                "$EXTRACT_DIR" >&2
            exit 1
        fi
        printf '%s\n' "$ARCHIVE" > "$EXTRACT_MARKER"
        printf 'Extracted data: %s\n' "$EXTRACT_DIR"
    fi
    NEW_DATA="$EXTRACT_DIR"
elif [[ -d "$INPUT" ]]; then
    if [[ $# -ne 2 ]]; then
        printf 'A target is required when DATA_DIR is used.\n' >&2
        usage
        exit 2
    fi
    NEW_DATA=$(cd -- "$INPUT" && pwd)
else
    printf 'Input is neither a data directory nor a .tar.zst archive: %s\n' \
        "$INPUT" >&2
    exit 1
fi

if [[ ! -d "$NEW_DATA/jobs" ]]; then
    printf 'Missing jobs directory: %s\n' "$NEW_DATA/jobs" >&2
    exit 1
fi
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

PAIRED_EDGE_COUNT=$(
    python3 - "$ANALYSIS/ddg_summary.csv" <<'PY'
import csv
import sys
from pathlib import Path

with Path(sys.argv[1]).open(newline="") as handle:
    print(sum(1 for _row in csv.DictReader(handle)))
PY
)
if ((PAIRED_EDGE_COUNT < 2)); then
    printf '\nCannot generate correlation figures: only %s edge(s) have paired water/protein results.\n' \
        "$PAIRED_EDGE_COUNT" >&2
    printf 'At least two paired edges are required for Pearson correlation.\n' >&2
    printf 'Inspect failed or incomplete jobs in:\n  %s\n' \
        "$ANALYSIS/job_validation.csv" >&2
    printf 'Resource metrics can still be analyzed with:\n' >&2
    printf '  python3 %q %q\n' "$ROOT/analyze_metrics.py" "$NEW_DATA" >&2
    exit 1
fi

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
