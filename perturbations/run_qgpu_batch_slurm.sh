#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="${QGPU_SCRIPT_DIR:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER="${QGPU_SCRIPT_DIR:-$SCRIPT_DIR}/run_qgpu_batch_local.sh"

JOB_NAME="${JOB_NAME:-}"
SBATCH_TIME="${SBATCH_TIME:-12:00:00}"
SBATCH_CPUS_PER_TASK="${SBATCH_CPUS_PER_TASK:-8}"
SBATCH_MEM="${SBATCH_MEM:-48G}"
SBATCH_GPUS_PER_NODE="${SBATCH_GPUS_PER_NODE:-v100:1}"
SBATCH_GRES="${SBATCH_GRES:-}"
SBATCH_PARTITION="${SBATCH_PARTITION:-}"
SBATCH_ACCOUNT="${SBATCH_ACCOUNT:-}"
SBATCH_QOS="${SBATCH_QOS:-}"
SBATCH_CONSTRAINT="${SBATCH_CONSTRAINT:-}"
SBATCH_GPU_BIND="${SBATCH_GPU_BIND:-}"
QGPU_USER="${USER:-${LOGNAME:-user}}"
QGPU_SCRATCH_BASE="${QGPU_SCRATCH_BASE:-/scratch-shared/$QGPU_USER/qgpu_batch}"
QGPU_OUTPUT_BASE="${QGPU_OUTPUT_BASE:-$QGPU_SCRATCH_BASE/jobs}"
QGPU_CLEAN_EXTENSIONS="${QGPU_CLEAN_EXTENSIONS-dcd,log}"
QGPU_CLEAN_ON_FAILURE="${QGPU_CLEAN_ON_FAILURE:-0}"
LOG_DIR="${LOG_DIR:-$QGPU_SCRATCH_BASE/logs}"

ONLY=""
DATASET="${QGPU_DATASET_DIR:-}"
DATASET_DIR=""
LIMIT=0
SYSTEM_FILTER="both"
REPLICATES_OVERRIDE=""
CLEAN_EXTENSIONS_RAW="$QGPU_CLEAN_EXTENSIONS"
CLEAN_EXTENSIONS=()
CLEAN_EXTENSIONS_CSV=""
IGNORED_ARRAY_MAX_CONCURRENT=""
SUBMIT_DRY_RUN=0
STAGE_ROOT=""
RESULT_DIR=""
METRICS_DIR=""
RUN_TARGET=""
STAGED_TARGET=""
RESULT_SAVED=0
ACTIVE_RUNNERS=()

usage() {
    cat <<'EOF'
Usage:
  ./run_qgpu_batch_slurm.sh --dataset DATASET [options]

Submits one Slurm job per FEP edge. Each job requests one GPU, copies the
selected inputfiles into QGPU_OUTPUT_BASE, then runs directly in that shared
result directory. Protein and water run sequentially without CUDA MPS; each
qdyn process batches all replicas for one system and simulation stage:
  ./run_qgpu_batch_local.sh --dataset DATASET --only EDGE --system VALUE

Options:
  --dataset VALUE    Dataset name under QGPU_SCRATCH_BASE (e.g. cdk2 or hif2a), or its path.
  --only VALUE       Submit one FEP edge by name, e.g. FEP_1h1q_1oiu, or one system path.
  --system VALUE     Run protein, water, or both. "both" runs them sequentially. Default: both.
  --replicates N     Number of replicas batched into each qdyn process. Default: runner default.
  --clean-extensions LIST
                     Comma- or space-separated extensions to remove after a
                     successful run. Default: dcd,log. Example: dcd,log,inp
  --no-clean         Keep all generated and copied files.
  --limit N         Submit the first N FEP edges in the default order.
  --dry-run         Print the edge list and sbatch command without submitting.
  -h, --help        Show this help.

Environment:
  QGPU_DATASET_DIR=cdk2               Alternative to --dataset.
  JOB_NAME=qgpu_DATASET               Slurm job name. Defaults to the resolved
                                      dataset name, e.g. qgpu_cdk2.
  QGPU_SCRATCH_BASE=/scratch-shared/$USER/qgpu_batch
                                      Shared base containing dataset directories,
                                      Slurm logs, and live results. For example,
                                      cdk2 is read from $QGPU_SCRATCH_BASE/cdk2.
  QGPU_OUTPUT_BASE=$QGPU_SCRATCH_BASE/jobs
                                      Shared directory where jobs read inputs and write outputs.
  QGPU_CLEAN_EXTENSIONS=dcd,log       Extensions removed after a successful run.
                                      Leading dots are optional; use an empty value to disable.
  QGPU_CLEAN_ON_FAILURE=0             Also clean selected extensions after a failed run.
  LOG_DIR=$QGPU_SCRATCH_BASE/logs     Directory for Slurm stdout logs.
  SBATCH_TIME=12:00:00                Slurm wall time.
  SBATCH_CPUS_PER_TASK=8              CPUs allocated to each edge task.
  SBATCH_MEM=48G                      Memory allocated to each edge task.
  SBATCH_GPUS_PER_NODE=v100:1         GPU request, used as --gpus-per-node unless SBATCH_GRES is set.
  SBATCH_GRES=gpu:v100:1              Optional --gres value for clusters that require GRES.
  SBATCH_PARTITION=gpu                Optional Slurm partition.
  SBATCH_ACCOUNT=...                  Optional Slurm account.
  SBATCH_QOS=...                      Optional Slurm QoS.
  SBATCH_CONSTRAINT=...               Optional Slurm constraint.
  SBATCH_GPU_BIND=single:1            Optional Slurm --gpu-bind value.
  QGPU_ALLOW_UNBOUND_GPU=1            Allow fallback to GPU 0 when Slurm exposes no GPU binding.

Runner environment such as QDYN, QFEP, CONTINUE_ON_ERROR, and METRIC_INTERVAL
is passed through. This wrapper forces CLEAN_AFTER=0 and performs the selected
extension cleanup itself.
EOF
}

log() {
    printf '[%s] %s\n' "$(date -Iseconds)" "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

normalize_clean_extensions() {
    local ext
    local normalized="${CLEAN_EXTENSIONS_RAW//,/ }"
    local values=()

    CLEAN_EXTENSIONS=()
    read -r -a values <<< "$normalized"
    for ext in "${values[@]}"; do
        ext="${ext#.}"
        [[ -n "$ext" ]] || continue
        [[ "$ext" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || \
            die "Invalid cleanup extension: $ext"
        if [[ " ${CLEAN_EXTENSIONS[*]} " != *" $ext "* ]]; then
            CLEAN_EXTENSIONS+=("$ext")
        fi
    done

    if ((${#CLEAN_EXTENSIONS[@]})); then
        CLEAN_EXTENSIONS_CSV="$(IFS=,; printf '%s' "${CLEAN_EXTENSIONS[*]}")"
    else
        CLEAN_EXTENSIONS_CSV=""
    fi
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
            --clean-extensions|--clean)
                [[ $# -ge 2 ]] || die "$1 requires a comma- or space-separated list"
                CLEAN_EXTENSIONS_RAW="$2"
                shift 2
                ;;
            --no-clean)
                CLEAN_EXTENSIONS_RAW=""
                shift
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
    [[ "$QGPU_CLEAN_ON_FAILURE" == "0" || "$QGPU_CLEAN_ON_FAILURE" == "1" ]] || \
        die "QGPU_CLEAN_ON_FAILURE must be 0 or 1"
    normalize_clean_extensions
}

resolve_dataset() {
    [[ -n "$DATASET" ]] || die "--dataset is required (for example: --dataset cdk2)"

    if [[ "$DATASET" == */* ]]; then
        [[ -d "$DATASET" ]] || die "Dataset path does not exist: $DATASET"
        DATASET_DIR="$(cd "$DATASET" && pwd)"
    elif [[ -d "$QGPU_SCRATCH_BASE/$DATASET" ]]; then
        DATASET_DIR="$(cd "$QGPU_SCRATCH_BASE/$DATASET" && pwd)"
    else
        die "Dataset not found under QGPU_SCRATCH_BASE: $QGPU_SCRATCH_BASE/$DATASET"
    fi

    [[ -d "$DATASET_DIR/2.protein" || -d "$DATASET_DIR/1.water" ]] || \
        die "Dataset has neither 2.protein nor 1.water: $DATASET_DIR"
}

safe_tag() {
    printf '%s' "$1" | sed 's#[^A-Za-z0-9_.-]#_#g'
}

configure_job_name() {
    if [[ -z "$JOB_NAME" ]]; then
        JOB_NAME="qgpu_$(safe_tag "$(basename "$DATASET_DIR")")"
    fi
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
    local dataset_tag parent
    dataset_tag="$(basename "$DATASET_DIR")"

    if [[ "$target" == FEP_* ]]; then
        safe_tag "$dataset_tag.$target.$SYSTEM_FILTER"
    else
        parent="$(basename "$(dirname "$target")")"
        safe_tag "$dataset_tag.$parent.$(basename "$target")"
    fi
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

    mapfile -t system_dirs < <(system_dirs_for_filter)

    if [[ "$target" == FEP_* ]]; then
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
        local discovery_dir
        if [[ "$SYSTEM_FILTER" == "water" ]]; then
            discovery_dir="$DATASET_DIR/1.water"
        else
            discovery_dir="$DATASET_DIR/2.protein"
        fi
        [[ -d "$discovery_dir" ]] || die "Missing discovery directory: $discovery_dir"
        while IFS= read -r target; do
            targets+=("$target")
        done < <(find "$discovery_dir" -maxdepth 1 -type d -name 'FEP_*' -printf '%f\n' | sort)
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
    if [[ -n "$CLEAN_EXTENSIONS_CSV" ]]; then
        printf '%s\0' "--clean-extensions" "$CLEAN_EXTENSIONS_CSV"
    else
        printf '%s\0' "--no-clean"
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

    if [[ "$target" == FEP_* ]]; then
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
        printf 'work_dir\t%s\n' "$STAGE_ROOT"
        printf 'metrics_dir\t%s\n' "$METRICS_DIR"
        printf 'result_dir\t%s\n' "$RESULT_DIR"
        printf 'clean_extensions\t%s\n' "${CLEAN_EXTENSIONS_CSV:-none}"
        printf 'clean_on_failure\t%s\n' "$QGPU_CLEAN_ON_FAILURE"
        printf 'exit_code\t%s\n' "$rc"
    } > "$RESULT_DIR/run_info.tsv"
}

clean_selected_outputs() {
    local rc="$1"
    local ext count

    if [[ "$rc" -ne 0 && "$QGPU_CLEAN_ON_FAILURE" != "1" ]]; then
        log "Keeping all files because the run failed with exit code $rc"
        return 0
    fi
    if ((${#CLEAN_EXTENSIONS[@]} == 0)); then
        log "Extension cleanup disabled; keeping all files"
        return 0
    fi

    for ext in "${CLEAN_EXTENSIONS[@]}"; do
        if ! count="$(
            find "$RESULT_DIR" -type f -name "*.$ext" -printf '.\n' -delete |
                wc -l
        )"; then
            log "WARNING: failed while removing *.$ext files from $RESULT_DIR"
            return 1
        fi
        count="${count//[[:space:]]/}"
        log "Removed ${count:-0} *.$ext file(s) from $RESULT_DIR"
    done
}

save_results() {
    local rc="$1"

    [[ "$RESULT_SAVED" == "0" ]] || return 0
    [[ -n "$STAGE_ROOT" && -d "$STAGE_ROOT" && -n "$RESULT_DIR" ]] || return 0

    mkdir -p "$RESULT_DIR"
    printf '%s\n' "$rc" > "$RESULT_DIR/exit_code.txt"
    write_run_info "$rc"

    if [[ -f "$METRICS_DIR/qgpu_batch_summary.tsv" ]]; then
        cp -p "$METRICS_DIR/qgpu_batch_summary.tsv" "$RESULT_DIR/summary.tsv"
    fi
    if [[ -f "$METRICS_DIR/current_batch_status.tsv" ]]; then
        cp -p "$METRICS_DIR/current_batch_status.tsv" "$RESULT_DIR/current_status.tsv"
    fi

    RESULT_SAVED=1
    log "Finalized results in $RESULT_DIR"
}

cleanup() {
    local rc=$?
    trap - EXIT INT TERM

    if ((${#ACTIVE_RUNNERS[@]})); then
        kill "${ACTIVE_RUNNERS[@]}" 2>/dev/null || true
        wait "${ACTIVE_RUNNERS[@]}" 2>/dev/null || true
        ACTIVE_RUNNERS=()
    fi

    if [[ -n "$STAGE_ROOT" && -d "$STAGE_ROOT" && -n "$RESULT_DIR" && "$RESULT_SAVED" == "0" ]]; then
        if ! save_results "$rc"; then
            log "WARNING: failed to finalize results in $RESULT_DIR"
        fi
    fi

    exit "$rc"
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
            die "CUDA_VISIBLE_DEVICES is unset and Slurm did not provide SLURM_STEP_GPUS/SLURM_JOB_GPUS; refusing to default the job to GPU 0. Check the GPU sbatch option or set QGPU_ALLOW_UNBOUND_GPU=1 for a controlled single-GPU test."
        fi
    fi

    [[ "$CUDA_VISIBLE_DEVICES" != *,* ]] || die "Expected exactly one visible GPU per job, got CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES"
}

run_staged_system() {
    local staged_runner="$1"
    local system="$2"
    local args=(--dataset "$STAGE_ROOT" --only "$STAGED_TARGET" --system "$system")

    if [[ -n "$REPLICATES_OVERRIDE" ]]; then
        args+=(--replicates "$REPLICATES_OVERRIDE")
    fi

    log "Starting $system runner: METRICS_DIR=$METRICS_DIR"
    METRICS_DIR="$METRICS_DIR" "$staged_runner" "${args[@]}"
}

run_job_task() {
    local target tag rc=0 staged_runner system child_rc child_pid
    local systems=()

    [[ -n "$ONLY" ]] || die "This Slurm job must be submitted with --only TARGET"
    [[ -x "$RUNNER" ]] || die "Runner is not executable: $RUNNER"

    target="$(resolve_one_target)"
    validate_target "$target"

    RUN_TARGET="$target"
    tag="$(target_tag "$target")"
    RESULT_DIR="$QGPU_OUTPUT_BASE/${SLURM_JOB_ID}_${tag}"
    STAGE_ROOT="$RESULT_DIR/work"
    METRICS_DIR="$RESULT_DIR/metrics"

    mkdir -p "$RESULT_DIR"
    [[ ! -e "$STAGE_ROOT" ]] || die "Work directory already exists; refusing to overwrite it: $STAGE_ROOT"
    STAGED_TARGET="$(stage_target "$target" "$STAGE_ROOT")"
    staged_runner="$STAGE_ROOT/$(basename "$RUNNER")"
    mkdir -p "$METRICS_DIR"

    log "SLURM_JOB_ID=$SLURM_JOB_ID"
    log "SLURM_ARRAY_TASK_ID=${SLURM_ARRAY_TASK_ID:-unset}"
    log "SLURM_JOB_NODELIST=${SLURM_JOB_NODELIST:-unset}"
    log "SLURM_JOB_GPUS=${SLURM_JOB_GPUS:-unset}"
    log "SLURM_STEP_GPUS=${SLURM_STEP_GPUS:-unset}"
    log "SLURM_GPUS_ON_NODE=${SLURM_GPUS_ON_NODE:-unset}"
    log "Target=$target"
    log "Shared work dir=$STAGE_ROOT"
    log "Staged target=$STAGED_TARGET"
    log "Result dir=$RESULT_DIR"
    log "METRICS_DIR=$METRICS_DIR"
    log "Cleanup extensions=${CLEAN_EXTENSIONS_CSV:-none}"

    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    ensure_single_visible_gpu
    log "CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES"

    # Keep all runner output until the wrapper applies the selected extension
    # policy. This guarantees that .en files are not removed by legacy cleanup.
    export CLEAN_AFTER=0

    case "$SYSTEM_FILTER" in
        protein) systems=(protein) ;;
        water) systems=(water) ;;
        both)
            [[ "$STAGED_TARGET" == FEP_* ]] || die "Protein/water mode requires --only to be an FEP name, not a single-system path"
            systems=(protein water)
            ;;
        *) die "Unsupported system filter: $SYSTEM_FILTER" ;;
    esac

    for system in "${systems[@]}"; do
        run_staged_system "$staged_runner" "$system" &
        child_pid="$!"
        ACTIVE_RUNNERS=("$child_pid")
        log "Launched $system runner pid=$child_pid"

        set +e
        wait "$child_pid"
        child_rc=$?
        set -e
        ACTIVE_RUNNERS=()
        log "Finished $system runner pid=$child_pid exit_code=$child_rc"
        if [[ "$child_rc" -ne 0 ]]; then
            rc=1
            if [[ "${CONTINUE_ON_ERROR:-0}" != "1" ]]; then
                log "Skipping remaining systems because $system failed"
                break
            fi
        fi
    done

    if ! clean_selected_outputs "$rc"; then
        log "WARNING: failed to clean selected extensions in $RESULT_DIR"
        if [[ "$rc" -eq 0 ]]; then
            rc=1
        fi
    fi

    if ! save_results "$rc"; then
        log "WARNING: failed to finalize results in $RESULT_DIR"
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
    configure_job_name

    if [[ -z "${SLURM_JOB_ID:-}" ]]; then
        submit_jobs "$@"
    else
        run_job_task
    fi
}

main "$@"
