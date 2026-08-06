#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="${QGPU_SCRIPT_DIR:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER="${QGPU_SCRIPT_DIR:-$SCRIPT_DIR}/run_qgpu_mps_local.sh"

JOB_NAME="${JOB_NAME:-}"
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
QGPU_SCRATCH_BASE="${QGPU_SCRATCH_BASE:-/scratch-shared/$QGPU_USER/qgpu_batch}"
QGPU_OUTPUT_BASE="${QGPU_OUTPUT_BASE:-}"
QGPU_CLEAN_EXTENSIONS="${QGPU_CLEAN_EXTENSIONS-dcd,log}"
QGPU_KEEP_ONLY="${QGPU_KEEP_ONLY-}"
QGPU_ARCHIVE_EN="${QGPU_ARCHIVE_EN:-0}"
QGPU_CLEAN_ON_FAILURE="${QGPU_CLEAN_ON_FAILURE:-0}"
LOG_DIR="${LOG_DIR:-}"

ONLY=""
DATASET="${QGPU_DATASET_DIR:-}"
DATASET_DIR=""
LIMIT=0
SYSTEM_FILTER="both"
REPLICATES_OVERRIDE=""
CLEAN_EXTENSIONS_RAW="$QGPU_CLEAN_EXTENSIONS"
CLEAN_EXTENSIONS=()
CLEAN_EXTENSIONS_CSV=""
KEEP_ONLY_RAW="$QGPU_KEEP_ONLY"
KEEP_ONLY=()
KEEP_ONLY_CSV=""
IGNORED_ARRAY_MAX_CONCURRENT=""
SUBMIT_DRY_RUN=0
MPS_STARTED=0
RESULT_DIR=""
RUN_TARGET=""
RESULT_SAVED=0
EDGE_ARCHIVE=""
RUN_ROOTS=()
OUTPUT_ROOTS=()
LOCK_DIRS=()

usage() {
    cat <<'EOF'
Usage:
  ./run_qgpu_mps_slurm.sh --dataset DATASET [options]

Submits one Slurm job per FEP edge. Before submission, the selected inputfiles
are copied from the source dataset to QGPU_SCRATCH_BASE/DATASET. Each job
requests one GPU, starts a private MPS daemon, then runs directly in the staged
scratch FEP directories. Generated FEP1 output is therefore written beside the
staged inputfiles:
  ./run_qgpu_mps_local.sh --only EDGE --system VALUE
For safety, a job refuses to start if that FEP1 directory already exists or
another job has locked the same staged FEP workspace.

Options:
  --dataset VALUE    Source dataset name under perturbations (e.g. cdk2 or
                     hif2a), or its path. Selected inputs are copied to scratch.
  --only VALUE       Submit one FEP edge by name, e.g. FEP_1h1q_1oiu, or one system path.
  --system VALUE     For FEP names, submit protein, water, or both. Default: both.
  --replicates N     Number of concurrent replicas inside each submitted job. Default: runner default.
  --clean-extensions LIST
                     Comma- or space-separated extensions to remove after a
                     successful run. Default: dcd,log. Example: dcd,log,inp
  --keep-only LIST   Keep only the listed extensions or exact filenames under
                     each generated FEP1 directory.
                     Example: en,qfep.out
  --archive-en       Pack each replicate's *.en files into one energies.tar.gz
                     immediately after successful QFEP, then combine all
                     replicate archives into one edge energy archive.
  --no-clean         Keep all generated files.
  --limit N         Submit the first N FEP edges in the default order.
  --dry-run         Print the edge list and sbatch command without submitting.
  -h, --help        Show this help.

Environment:
  QGPU_DATASET_DIR=cdk2               Alternative to --dataset.
  JOB_NAME=qgpu_DATASET               Slurm job name. Defaults to the resolved
                                      dataset name, e.g. qgpu_cdk2.
  QGPU_SCRATCH_BASE=/scratch-shared/$USER/qgpu_batch
                                      Shared base for staged dataset inputs,
                                      Slurm logs, and live results. For example,
                                      cdk2 is staged in $QGPU_SCRATCH_BASE/cdk2.
  QGPU_OUTPUT_BASE=$QGPU_SCRATCH_BASE/DATASET/jobs
                                      Dataset-specific directory for per-job
                                      metrics and metadata. Simulation output
                                      is written below the staged FEP directories.
  QGPU_CLEAN_EXTENSIONS=dcd,log       Extensions removed after a successful run.
                                      Leading dots are optional; use an empty value to disable.
  QGPU_KEEP_ONLY=en,qfep.out          Keep only these files in each generated
                                      FEP1 tree. Exact names contain a dot; other
                                      values are treated as extensions.
  QGPU_ARCHIVE_EN=0                   Set to 1 to create one energies.tar.gz per
                                      replicate, then one *.energies.tar per edge;
                                      verified source files are removed at each layer.
  QGPU_CLEAN_ON_FAILURE=0             Also clean selected extensions after a failed run.
  LOG_DIR=$QGPU_SCRATCH_BASE/DATASET/logs
                                      Dataset-specific Slurm stdout directory.
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

Runner environment such as QDYN, QFEP, CONTINUE_ON_ERROR, and METRIC_INTERVAL
is passed through. This wrapper forces CLEAN_AFTER=0 and performs the selected
extension cleanup itself. $TMPDIR is used only for private NVIDIA MPS files.
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

normalize_keep_only() {
    local value
    local normalized="${KEEP_ONLY_RAW//,/ }"
    local values=()

    KEEP_ONLY=()
    read -r -a values <<< "$normalized"
    for value in "${values[@]}"; do
        value="${value#.}"
        [[ -n "$value" ]] || continue
        [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || \
            die "Invalid keep-only value: $value"
        if [[ " ${KEEP_ONLY[*]} " != *" $value "* ]]; then
            KEEP_ONLY+=("$value")
        fi
    done

    if ((${#KEEP_ONLY[@]})); then
        KEEP_ONLY_CSV="$(IFS=,; printf '%s' "${KEEP_ONLY[*]}")"
    else
        KEEP_ONLY_CSV=""
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
                KEEP_ONLY_RAW=""
                shift 2
                ;;
            --keep-only)
                [[ $# -ge 2 ]] || die "--keep-only requires a comma- or space-separated list"
                KEEP_ONLY_RAW="$2"
                shift 2
                ;;
            --archive-en)
                QGPU_ARCHIVE_EN=1
                shift
                ;;
            --no-clean)
                CLEAN_EXTENSIONS_RAW=""
                KEEP_ONLY_RAW=""
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
    [[ "$QGPU_ARCHIVE_EN" == "0" || "$QGPU_ARCHIVE_EN" == "1" ]] || \
        die "QGPU_ARCHIVE_EN must be 0 or 1"
    normalize_clean_extensions
    normalize_keep_only
}

resolve_dataset() {
    [[ -n "$DATASET" ]] || die "--dataset is required (for example: --dataset cdk2)"

    if [[ "$DATASET" == */* ]]; then
        [[ -d "$DATASET" ]] || die "Dataset path does not exist: $DATASET"
        DATASET_DIR="$(cd "$DATASET" && pwd)"
    elif [[ -d "$SCRIPT_DIR/$DATASET" ]]; then
        DATASET_DIR="$(cd "$SCRIPT_DIR/$DATASET" && pwd)"
    elif [[ -d "$REPO_ROOT/$DATASET" ]]; then
        DATASET_DIR="$(cd "$REPO_ROOT/$DATASET" && pwd)"
    elif [[ -d "$QGPU_SCRATCH_BASE/$DATASET" ]]; then
        DATASET_DIR="$(cd "$QGPU_SCRATCH_BASE/$DATASET" && pwd)"
    else
        die "Dataset is neither an existing path nor a directory under perturbations or QGPU_SCRATCH_BASE: $DATASET"
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

configure_dataset_storage() {
    local dataset_name
    dataset_name="$(basename "$DATASET_DIR")"
    QGPU_OUTPUT_BASE="${QGPU_OUTPUT_BASE:-$QGPU_SCRATCH_BASE/$dataset_name/jobs}"
    LOG_DIR="${LOG_DIR:-$QGPU_SCRATCH_BASE/$dataset_name/logs}"
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
    if [[ -n "$KEEP_ONLY_CSV" ]]; then
        printf '%s\0' "--keep-only" "$KEEP_ONLY_CSV"
    fi
    if [[ "$QGPU_ARCHIVE_EN" == "1" ]]; then
        printf '%s\0' "--archive-en"
    fi
}

stage_submission_inputs() {
    local targets_name="$1"
    local -n targets_ref="$targets_name"
    local source_dataset="$DATASET_DIR"
    local dataset_name scratch_dataset target system_dir fep_name i
    local system_dirs=()

    dataset_name="$(basename "$source_dataset")"
    scratch_dataset="$QGPU_SCRATCH_BASE/$dataset_name"

    if [[ "$source_dataset" == "$scratch_dataset" ]]; then
        log "Dataset inputs already reside in scratch: $scratch_dataset"
        stage_dataset_runner "$scratch_dataset"
        return 0
    fi

    log "Staging selected inputs: $source_dataset -> $scratch_dataset"
    for i in "${!targets_ref[@]}"; do
        target="${targets_ref[$i]}"
        if [[ "$target" == FEP_* ]]; then
            mapfile -t system_dirs < <(system_dirs_for_filter)
            for system_dir in "${system_dirs[@]}"; do
                if ((SUBMIT_DRY_RUN)); then
                    printf 'Would copy %s/inputfiles -> %s/%s/%s/inputfiles\n' \
                        "$source_dataset/$system_dir/$target" \
                        "$scratch_dataset" "$system_dir" "$target"
                else
                    stage_system_path \
                        "$source_dataset/$system_dir/$target" \
                        "$scratch_dataset" >/dev/null
                fi
            done
        else
            system_dir="$(basename "$(dirname "$target")")"
            fep_name="$(basename "$target")"
            if ((SUBMIT_DRY_RUN)); then
                printf 'Would copy %s/inputfiles -> %s/%s/%s/inputfiles\n' \
                    "$target" "$scratch_dataset" "$system_dir" "$fep_name"
            else
                stage_system_path "$target" "$scratch_dataset" >/dev/null
            fi
            targets_ref[$i]="$scratch_dataset/$system_dir/$fep_name"
        fi
    done

    stage_dataset_runner "$scratch_dataset"
    DATASET_DIR="$scratch_dataset"
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
    stage_submission_inputs targets
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

require_mps_tmpdir() {
    [[ -n "${TMPDIR:-}" ]] || die "TMPDIR is not set; a private NVIDIA MPS directory is required"
    [[ -d "$TMPDIR" ]] || die "TMPDIR does not exist: $TMPDIR"
    [[ -w "$TMPDIR" ]] || die "TMPDIR is not writable: $TMPDIR"
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

stage_dataset_runner() {
    local stage_root="$1"
    local runner_dst runner_tmp archiver_src archiver_dst archiver_tmp

    # The local runner resolves 1.water and 2.protein relative to its own
    # location, so install it and its energy archiver at the dataset root.
    runner_dst="$stage_root/$(basename "$RUNNER")"
    archiver_src="$SCRIPT_DIR/archive_en_replicates.sh"
    archiver_dst="$stage_root/$(basename "$archiver_src")"
    [[ -x "$archiver_src" ]] || die "Energy archiver is missing or not executable: $archiver_src"
    if ((SUBMIT_DRY_RUN)); then
        printf 'Would install runner %s -> %s\n' "$RUNNER" "$runner_dst"
        printf 'Would install archiver %s -> %s\n' "$archiver_src" "$archiver_dst"
        return 0
    fi

    mkdir -p "$stage_root"
    runner_tmp="$runner_dst.tmp.${BASHPID:-$$}"
    cp -p "$RUNNER" "$runner_tmp"
    chmod +x "$runner_tmp"
    mv -f -- "$runner_tmp" "$runner_dst"

    archiver_tmp="$archiver_dst.tmp.${BASHPID:-$$}"
    cp -p "$archiver_src" "$archiver_tmp"
    chmod +x "$archiver_tmp"
    mv -f -- "$archiver_tmp" "$archiver_dst"
}

resolve_run_roots() {
    local target="$1"
    local system_dir root

    RUN_ROOTS=()
    OUTPUT_ROOTS=()
    if [[ "$target" == FEP_* ]]; then
        while IFS= read -r system_dir; do
            root="$(cd "$DATASET_DIR/$system_dir/$target" && pwd)"
            RUN_ROOTS+=("$root")
            OUTPUT_ROOTS+=("$root/FEP1")
        done < <(system_dirs_for_filter)
    else
        root="$(cd "$target" && pwd)"
        RUN_ROOTS+=("$root")
        OUTPUT_ROOTS+=("$root/FEP1")
    fi
}

release_run_locks() {
    local lock_dir

    for lock_dir in "${LOCK_DIRS[@]}"; do
        if ! rmdir -- "$lock_dir" 2>/dev/null && [[ -d "$lock_dir" ]]; then
            log "WARNING: could not remove job lock directory: $lock_dir"
        fi
    done
    LOCK_DIRS=()
}

acquire_run_locks() {
    local root lock_dir

    LOCK_DIRS=()
    for root in "${RUN_ROOTS[@]}"; do
        if [[ -e "$root/FEP1" ]]; then
            release_run_locks
            die "Output directory already exists; refusing to reuse it: $root/FEP1"
        fi

        lock_dir="$root/.qgpu_mps_slurm.lock"
        if ! mkdir -- "$lock_dir"; then
            release_run_locks
            die "Another job may already own this FEP workspace: $root"
        fi
        LOCK_DIRS+=("$lock_dir")

        if [[ -e "$root/FEP1" ]]; then
            release_run_locks
            die "Output directory appeared while reserving the workspace: $root/FEP1"
        fi
    done
}

write_run_info() {
    local rc="$1"
    local run_roots_csv output_roots_csv

    run_roots_csv="$(IFS=,; printf '%s' "${RUN_ROOTS[*]}")"
    output_roots_csv="$(IFS=,; printf '%s' "${OUTPUT_ROOTS[*]}")"

    {
        printf 'key\tvalue\n'
        printf 'slurm_job_id\t%s\n' "${SLURM_JOB_ID:-unset}"
        printf 'slurm_job_nodelist\t%s\n' "${SLURM_JOB_NODELIST:-unset}"
        printf 'target\t%s\n' "$RUN_TARGET"
        printf 'dataset_dir\t%s\n' "$DATASET_DIR"
        printf 'input_roots\t%s\n' "$run_roots_csv"
        printf 'output_roots\t%s\n' "$output_roots_csv"
        printf 'system_filter\t%s\n' "$SYSTEM_FILTER"
        printf 'replicates_override\t%s\n' "${REPLICATES_OVERRIDE:-runner_default}"
        printf 'script_dir\t%s\n' "$SCRIPT_DIR"
        printf 'metrics_dir\t%s\n' "$METRICS_DIR"
        printf 'result_dir\t%s\n' "$RESULT_DIR"
        printf 'clean_extensions\t%s\n' "${CLEAN_EXTENSIONS_CSV:-none}"
        printf 'keep_only\t%s\n' "${KEEP_ONLY_CSV:-none}"
        printf 'archive_en\t%s\n' "$QGPU_ARCHIVE_EN"
        printf 'edge_energy_archive\t%s\n' "${EDGE_ARCHIVE:-none}"
        printf 'clean_on_failure\t%s\n' "$QGPU_CLEAN_ON_FAILURE"
        printf 'exit_code\t%s\n' "$rc"
    } > "$RESULT_DIR/run_info.tsv"
}

clean_selected_outputs() {
    local rc="$1"
    local ext count file base rule keep output_root
    local clean_roots=()

    if [[ "$rc" -ne 0 && "$QGPU_CLEAN_ON_FAILURE" != "1" ]]; then
        log "Keeping all files because the run failed with exit code $rc"
        return 0
    fi
    for output_root in "${OUTPUT_ROOTS[@]}"; do
        [[ -d "$output_root" ]] && clean_roots+=("$output_root")
    done
    if ((${#clean_roots[@]} == 0)); then
        log "No generated FEP1 directories found to clean"
        return 0
    fi
    if ((${#KEEP_ONLY[@]})); then
        count=0
        while IFS= read -r -d '' file; do
            base="$(basename "$file")"
            keep=0
            if [[ "$QGPU_ARCHIVE_EN" == "1" && "$base" == "energies.tar.gz" ]]; then
                keep=1
            fi
            for rule in "${KEEP_ONLY[@]}"; do
                if [[ "$rule" == *.* ]]; then
                    [[ "$base" == "$rule" ]] && keep=1
                else
                    [[ "$base" == "$rule" || "$base" == *".$rule" ]] && keep=1
                fi
                ((keep)) && break
            done
            if (( ! keep )); then
                rm -f -- "$file"
                count=$((count + 1))
            fi
        done < <(find "${clean_roots[@]}" -type f -print0)
        log "Removed $count non-matching file(s) from generated FEP1 output; kept ${KEEP_ONLY_CSV}"
        return 0
    fi
    if ((${#CLEAN_EXTENSIONS[@]} == 0)); then
        log "Extension cleanup disabled; keeping all files"
        return 0
    fi

    for ext in "${CLEAN_EXTENSIONS[@]}"; do
        if ! count="$(
            find "${clean_roots[@]}" -type f -name "*.$ext" -printf '.\n' -delete |
                wc -l
        )"; then
            log "WARNING: failed while removing *.$ext files from generated FEP1 output"
            return 1
        fi
        count="${count//[[:space:]]/}"
        log "Removed ${count:-0} *.$ext file(s) from generated FEP1 output"
    done
}

archive_energy_outputs() {
    local rc="$1"
    local archiver="$SCRIPT_DIR/archive_en_replicates.sh"
    local archive_roots=()
    local output_root edge_tag edge_archive

    [[ "$QGPU_ARCHIVE_EN" == "1" ]] || return 0
    if [[ "$rc" -ne 0 ]]; then
        log "Keeping individual energy files/archives because the edge failed with exit code $rc"
        return 0
    fi
    for output_root in "${OUTPUT_ROOTS[@]}"; do
        [[ -d "$output_root" ]] && archive_roots+=("$output_root")
    done
    ((${#archive_roots[@]})) || {
        log "ERROR: no generated FEP1 directories found to archive"
        return 1
    }
    [[ -x "$archiver" ]] || {
        log "ERROR: energy archiver is missing or not executable: $archiver"
        return 1
    }

    # Normally the local runner already created these immediately after each
    # successful QFEP. This pass also handles an older staged runner safely.
    "$archiver" "${archive_roots[@]}"

    edge_tag="$(target_tag "$RUN_TARGET")"
    edge_archive="$DATASET_DIR/energy_archives/$edge_tag.energies.tar"
    "$archiver" --edge "$edge_archive" "$DATASET_DIR" "${archive_roots[@]}"
    EDGE_ARCHIVE="$edge_archive"
    log "Created edge energy archive: $EDGE_ARCHIVE"
}

save_results() {
    local rc="$1"

    [[ "$RESULT_SAVED" == "0" ]] || return 0
    [[ -n "$RESULT_DIR" ]] || return 0

    mkdir -p "$RESULT_DIR"
    printf '%s\n' "$rc" > "$RESULT_DIR/exit_code.txt"
    write_run_info "$rc"

    if [[ -f "$METRICS_DIR/qgpu_mps_summary.tsv" ]]; then
        cp -p "$METRICS_DIR/qgpu_mps_summary.tsv" "$RESULT_DIR/summary.tsv"
    fi
    if [[ -f "$METRICS_DIR/current_status.tsv" ]]; then
        cp -p "$METRICS_DIR/current_status.tsv" "$RESULT_DIR/current_status.tsv"
    fi

    RESULT_SAVED=1
    log "Finalized results in $RESULT_DIR"
}

cleanup_mps_tmpdir() {
    local mps_dir

    [[ -n "${TMPDIR:-}" ]] || return 0

    for mps_dir in "${CUDA_MPS_PIPE_DIRECTORY:-}" "${CUDA_MPS_LOG_DIRECTORY:-}"; do
        [[ -n "$mps_dir" ]] || continue
        case "$mps_dir" in
            "$TMPDIR"/nvidia-mps-pipe|"$TMPDIR"/nvidia-mps-log)
                if ! rm -rf -- "$mps_dir"; then
                    log "WARNING: could not remove MPS directory: $mps_dir"
                    return 1
                fi
                ;;
            *)
                log "Keeping externally configured MPS directory: $mps_dir"
                ;;
        esac
    done

    if [[ -n "${SLURM_JOB_ID:-}" && "$(basename "$TMPDIR")" == "$QGPU_USER.$SLURM_JOB_ID" ]]; then
        if rmdir -- "$TMPDIR" 2>/dev/null; then
            log "Removed empty job TMPDIR: $TMPDIR"
        elif [[ -d "$TMPDIR" ]]; then
            log "Job TMPDIR contains files not created by NVIDIA MPS: $TMPDIR"
        fi
    fi
}

cleanup() {
    local rc=$?
    trap - EXIT INT TERM

    if [[ -n "$RESULT_DIR" && "$RESULT_SAVED" == "0" ]]; then
        if ! save_results "$rc"; then
            log "WARNING: failed to finalize results in $RESULT_DIR"
        fi
    fi

    if ((MPS_STARTED)); then
        echo quit | nvidia-cuda-mps-control >/dev/null 2>&1 || true
        MPS_STARTED=0
    fi

    if ! cleanup_mps_tmpdir; then
        log "WARNING: failed to clean NVIDIA MPS data from ${TMPDIR:-unset}"
    fi

    release_run_locks
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
    local target tag rc dataset_runner root
    local runner_args=()

    [[ -n "$ONLY" ]] || die "This Slurm job must be submitted with --only TARGET"
    [[ -x "$RUNNER" ]] || die "Runner is not executable: $RUNNER"

    target="$(resolve_one_target)"
    validate_target "$target"
    require_mps_tmpdir

    RUN_TARGET="$target"
    resolve_run_roots "$target"
    tag="$(target_tag "$target")"
    RESULT_DIR="$QGPU_OUTPUT_BASE/${SLURM_JOB_ID}_${tag}"
    export METRICS_DIR="$RESULT_DIR/metrics"
    dataset_runner="$DATASET_DIR/$(basename "$RUNNER")"

    mkdir -p "$RESULT_DIR" "$METRICS_DIR"

    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    [[ -x "$dataset_runner" ]] || die "Staged dataset runner is not executable: $dataset_runner"
    acquire_run_locks

    log "SLURM_JOB_ID=$SLURM_JOB_ID"
    log "SLURM_ARRAY_TASK_ID=${SLURM_ARRAY_TASK_ID:-unset}"
    log "SLURM_JOB_NODELIST=${SLURM_JOB_NODELIST:-unset}"
    log "SLURM_JOB_GPUS=${SLURM_JOB_GPUS:-unset}"
    log "SLURM_STEP_GPUS=${SLURM_STEP_GPUS:-unset}"
    log "SLURM_GPUS_ON_NODE=${SLURM_GPUS_ON_NODE:-unset}"
    log "Target=$target"
    for root in "${RUN_ROOTS[@]}"; do
        log "Scratch FEP workspace=$root"
    done
    log "Result dir=$RESULT_DIR"
    log "METRICS_DIR=$METRICS_DIR"
    log "Cleanup extensions=${CLEAN_EXTENSIONS_CSV:-none}"

    ensure_single_visible_gpu
    log "CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES"
    start_mps

    runner_args=(--only "$target" --system "$SYSTEM_FILTER")
    if [[ -n "$REPLICATES_OVERRIDE" ]]; then
        runner_args+=(--replicates "$REPLICATES_OVERRIDE")
    fi

    # Keep all runner output until the wrapper applies the selected extension
    # policy. This guarantees that .en files are not removed by legacy cleanup.
    export CLEAN_AFTER=0
    export QGPU_EN_ARCHIVER="$DATASET_DIR/archive_en_replicates.sh"

    set +e
    "$dataset_runner" "${runner_args[@]}"
    rc=$?
    set -e

    if ! archive_energy_outputs "$rc"; then
        log "WARNING: failed to create per-replicate energy archives"
        if [[ "$rc" -eq 0 ]]; then
            rc=1
        fi
    fi

    if ! clean_selected_outputs "$rc"; then
        log "WARNING: failed to clean selected extensions in generated FEP1 output"
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
    configure_dataset_storage

    if [[ -z "${SLURM_JOB_ID:-}" ]]; then
        submit_jobs "$@"
    else
        run_job_task
    fi
}

main "$@"
