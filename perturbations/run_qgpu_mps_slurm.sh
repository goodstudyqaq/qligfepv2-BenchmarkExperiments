#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="${QGPU_SCRIPT_DIR:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER="${QGPU_SCRIPT_DIR:-$SCRIPT_DIR}/run_qgpu_mps_local.sh"

JOB_NAME="${JOB_NAME:-qgpu-mps}"
SBATCH_TIME="${SBATCH_TIME:-12:00:00}"
SBATCH_CPUS_PER_TASK="${SBATCH_CPUS_PER_TASK:-18}"
SBATCH_MEM="${SBATCH_MEM:-120G}"
SBATCH_GPUS_PER_NODE="${SBATCH_GPUS_PER_NODE:-1}"
SBATCH_GRES="${SBATCH_GRES:-}"
SBATCH_PARTITION="${SBATCH_PARTITION:-gpu_a100}"
SBATCH_ACCOUNT="${SBATCH_ACCOUNT:-}"
SBATCH_QOS="${SBATCH_QOS:-}"
SBATCH_CONSTRAINT="${SBATCH_CONSTRAINT:-}"
SBATCH_GPU_BIND="${SBATCH_GPU_BIND:-}"
QGPU_USER="${USER:-${LOGNAME:-user}}"
QGPU_SCRATCH_BASE="${QGPU_SCRATCH_BASE:-/scratch-shared/$QGPU_USER/qgpu_mps}"
QGPU_OUTPUT_BASE="${QGPU_OUTPUT_BASE:-$QGPU_SCRATCH_BASE/jobs}"
QGPU_METRICS_BASE="${QGPU_METRICS_BASE:-$QGPU_SCRATCH_BASE/metrics}"
QGPU_COPY_METRICS="${QGPU_COPY_METRICS:-1}"
LOG_DIR="${LOG_DIR:-$QGPU_SCRATCH_BASE/logs}"

ONLY=""
DATASET="${QGPU_DATASET_DIR:-}"
DATASET_DIR=""
LIMIT=0
SYSTEM_FILTER="both"
REPLICATES_OVERRIDE=""
IGNORED_ARRAY_MAX_CONCURRENT=""
SUBMIT_DRY_RUN=0
MPS_STARTED=0
STAGE_ROOT=""
RESULT_DIR=""
SHARED_METRICS_DIR=""
RUN_TARGET=""
STAGED_TARGET=""
RESULT_SAVED=0

usage() {
    cat <<'EOF'
Usage:
  ./run_qgpu_mps_slurm.sh --dataset DATASET [options]

Submits one Slurm job per FEP edge. Each job requests one GPU, stages the
selected inputfiles into $TMPDIR, starts a private MPS daemon, then runs:
  ./run_qgpu_mps_local.sh --only EDGE --system VALUE

Options:
  --dataset VALUE    Dataset name under perturbations (e.g. cdk2 or hif2a), or its path.
  --only VALUE       Submit one FEP edge by name, e.g. FEP_1h1q_1oiu, or one system path.
  --system VALUE     For FEP names, submit protein, water, or both. Default: both.
  --replicates N     Number of concurrent replicas inside each submitted job. Default: runner default.
  --limit N         Submit the first N FEP edges in the default order.
  --dry-run         Print the edge list and sbatch command without submitting.
  -h, --help        Show this help.

Environment:
  JOB_NAME=qgpu-mps                   Slurm job name.
  QGPU_DATASET_DIR=cdk2               Alternative to --dataset.
  QGPU_SCRATCH_BASE=/scratch-shared/$USER/qgpu_mps
                                      Shared base for Slurm logs, result archives, and metrics.
  QGPU_OUTPUT_BASE=$QGPU_SCRATCH_BASE/jobs
                                      Shared directory for per-job result archives.
  QGPU_METRICS_BASE=$QGPU_SCRATCH_BASE/metrics
                                      Shared directory for per-job metric copies.
  QGPU_COPY_METRICS=1                 Copy local $TMPDIR metrics to QGPU_METRICS_BASE after the run.
  LOG_DIR=$QGPU_SCRATCH_BASE/logs     Directory for Slurm stdout logs.
  SBATCH_TIME=12:00:00                Slurm wall time.
  SBATCH_CPUS_PER_TASK=18             CPUs allocated to each A100 edge task.
  SBATCH_MEM=120G                     Memory allocated to each A100 edge task.
  SBATCH_GPUS_PER_NODE=1              GPU request, used as --gpus-per-node unless SBATCH_GRES is set.
  SBATCH_GRES=gpu:1                   Optional --gres value for clusters that require GRES.
  SBATCH_PARTITION=gpu_a100           Slurm GPU partition.
  SBATCH_ACCOUNT=...                  Optional Slurm account.
  SBATCH_QOS=...                      Optional Slurm QoS.
  SBATCH_CONSTRAINT=...               Optional Slurm constraint.
  SBATCH_GPU_BIND=single:1            Optional Slurm --gpu-bind value.
  MPS_ACTIVE_THREAD_PERCENTAGE=10     Optional per-client MPS SM percentage cap.
  QGPU_ALLOW_UNBOUND_GPU=1            Allow fallback to GPU 0 when Slurm exposes no GPU binding.

Runner environment such as QDYN, QFEP, CLEAN_AFTER, KEEP_QFEP_ONLY,
CONTINUE_ON_ERROR, and METRIC_INTERVAL is passed through to the local runner.
EOF
}

log() {
    printf '[%s] %s\n' "$(date -Iseconds)" "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

parse_args() {
    while (($#)); do
        case "$1" in
            --dataset)
                [[ $# -ge 2 ]] || die "--dataset requires a value"
                DATASET="$2"
                shift 2
                ;;
            --only)
                [[ $# -ge 2 ]] || die "--only requires a value"
                ONLY="$2"
                shift 2
                ;;
            --system)
                [[ $# -ge 2 ]] || die "--system requires protein, water, or both"
                SYSTEM_FILTER="$2"
                [[ "$SYSTEM_FILTER" == "protein" || "$SYSTEM_FILTER" == "water" || "$SYSTEM_FILTER" == "both" ]] || die "--system must be protein, water, or both"
                shift 2
                ;;
            --replicates)
                [[ $# -ge 2 ]] || die "--replicates requires a value"
                REPLICATES_OVERRIDE="$2"
                [[ "$REPLICATES_OVERRIDE" =~ ^[1-9][0-9]*$ ]] || die "--replicates must be a positive integer"
                shift 2
                ;;
            --array-max-concurrent)
                [[ $# -ge 2 ]] || die "--array-max-concurrent requires a value"
                IGNORED_ARRAY_MAX_CONCURRENT="$2"
                [[ "$IGNORED_ARRAY_MAX_CONCURRENT" =~ ^[1-9][0-9]*$ ]] || die "--array-max-concurrent must be a positive integer"
                shift 2
                ;;
            --limit)
                [[ $# -ge 2 ]] || die "--limit requires a value"
                LIMIT="$2"
                [[ "$LIMIT" =~ ^[0-9]+$ ]] || die "--limit must be a non-negative integer"
                shift 2
                ;;
            --dry-run)
                SUBMIT_DRY_RUN=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown argument: $1"
                ;;
        esac
    done
    [[ "$QGPU_COPY_METRICS" == "0" || "$QGPU_COPY_METRICS" == "1" ]] || die "QGPU_COPY_METRICS must be 0 or 1"
}

resolve_dataset() {
    [[ -n "$DATASET" ]] || die "--dataset is required (for example: --dataset cdk2)"

    if [[ -d "$DATASET" ]]; then
        DATASET_DIR="$(cd "$DATASET" && pwd)"
    elif [[ -d "$SCRIPT_DIR/$DATASET" ]]; then
        DATASET_DIR="$(cd "$SCRIPT_DIR/$DATASET" && pwd)"
    elif [[ -d "$REPO_ROOT/$DATASET" ]]; then
        DATASET_DIR="$(cd "$REPO_ROOT/$DATASET" && pwd)"
    else
        die "Dataset is neither an existing path nor a directory under perturbations: $DATASET"
    fi

    [[ -d "$DATASET_DIR/2.protein" || -d "$DATASET_DIR/1.water" ]] || \
        die "Dataset has neither 2.protein nor 1.water: $DATASET_DIR"
}

safe_tag() {
    printf '%s' "$1" | sed 's#[^A-Za-z0-9_.-]#_#g'
}

system_dirs_for_filter() {
    case "$SYSTEM_FILTER" in
        protein) printf '%s\n' 2.protein ;;
        water) printf '%s\n' 1.water ;;
        both) printf '%s\n' 2.protein 1.water ;;
        *) die "--system must be protein, water, or both" ;;
    esac
}

target_tag() {
    local target="$1"
    local parent

    if [[ "$target" != */* ]]; then
        safe_tag "$target.$SYSTEM_FILTER"
    else
        parent="$(basename "$(dirname "$target")")"
        safe_tag "$parent.$(basename "$target")"
    fi
}

resolve_one_target() {
    if [[ -d "$ONLY" ]]; then
        cd "$ONLY" && pwd
    elif [[ -d "$REPO_ROOT/$ONLY" ]]; then
        cd "$REPO_ROOT/$ONLY" && pwd
    elif [[ "$ONLY" != */* ]]; then
        printf '%s\n' "$ONLY"
    else
        die "--only value is neither an existing path nor an FEP name: $ONLY"
    fi
}

validate_target() {
    local target="$1"
    local system_dir
    local system_dirs=()

    mapfile -t system_dirs < <(system_dirs_for_filter)

    if [[ "$target" != */* ]]; then
        for system_dir in "${system_dirs[@]}"; do
            [[ -d "$DATASET_DIR/$system_dir/$target/inputfiles" ]] || die "Missing system path: $DATASET_DIR/$system_dir/$target"
        done
    else
        [[ -d "$target/inputfiles" ]] || die "Missing inputfiles directory for target path: $target"
    fi
}

resolve_targets() {
    local targets=()
    local target

    if [[ -n "$ONLY" ]]; then
        target="$(resolve_one_target)"
        targets+=("$target")
    else
        while IFS= read -r target; do
            targets+=("$target")
        [[ -d "$DATASET_DIR/2.protein" ]] || die "Default edge discovery requires $DATASET_DIR/2.protein"
        done < <(find "$DATASET_DIR/2.protein" -mindepth 2 -maxdepth 2 -type d -name inputfiles -printf '%h\n' | sed 's#.*/##' | sort)
    fi

    if ((LIMIT > 0 && LIMIT < ${#targets[@]})); then
        targets=("${targets[@]:0:LIMIT}")
    fi

    ((${#targets[@]})) || die "No FEP targets resolved"
    for target in "${targets[@]}"; do
        validate_target "$target"
    done

    printf '%s\n' "${targets[@]}"
}

print_command() {
    printf '%q ' "$@"
    printf '\n'
}

build_sbatch_args() {
    local target="$1"
    local tag
    tag="$(target_tag "$target")"

    printf '%s\0' \
        "--job-name=$JOB_NAME" \
        "--nodes=1" \
        "--ntasks=1" \
        "--cpus-per-task=$SBATCH_CPUS_PER_TASK" \
        "--mem=$SBATCH_MEM" \
        "--time=$SBATCH_TIME" \
        "--chdir=$SCRIPT_DIR" \
        "--output=$LOG_DIR/%x.%j.$tag.log" \
        "--export=ALL,QGPU_SCRIPT_DIR=$SCRIPT_DIR"

    [[ -n "$SBATCH_PARTITION" ]] && printf '%s\0' "--partition=$SBATCH_PARTITION"
    [[ -n "$SBATCH_ACCOUNT" ]] && printf '%s\0' "--account=$SBATCH_ACCOUNT"
    [[ -n "$SBATCH_QOS" ]] && printf '%s\0' "--qos=$SBATCH_QOS"
    [[ -n "$SBATCH_CONSTRAINT" ]] && printf '%s\0' "--constraint=$SBATCH_CONSTRAINT"
    [[ -n "$SBATCH_GPU_BIND" ]] && printf '%s\0' "--gpu-bind=$SBATCH_GPU_BIND"

    if [[ -n "$SBATCH_GRES" ]]; then
        printf '%s\0' "--gres=$SBATCH_GRES"
    else
        printf '%s\0' "--gpus-per-node=$SBATCH_GPUS_PER_NODE"
    fi
}

build_child_args() {
    local target="$1"

    printf '%s\0' "$SCRIPT_PATH" "--dataset" "$DATASET_DIR" "--only" "$target" "--system" "$SYSTEM_FILTER"
    if [[ -n "$REPLICATES_OVERRIDE" ]]; then
        printf '%s\0' "--replicates" "$REPLICATES_OVERRIDE"
    fi
}

submit_jobs() {
    local targets=()
    local target
    local sbatch_args=()
    local child_args=()

    if (( ! SUBMIT_DRY_RUN )); then
        command -v sbatch >/dev/null || die "sbatch is required"
    fi
    [[ -x "$RUNNER" ]] || die "Runner is not executable: $RUNNER"

    mapfile -t targets < <(resolve_targets)
    mkdir -p "$LOG_DIR"

    printf 'Resolved %d target(s):\n' "${#targets[@]}"
    printf '  %s\n' "${targets[@]}"
    if [[ -n "$IGNORED_ARRAY_MAX_CONCURRENT" ]]; then
        printf 'Note: --array-max-concurrent is ignored because this script now submits independent jobs, not a Slurm array.\n'
    fi

    for target in "${targets[@]}"; do
        sbatch_args=()
        child_args=()
        mapfile -d '' -t sbatch_args < <(build_sbatch_args "$target")
        mapfile -d '' -t child_args < <(build_child_args "$target")

        if ((SUBMIT_DRY_RUN)); then
            printf 'sbatch command for %s:\n  ' "$target"
            print_command sbatch "${sbatch_args[@]}" "${child_args[@]}"
        else
            sbatch "${sbatch_args[@]}" "${child_args[@]}"
        fi
    done
}

require_job_tmpdir() {
    [[ -n "${TMPDIR:-}" ]] || die "TMPDIR is not set; this runner must stage jobs onto node-local Slurm storage"
    [[ -d "$TMPDIR" ]] || die "TMPDIR does not exist: $TMPDIR"
    [[ -w "$TMPDIR" ]] || die "TMPDIR is not writable: $TMPDIR"
    command -v tar >/dev/null || die "tar is required"
}

stage_system_path() {
    local src="$1"
    local stage_root="$2"
    local fep_name system_dir dst

    src="$(cd "$src" && pwd)"
    fep_name="$(basename "$src")"
    system_dir="$(basename "$(dirname "$src")")"
    [[ "$system_dir" == "2.protein" || "$system_dir" == "1.water" ]] || die "Cannot infer system from path: $src"
    [[ -d "$src/inputfiles" ]] || die "Missing inputfiles directory for target path: $src"

    dst="$stage_root/$system_dir/$fep_name"
    mkdir -p "$dst"
    cp -a "$src/inputfiles" "$dst/"
    printf '%s\n' "$dst"
}

stage_target() {
    local target="$1"
    local stage_root="$2"
    local system_dir

    mkdir -p "$stage_root"
    cp -p "$RUNNER" "$stage_root/"
    chmod +x "$stage_root/$(basename "$RUNNER")"

    if [[ "$target" != */* ]]; then
        while IFS= read -r system_dir; do
            stage_system_path "$DATASET_DIR/$system_dir/$target" "$stage_root" >/dev/null
        done < <(system_dirs_for_filter)
        printf '%s\n' "$target"
    else
        stage_system_path "$target" "$stage_root"
    fi
}

write_run_info() {
    local rc="$1"

    {
        printf 'key\tvalue\n'
        printf 'slurm_job_id\t%s\n' "${SLURM_JOB_ID:-unset}"
        printf 'slurm_job_nodelist\t%s\n' "${SLURM_JOB_NODELIST:-unset}"
        printf 'target\t%s\n' "$RUN_TARGET"
        printf 'dataset_dir\t%s\n' "$DATASET_DIR"
        printf 'staged_target\t%s\n' "$STAGED_TARGET"
        printf 'system_filter\t%s\n' "$SYSTEM_FILTER"
        printf 'replicates_override\t%s\n' "${REPLICATES_OVERRIDE:-runner_default}"
        printf 'script_dir\t%s\n' "$SCRIPT_DIR"
        printf 'stage_root\t%s\n' "$STAGE_ROOT"
        printf 'metrics_dir\t%s\n' "$STAGE_ROOT/metrics"
        printf 'result_dir\t%s\n' "$RESULT_DIR"
        printf 'shared_metrics_dir\t%s\n' "${SHARED_METRICS_DIR:-disabled}"
        printf 'exit_code\t%s\n' "$rc"
    } > "$RESULT_DIR/run_info.tsv"
}

copy_metrics_to_shared() {
    [[ "$QGPU_COPY_METRICS" == "1" ]] || return 0
    [[ -d "$STAGE_ROOT/metrics" ]] || return 0

    mkdir -p "$SHARED_METRICS_DIR"
    cp -a "$STAGE_ROOT/metrics/." "$SHARED_METRICS_DIR/"
}

save_results() {
    local rc="$1"
    local archive_path archive_tmp

    [[ "$RESULT_SAVED" == "0" ]] || return 0
    [[ -n "$STAGE_ROOT" && -d "$STAGE_ROOT" && -n "$RESULT_DIR" ]] || return 0

    mkdir -p "$RESULT_DIR"
    printf '%s\n' "$rc" > "$RESULT_DIR/exit_code.txt"
    write_run_info "$rc"

    if [[ -f "$STAGE_ROOT/metrics/qgpu_mps_summary.tsv" ]]; then
        cp -p "$STAGE_ROOT/metrics/qgpu_mps_summary.tsv" "$RESULT_DIR/summary.tsv"
    fi
    if [[ -f "$STAGE_ROOT/metrics/current_status.tsv" ]]; then
        cp -p "$STAGE_ROOT/metrics/current_status.tsv" "$RESULT_DIR/current_status.tsv"
    fi
    copy_metrics_to_shared

    archive_path="$RESULT_DIR/staged_run.tar.gz"
    archive_tmp="$archive_path.tmp.$$"
    tar -czf "$archive_tmp" -C "$STAGE_ROOT" .
    mv "$archive_tmp" "$archive_path"

    RESULT_SAVED=1
    log "Saved staged results to $archive_path"
}

cleanup() {
    local rc=$?
    trap - EXIT INT TERM

    if [[ -n "$STAGE_ROOT" && -d "$STAGE_ROOT" && -n "$RESULT_DIR" && "$RESULT_SAVED" == "0" ]]; then
        if ! save_results "$rc"; then
            log "WARNING: failed to save staged results from $STAGE_ROOT to $RESULT_DIR"
        fi
    fi

    if ((MPS_STARTED)); then
        echo quit | nvidia-cuda-mps-control >/dev/null 2>&1 || true
    fi

    exit "$rc"
}

start_mps() {
    command -v nvidia-cuda-mps-control >/dev/null || die "nvidia-cuda-mps-control is required"

    export CUDA_MPS_PIPE_DIRECTORY="${CUDA_MPS_PIPE_DIRECTORY:-$TMPDIR/nvidia-mps-pipe}"
    export CUDA_MPS_LOG_DIRECTORY="${CUDA_MPS_LOG_DIRECTORY:-$TMPDIR/nvidia-mps-log}"
    mkdir -p "$CUDA_MPS_PIPE_DIRECTORY" "$CUDA_MPS_LOG_DIRECTORY"

    if [[ -n "${MPS_ACTIVE_THREAD_PERCENTAGE:-}" ]]; then
        export CUDA_MPS_ACTIVE_THREAD_PERCENTAGE="$MPS_ACTIVE_THREAD_PERCENTAGE"
        log "MPS active thread percentage per client: $CUDA_MPS_ACTIVE_THREAD_PERCENTAGE"
    fi

    log "Starting MPS on CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-unset}"
    nvidia-cuda-mps-control -d
    MPS_STARTED=1
    sleep 1
}

ensure_single_visible_gpu() {
    local slurm_gpu_list

    if [[ -z "${CUDA_VISIBLE_DEVICES:-}" ]]; then
        slurm_gpu_list="${SLURM_STEP_GPUS:-${SLURM_JOB_GPUS:-}}"
        if [[ -n "$slurm_gpu_list" ]]; then
            export CUDA_VISIBLE_DEVICES="${slurm_gpu_list%%,*}"
            log "CUDA_VISIBLE_DEVICES was unset; using Slurm GPU allocation: $CUDA_VISIBLE_DEVICES"
        elif [[ "${QGPU_ALLOW_UNBOUND_GPU:-0}" == "1" ]]; then
            export CUDA_VISIBLE_DEVICES="${GPU_ID:-0}"
            log "WARNING: CUDA_VISIBLE_DEVICES is unset; QGPU_ALLOW_UNBOUND_GPU=1, using GPU $CUDA_VISIBLE_DEVICES"
        else
            die "CUDA_VISIBLE_DEVICES is unset and Slurm did not provide SLURM_STEP_GPUS/SLURM_JOB_GPUS; refusing to default all array tasks to GPU 0. Check the GPU sbatch option or set QGPU_ALLOW_UNBOUND_GPU=1 for a controlled single-GPU test."
        fi
    fi

    [[ "$CUDA_VISIBLE_DEVICES" != *,* ]] || die "Expected exactly one visible GPU per array task, got CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES"
}

run_job_task() {
    local target tag rc staged_runner
    local runner_args=()

    [[ -n "$ONLY" ]] || die "This Slurm job must be submitted with --only TARGET"
    [[ -x "$RUNNER" ]] || die "Runner is not executable: $RUNNER"

    target="$(resolve_one_target)"
    validate_target "$target"
    require_job_tmpdir

    RUN_TARGET="$target"
    tag="$(target_tag "$target")"
    STAGE_ROOT="$(mktemp -d "$TMPDIR/qgpu_${SLURM_JOB_ID}_${tag}.XXXXXX")"
    RESULT_DIR="$QGPU_OUTPUT_BASE/${SLURM_JOB_ID}_${tag}"
    SHARED_METRICS_DIR="$QGPU_METRICS_BASE/${SLURM_JOB_ID}_${tag}"
    STAGED_TARGET="$(stage_target "$target" "$STAGE_ROOT")"
    staged_runner="$STAGE_ROOT/$(basename "$RUNNER")"
    export METRICS_DIR="$STAGE_ROOT/metrics"
    mkdir -p "$METRICS_DIR"

    log "SLURM_JOB_ID=$SLURM_JOB_ID"
    log "SLURM_ARRAY_TASK_ID=${SLURM_ARRAY_TASK_ID:-unset}"
    log "SLURM_JOB_NODELIST=${SLURM_JOB_NODELIST:-unset}"
    log "SLURM_JOB_GPUS=${SLURM_JOB_GPUS:-unset}"
    log "SLURM_STEP_GPUS=${SLURM_STEP_GPUS:-unset}"
    log "SLURM_GPUS_ON_NODE=${SLURM_GPUS_ON_NODE:-unset}"
    log "Target=$target"
    log "Stage root=$STAGE_ROOT"
    log "Staged target=$STAGED_TARGET"
    log "Result dir=$RESULT_DIR"
    log "METRICS_DIR=$METRICS_DIR"

    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    ensure_single_visible_gpu
    log "CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES"
    start_mps

    runner_args=(--only "$STAGED_TARGET" --system "$SYSTEM_FILTER")
    if [[ -n "$REPLICATES_OVERRIDE" ]]; then
        runner_args+=(--replicates "$REPLICATES_OVERRIDE")
    fi

    set +e
    "$staged_runner" "${runner_args[@]}"
    rc=$?
    set -e

    if ! save_results "$rc"; then
        log "WARNING: failed to save staged results from $STAGE_ROOT to $RESULT_DIR"
        if [[ "$rc" -eq 0 ]]; then
            rc=1
        fi
    fi

    log "Finished target=$target exit_code=$rc"
    exit "$rc"
}

main() {
    parse_args "$@"
    resolve_dataset

    if [[ -z "${SLURM_JOB_ID:-}" ]]; then
        submit_jobs "$@"
    else
        run_job_task
    fi
}

main "$@"
