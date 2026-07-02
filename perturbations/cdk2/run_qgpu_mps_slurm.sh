#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="${QGPU_SCRIPT_DIR:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="${QGPU_SCRIPT_DIR:-$SCRIPT_DIR}/run_qgpu_mps_local.sh"

JOB_NAME="${JOB_NAME:-cdk2-qgpu}"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"
SBATCH_TIME="${SBATCH_TIME:-12:00:00}"
SBATCH_CPUS_PER_TASK="${SBATCH_CPUS_PER_TASK:-8}"
SBATCH_MEM="${SBATCH_MEM:-48G}"
SBATCH_GPUS_PER_NODE="${SBATCH_GPUS_PER_NODE:-v100:1}"
SBATCH_GRES="${SBATCH_GRES:-}"
SBATCH_PARTITION="${SBATCH_PARTITION:-}"
SBATCH_ACCOUNT="${SBATCH_ACCOUNT:-}"
SBATCH_QOS="${SBATCH_QOS:-}"
SBATCH_CONSTRAINT="${SBATCH_CONSTRAINT:-}"
SBATCH_ARRAY_MAX_CONCURRENT="${SBATCH_ARRAY_MAX_CONCURRENT:-1}"
SBATCH_GPU_BIND="${SBATCH_GPU_BIND:-}"

ONLY=""
LIMIT=0
SYSTEM_FILTER="both"
REPLICATES_OVERRIDE=""
SUBMIT_DRY_RUN=0
MPS_STARTED=0

usage() {
    cat <<'EOF'
Usage:
  ./run_qgpu_mps_slurm.sh [options]

Submits one Slurm array task per FEP edge. Each task requests one GPU,
starts a private MPS daemon inside the Slurm allocation, then runs:
  ./run_qgpu_mps_local.sh --only EDGE --system VALUE

Options:
  --only VALUE       Submit one FEP edge by name, e.g. FEP_1h1q_1oiu, or one system path.
  --system VALUE     For FEP names, submit protein, water, or both. Default: both.
  --replicates N     Number of concurrent replicas inside each array task. Default: runner default.
  --array-max-concurrent N
                     Max concurrent Slurm array tasks. Default: 1.
  --limit N         Submit the first N FEP edges in the default order.
  --dry-run         Print the edge list and sbatch command without submitting.
  -h, --help        Show this help.

Environment:
  JOB_NAME=cdk2-qgpu                  Slurm job name.
  LOG_DIR=./logs                      Directory for Slurm stdout logs and edge list.
  SBATCH_TIME=12:00:00                Slurm wall time.
  SBATCH_CPUS_PER_TASK=8              CPUs allocated to each edge task.
  SBATCH_MEM=48G                      Memory allocated to each edge task.
  SBATCH_GPUS_PER_NODE=v100:1         GPU request, used as --gpus-per-node unless SBATCH_GRES is set.
  SBATCH_GRES=gpu:v100:1              Optional --gres value for clusters that require GRES.
  SBATCH_PARTITION=gpu                Optional Slurm partition.
  SBATCH_ACCOUNT=...                  Optional Slurm account.
  SBATCH_QOS=...                      Optional Slurm QoS.
  SBATCH_CONSTRAINT=...               Optional Slurm constraint.
  SBATCH_ARRAY_MAX_CONCURRENT=1       Slurm array throttle. Raise to the number of GPUs to use.
  SBATCH_GPU_BIND=single:1            Optional Slurm --gpu-bind value.
  QGPU_METRICS_BASE=./metrics/slurm   Base directory for per-task metrics.
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
                SBATCH_ARRAY_MAX_CONCURRENT="$2"
                [[ "$SBATCH_ARRAY_MAX_CONCURRENT" =~ ^[1-9][0-9]*$ ]] || die "--array-max-concurrent must be a positive integer"
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
}

safe_tag() {
    printf '%s' "$1" | sed 's#[^A-Za-z0-9_.-]#_#g'
}

resolve_one_target() {
    if [[ -d "$ONLY" ]]; then
        cd "$ONLY" && pwd
    elif [[ -d "$REPO_ROOT/$ONLY" ]]; then
        cd "$REPO_ROOT/$ONLY" && pwd
    elif [[ "$ONLY" == FEP_* ]]; then
        printf '%s\n' "$ONLY"
    else
        die "--only value is neither an existing path nor an FEP name: $ONLY"
    fi
}

validate_target() {
    local target="$1"
    local system_dir
    local system_dirs=()

    case "$SYSTEM_FILTER" in
        protein) system_dirs=(2.protein) ;;
        water) system_dirs=(1.water) ;;
        both) system_dirs=(2.protein 1.water) ;;
        *) die "--system must be protein, water, or both" ;;
    esac

    if [[ "$target" == FEP_* ]]; then
        for system_dir in "${system_dirs[@]}"; do
            [[ -d "$SCRIPT_DIR/$system_dir/$target/inputfiles" ]] || die "Missing system path: $SCRIPT_DIR/$system_dir/$target"
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
        done < <(find "$SCRIPT_DIR/2.protein" -maxdepth 1 -type d -name 'FEP_*' -printf '%f\n' | sort)
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

write_target_list() {
    local target_list
    mkdir -p "$LOG_DIR"
    target_list="$(mktemp "$LOG_DIR/qgpu_targets.XXXXXX.txt")"
    printf '%s\n' "$@" > "$target_list"
    printf '%s\n' "$target_list"
}

print_command() {
    printf '%q ' "$@"
    printf '\n'
}

submit_array() {
    local targets=()
    local target_list array_spec
    local sbatch_args=()

    if (( ! SUBMIT_DRY_RUN )); then
        command -v sbatch >/dev/null || die "sbatch is required"
    fi
    [[ -x "$RUNNER" ]] || die "Runner is not executable: $RUNNER"

    mapfile -t targets < <(resolve_targets)
    target_list="$(write_target_list "${targets[@]}")"

    array_spec="1-${#targets[@]}"
    if [[ -n "$SBATCH_ARRAY_MAX_CONCURRENT" ]]; then
        [[ "$SBATCH_ARRAY_MAX_CONCURRENT" =~ ^[1-9][0-9]*$ ]] || die "SBATCH_ARRAY_MAX_CONCURRENT must be a positive integer"
        array_spec="$array_spec%$SBATCH_ARRAY_MAX_CONCURRENT"
    fi

    sbatch_args=(
        "--job-name=$JOB_NAME"
        "--nodes=1"
        "--ntasks=1"
        "--cpus-per-task=$SBATCH_CPUS_PER_TASK"
        "--mem=$SBATCH_MEM"
        "--time=$SBATCH_TIME"
        "--chdir=$SCRIPT_DIR"
        "--array=$array_spec"
        "--output=$LOG_DIR/%x.%A_%a.log"
        "--export=ALL,QGPU_TARGET_LIST=$target_list,QGPU_SCRIPT_DIR=$SCRIPT_DIR"
    )

    [[ -n "$SBATCH_PARTITION" ]] && sbatch_args+=("--partition=$SBATCH_PARTITION")
    [[ -n "$SBATCH_ACCOUNT" ]] && sbatch_args+=("--account=$SBATCH_ACCOUNT")
    [[ -n "$SBATCH_QOS" ]] && sbatch_args+=("--qos=$SBATCH_QOS")
    [[ -n "$SBATCH_CONSTRAINT" ]] && sbatch_args+=("--constraint=$SBATCH_CONSTRAINT")
    [[ -n "$SBATCH_GPU_BIND" ]] && sbatch_args+=("--gpu-bind=$SBATCH_GPU_BIND")

    if [[ -n "$SBATCH_GRES" ]]; then
        sbatch_args+=("--gres=$SBATCH_GRES")
    else
        sbatch_args+=("--gpus-per-node=$SBATCH_GPUS_PER_NODE")
    fi

    printf 'Resolved %d target(s):\n' "${#targets[@]}"
    printf '  %s\n' "${targets[@]}"
    printf 'Target list: %s\n' "$target_list"

    if ((SUBMIT_DRY_RUN)); then
        printf 'sbatch command:\n  '
        print_command sbatch "${sbatch_args[@]}" "$SCRIPT_PATH" "$@"
        return 0
    fi

    exec sbatch "${sbatch_args[@]}" "$SCRIPT_PATH" "$@"
}

cleanup() {
    local rc=$?
    trap - EXIT INT TERM

    if ((MPS_STARTED)); then
        echo quit | nvidia-cuda-mps-control >/dev/null 2>&1 || true
    fi

    exit "$rc"
}

start_mps() {
    command -v nvidia-cuda-mps-control >/dev/null || die "nvidia-cuda-mps-control is required"

    export CUDA_MPS_PIPE_DIRECTORY="${CUDA_MPS_PIPE_DIRECTORY:-/tmp/nvidia-mps-${USER:-user}-${SLURM_JOB_ID}-${SLURM_ARRAY_TASK_ID}}"
    export CUDA_MPS_LOG_DIRECTORY="${CUDA_MPS_LOG_DIRECTORY:-/tmp/nvidia-mps-log-${USER:-user}-${SLURM_JOB_ID}-${SLURM_ARRAY_TASK_ID}}"
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

run_array_task() {
    local target tag array_job_id metrics_base rc
    local runner_args=()

    [[ -n "${SLURM_ARRAY_TASK_ID:-}" ]] || die "SLURM_ARRAY_TASK_ID is required; submit this script as an array job"
    [[ -n "${QGPU_TARGET_LIST:-}" ]] || die "QGPU_TARGET_LIST is required"
    [[ -f "$QGPU_TARGET_LIST" ]] || die "Target list does not exist: $QGPU_TARGET_LIST"
    [[ -x "$RUNNER" ]] || die "Runner is not executable: $RUNNER"

    target="$(sed -n "${SLURM_ARRAY_TASK_ID}p" "$QGPU_TARGET_LIST")"
    [[ -n "$target" ]] || die "No target found for SLURM_ARRAY_TASK_ID=$SLURM_ARRAY_TASK_ID"
    validate_target "$target"

    tag="$(safe_tag "$target")"
    array_job_id="${SLURM_ARRAY_JOB_ID:-$SLURM_JOB_ID}"
    metrics_base="${QGPU_METRICS_BASE:-$SCRIPT_DIR/metrics/slurm}"
    export METRICS_DIR="$metrics_base/${array_job_id}_${SLURM_ARRAY_TASK_ID}_${tag}"
    mkdir -p "$METRICS_DIR"

    log "SLURM_JOB_ID=$SLURM_JOB_ID"
    log "SLURM_ARRAY_TASK_ID=$SLURM_ARRAY_TASK_ID"
    log "SLURM_JOB_NODELIST=${SLURM_JOB_NODELIST:-unset}"
    log "SLURM_JOB_GPUS=${SLURM_JOB_GPUS:-unset}"
    log "SLURM_STEP_GPUS=${SLURM_STEP_GPUS:-unset}"
    log "SLURM_GPUS_ON_NODE=${SLURM_GPUS_ON_NODE:-unset}"
    log "Target=$target"
    log "METRICS_DIR=$METRICS_DIR"

    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    ensure_single_visible_gpu
    log "CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES"
    start_mps

    runner_args=(--only "$target" --system "$SYSTEM_FILTER")
    if [[ -n "$REPLICATES_OVERRIDE" ]]; then
        runner_args+=(--replicates "$REPLICATES_OVERRIDE")
    fi

    set +e
    "$RUNNER" "${runner_args[@]}"
    rc=$?
    set -e

    log "Finished target=$target exit_code=$rc"
    exit "$rc"
}

main() {
    parse_args "$@"

    if [[ -z "${SLURM_JOB_ID:-}" ]]; then
        submit_array "$@"
    else
        run_array_task
    fi
}

main "$@"
