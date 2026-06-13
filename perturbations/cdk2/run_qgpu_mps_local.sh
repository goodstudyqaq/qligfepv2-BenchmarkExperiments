#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CDK2_DIR="$SCRIPT_DIR"

QDYN="${QDYN:-/home/shen/code/Q2/bin/qdyn}"
QFEP="${QFEP:-/home/shen/code/Q2/src/q6/bin/q6/qfep}"
GPU_ID="${GPU_ID:-${CUDA_VISIBLE_DEVICES:-0}}"
GPU_ID="${GPU_ID%%,*}"
export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-$GPU_ID}"

METRIC_INTERVAL="${METRIC_INTERVAL:-5}"
METRICS_DIR="${METRICS_DIR:-$CDK2_DIR/metrics}"
RAW_METRICS_DIR="$METRICS_DIR/raw"
SUMMARY_FILE="$METRICS_DIR/cdk2_qgpu_mps_summary.tsv"
STATUS_FILE="$METRICS_DIR/current_status.tsv"

USE_MPS="${USE_MPS:-1}"
CLEAN_AFTER="${CLEAN_AFTER:-1}"
KEEP_QFEP_ONLY="${KEEP_QFEP_ONLY:-1}"
CONTINUE_ON_ERROR="${CONTINUE_ON_ERROR:-0}"

ONLY=""
LIMIT=0
DRY_RUN=0
GPU_HAS_POWER=1
MPS_STARTED=0
ACTIVE_SAMPLERS=()
ACTIVE_WORKERS=()

exec 3>&1

usage() {
    cat <<'EOF'
Usage:
  ./run_qgpu_mps_local.sh [options]

Options:
  --only VALUE       Run one FEP pair by name, e.g. FEP_1h1q_1oiu, or one system path.
  --limit N         Run the first N FEP pairs in the default order.
  --dry-run         Print execution order without running qdyn.
  --no-mps          Do not start a private MPS daemon.
  -h, --help        Show this help.

Environment:
  QDYN=/path/to/qdyn                  Default: /home/shen/code/Q2/bin/qdyn
  QFEP=/path/to/qfep                  Default: /home/shen/code/Q2/src/q6/bin/q6/qfep
  GPU_ID=0                            GPU passed to nvidia-smi; also used for CUDA_VISIBLE_DEVICES if unset.
  CUDA_VISIBLE_DEVICES=0              GPU visible to qdyn.
  METRIC_INTERVAL=5                   Sampling interval in seconds.
  MPS_ACTIVE_THREAD_PERCENTAGE=10     Optional per-client MPS SM percentage cap.
  CLEAN_AFTER=1                       Clean each replicate run directory after successful qfep.
  KEEP_QFEP_ONLY=1                    With CLEAN_AFTER=1, keep only qfep.out in each replicate run directory.
  CONTINUE_ON_ERROR=0                 Continue to next system after a failed system.
  USE_MPS=1                           Start a private MPS daemon.
EOF
}

log() {
    local line
    line="[$(date -Iseconds)] $*"
    printf '%s\n' "$line"
    if [[ "${DUPLICATE_LOG_TO_MAIN:-0}" == "1" ]]; then
        printf '%s\n' "$line" >&3
    fi
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
            --limit)
                [[ $# -ge 2 ]] || die "--limit requires a value"
                LIMIT="$2"
                [[ "$LIMIT" =~ ^[0-9]+$ ]] || die "--limit must be a non-negative integer"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --no-mps)
                USE_MPS=0
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

require_runtime_commands() {
    command -v awk >/dev/null || die "awk is required"
    command -v sed >/dev/null || die "sed is required"
    command -v ps >/dev/null || die "ps is required"
    command -v pgrep >/dev/null || die "pgrep is required"

    [[ "$CUDA_VISIBLE_DEVICES" != *,* ]] || die "Expose exactly one GPU, e.g. CUDA_VISIBLE_DEVICES=0"
    [[ -x "$QDYN" ]] || die "QDYN is not executable: $QDYN"
    [[ -x "$QFEP" ]] || die "QFEP is not executable: $QFEP"
    command -v nvidia-smi >/dev/null || die "nvidia-smi is required"

    if ((USE_MPS)); then
        command -v nvidia-cuda-mps-control >/dev/null || die "nvidia-cuda-mps-control is required, or use --no-mps"
    fi

    if ! nvidia-smi -i "$GPU_ID" --query-gpu=power.draw --format=csv,noheader,nounits >/dev/null 2>&1; then
        GPU_HAS_POWER=0
    fi
}

init_metrics() {
    mkdir -p "$RAW_METRICS_DIR"
    if [[ ! -f "$SUMMARY_FILE" ]]; then
        printf '%s\n' \
            $'fep_id\tsystem\tfep_path\tstart_time\tend_time\twall_sec\tstatus\treplicates_done\tcpu_samples\tgpu_samples\tcpu_avg_pct_cores\tcpu_peak_pct_cores\tcpu_avg_pct_node\tcpu_peak_pct_node\trss_avg_mb\trss_peak_mb\tgpu_avg_pct\tgpu_peak_pct\tgpu_mem_util_avg_pct\tgpu_mem_util_peak_pct\tgpu_mem_used_avg_mb\tgpu_mem_used_peak_mb\tgpu_power_avg_w\tgpu_power_peak_w' \
            > "$SUMMARY_FILE"
    fi
    printf '%s\n' \
        $'timestamp\tfep_id\tsystem\telapsed_sec\tstatus\trunning_replicates\tdone_replicates\tfailed_replicates\tgpu_util_pct\tgpu_mem_used_mb\tgpu_mem_total_mb\tgpu_power_w' \
        > "$STATUS_FILE"
}

collect_process_tree() {
    local queue=("$@")
    local all=()
    local pid child

    while ((${#queue[@]})); do
        pid="${queue[0]}"
        queue=("${queue[@]:1}")
        [[ -n "$pid" ]] || continue
        kill -0 "$pid" 2>/dev/null || continue
        all+=("$pid")
        while IFS= read -r child; do
            [[ -n "$child" ]] && queue+=("$child")
        done < <(pgrep -P "$pid" 2>/dev/null || true)
    done

    printf '%s\n' "${all[@]}"
}

kill_process_tree() {
    local roots=("$@")
    local pids=()

    mapfile -t pids < <(collect_process_tree "${roots[@]}" | awk 'NF' | sort -rn | uniq)
    ((${#pids[@]})) || return 0
    kill -TERM "${pids[@]}" 2>/dev/null || true
    sleep 2
    mapfile -t pids < <(collect_process_tree "${roots[@]}" | awk 'NF' | sort -rn | uniq)
    ((${#pids[@]})) && kill -KILL "${pids[@]}" 2>/dev/null || true
}

cleanup() {
    local rc=$?
    trap - EXIT INT TERM

    if ((${#ACTIVE_SAMPLERS[@]})); then
        kill "${ACTIVE_SAMPLERS[@]}" 2>/dev/null || true
        wait "${ACTIVE_SAMPLERS[@]}" 2>/dev/null || true
    fi

    if ((${#ACTIVE_WORKERS[@]})); then
        kill_process_tree "${ACTIVE_WORKERS[@]}"
        wait "${ACTIVE_WORKERS[@]}" 2>/dev/null || true
    fi

    if ((MPS_STARTED)); then
        echo quit | nvidia-cuda-mps-control >/dev/null 2>&1 || true
    fi

    exit "$rc"
}

start_mps() {
    ((USE_MPS)) || return 0

    export CUDA_MPS_PIPE_DIRECTORY="${CUDA_MPS_PIPE_DIRECTORY:-/tmp/nvidia-mps-${USER:-user}-$$}"
    export CUDA_MPS_LOG_DIRECTORY="${CUDA_MPS_LOG_DIRECTORY:-/tmp/nvidia-mps-log-${USER:-user}-$$}"
    mkdir -p "$CUDA_MPS_PIPE_DIRECTORY" "$CUDA_MPS_LOG_DIRECTORY"

    if [[ -n "${MPS_ACTIVE_THREAD_PERCENTAGE:-}" ]]; then
        export CUDA_MPS_ACTIVE_THREAD_PERCENTAGE="$MPS_ACTIVE_THREAD_PERCENTAGE"
        log "MPS active thread percentage per client: $CUDA_MPS_ACTIVE_THREAD_PERCENTAGE"
    fi

    log "Starting MPS on CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES"
    nvidia-cuda-mps-control -d
    MPS_STARTED=1
    sleep 1
}

system_label_from_path() {
    local parent
    parent="$(basename "$(dirname "$1")")"
    case "$parent" in
        2.protein) printf 'protein\n' ;;
        1.water) printf 'water\n' ;;
        *) die "Cannot infer system from path: $1" ;;
    esac
}

safe_tag() {
    printf '%s' "$1" | sed 's#[^A-Za-z0-9_.-]#_#g'
}

parse_array_assignment() {
    local script="$1"
    local name="$2"
    local line
    line="$(awk -v name="$name" '$0 ~ "^" name "=\\(" {print; exit}' "$script")"
    [[ -n "$line" ]] || return 1
    line="${line#"$name=("}"
    line="${line%)}"
    printf '%s\n' "$line"
}

extract_qdyn_inputs() {
    local run_script="$1"
    awk '
        /#EQ_FILES/ {capture=1; next}
        /timeout 3m/ {exit}
        capture && /\$qdyn/ {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /\.inp$/) print $i
            }
        }
    ' "$run_script"
}

sample_cpu_mem() {
    local output="$1"
    local interval="$2"
    shift 2
    local roots=("$@")
    local nproc
    nproc="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc)"

    printf 'epoch,iso,cpu_pct_cores,cpu_pct_node,rss_mb,pid_count\n' > "$output"

    while true; do
        local epoch iso pids=() pid_csv stats cpu_cores rss_kb rss_mb cpu_node pid_count
        epoch="$(date +%s)"
        iso="$(date -Iseconds)"
        mapfile -t pids < <(collect_process_tree "${roots[@]}" | awk 'NF' | sort -n | uniq)
        pid_count="${#pids[@]}"

        if ((pid_count)); then
            pid_csv="$(IFS=,; printf '%s' "${pids[*]}")"
            stats="$(ps -o pcpu=,rss= -p "$pid_csv" 2>/dev/null | awk '
                {cpu += $1; rss += $2}
                END {printf "%.4f %.0f", cpu + 0, rss + 0}
            ')"
            cpu_cores="${stats%% *}"
            rss_kb="${stats##* }"
        else
            cpu_cores="0.0000"
            rss_kb="0"
        fi

        cpu_node="$(awk -v cpu="$cpu_cores" -v n="$nproc" 'BEGIN {if (n > 0) printf "%.4f", cpu / n; else printf "0.0000"}')"
        rss_mb="$(awk -v rss="$rss_kb" 'BEGIN {printf "%.4f", rss / 1024.0}')"
        printf '%s,%s,%s,%s,%s,%s\n' "$epoch" "$iso" "$cpu_cores" "$cpu_node" "$rss_mb" "$pid_count" >> "$output"
        sleep "$interval"
    done
}

sample_gpu() {
    local output="$1"
    local interval="$2"
    local gpu_id="$3"
    local query line epoch

    printf 'epoch,nvidia_timestamp,gpu_index,gpu_util_pct,gpu_mem_util_pct,gpu_mem_used_mb,gpu_mem_total_mb,gpu_power_w\n' > "$output"

    if ((GPU_HAS_POWER)); then
        query='timestamp,index,utilization.gpu,utilization.memory,memory.used,memory.total,power.draw'
    else
        query='timestamp,index,utilization.gpu,utilization.memory,memory.used,memory.total'
    fi

    while true; do
        epoch="$(date +%s)"
        if line="$(nvidia-smi -i "$gpu_id" --query-gpu="$query" --format=csv,noheader,nounits 2>/dev/null | head -n 1)"; then
            if ((GPU_HAS_POWER)); then
                printf '%s,%s\n' "$epoch" "$line" >> "$output"
            else
                printf '%s,%s,NA\n' "$epoch" "$line" >> "$output"
            fi
        else
            printf '%s,NA,NA,NA,NA,NA,NA,NA\n' "$epoch" >> "$output"
        fi
        sleep "$interval"
    done
}

query_gpu_status() {
    local gpu_id="$1"
    local query line

    if ((GPU_HAS_POWER)); then
        query='utilization.gpu,memory.used,memory.total,power.draw'
    else
        query='utilization.gpu,memory.used,memory.total'
    fi

    if line="$(nvidia-smi -i "$gpu_id" --query-gpu="$query" --format=csv,noheader,nounits 2>/dev/null | head -n 1)"; then
        if ((GPU_HAS_POWER)); then
            printf '%s\n' "$line" | awk -F',' '{gsub(/^[ \t]+|[ \t]+$/, "", $1); gsub(/^[ \t]+|[ \t]+$/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $3); gsub(/^[ \t]+|[ \t]+$/, "", $4); printf "%s\t%s\t%s\t%s", $1, $2, $3, $4}'
        else
            printf '%s\n' "$line" | awk -F',' '{gsub(/^[ \t]+|[ \t]+$/, "", $1); gsub(/^[ \t]+|[ \t]+$/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $3); printf "%s\t%s\t%s\tNA", $1, $2, $3}'
        fi
    else
        printf 'NA\tNA\tNA\tNA'
    fi
}

write_current_status_snapshot() {
    local output="$1"
    local fep_name="$2"
    local system_label="$3"
    local start_epoch="$4"
    local status="$5"
    local rep_raw="$6"
    shift 6
    local pids=("$@")
    local timestamp elapsed running done failed gpu_fields tmp pid

    timestamp="$(date -Iseconds)"
    elapsed="$(($(date +%s) - start_epoch))"
    running=0
    for pid in "${pids[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            running=$((running + 1))
        fi
    done

    done="$(awk -F'\t' 'NR > 1 && $4 == "ok" {count++} END {print count + 0}' "$rep_raw" 2>/dev/null || printf '0')"
    failed="$(awk -F'\t' 'NR > 1 && $4 == "failed" {count++} END {print count + 0}' "$rep_raw" 2>/dev/null || printf '0')"
    gpu_fields="$(query_gpu_status "$GPU_ID")"
    tmp="$output.$BASHPID.tmp"

    {
        printf '%s\n' $'timestamp\tfep_id\tsystem\telapsed_sec\tstatus\trunning_replicates\tdone_replicates\tfailed_replicates\tgpu_util_pct\tgpu_mem_used_mb\tgpu_mem_total_mb\tgpu_power_w'
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$timestamp" "$fep_name" "$system_label" "$elapsed" "$status" "$running" "$done" "$failed" "$gpu_fields"
    } > "$tmp"
    mv "$tmp" "$output"
}

sample_current_status() {
    local output="$1"
    local interval="$2"
    local fep_name="$3"
    local system_label="$4"
    local start_epoch="$5"
    local rep_raw="$6"
    shift 6
    local pids=("$@")

    while true; do
        write_current_status_snapshot "$output" "$fep_name" "$system_label" "$start_epoch" "running" "$rep_raw" "${pids[@]}"
        sleep "$interval"
    done
}

cpu_stats() {
    local file="$1"
    awk -F',' '
        NR > 1 {
            samples++
            cpu += $3
            if ($3 > cpu_peak) cpu_peak = $3
            node += $4
            if ($4 > node_peak) node_peak = $4
            rss += $5
            if ($5 > rss_peak) rss_peak = $5
        }
        END {
            if (samples == 0) {
                printf "0\tNA\tNA\tNA\tNA\tNA\tNA"
            } else {
                printf "%d\t%.4f\t%.4f\t%.4f\t%.4f\t%.4f\t%.4f", samples, cpu / samples, cpu_peak, node / samples, node_peak, rss / samples, rss_peak
            }
        }
    ' "$file"
}

gpu_stats() {
    local file="$1"
    awk -F',' '
        function trim(s) {
            gsub(/^[ \t]+|[ \t]+$/, "", s)
            return s
        }
        function numeric(s) {
            s = trim(s)
            return s ~ /^[-+]?[0-9]+([.][0-9]+)?$/
        }
        NR > 1 {
            samples++
            gpu = trim($4)
            mem_util = trim($5)
            mem_used = trim($6)
            power = trim($8)

            if (numeric(gpu)) {
                gpu_sum += gpu
                gpu_n++
                if (gpu > gpu_peak) gpu_peak = gpu
            }
            if (numeric(mem_util)) {
                mem_util_sum += mem_util
                mem_util_n++
                if (mem_util > mem_util_peak) mem_util_peak = mem_util
            }
            if (numeric(mem_used)) {
                mem_used_sum += mem_used
                mem_used_n++
                if (mem_used > mem_used_peak) mem_used_peak = mem_used
            }
            if (numeric(power)) {
                power_sum += power
                power_n++
                if (power > power_peak) power_peak = power
            }
        }
        END {
            gpu_avg = gpu_n ? sprintf("%.4f", gpu_sum / gpu_n) : "NA"
            gpu_pk = gpu_n ? sprintf("%.4f", gpu_peak) : "NA"
            mem_util_avg = mem_util_n ? sprintf("%.4f", mem_util_sum / mem_util_n) : "NA"
            mem_util_pk = mem_util_n ? sprintf("%.4f", mem_util_peak) : "NA"
            mem_used_avg = mem_used_n ? sprintf("%.4f", mem_used_sum / mem_used_n) : "NA"
            mem_used_pk = mem_used_n ? sprintf("%.4f", mem_used_peak) : "NA"
            power_avg = power_n ? sprintf("%.4f", power_sum / power_n) : "NA"
            power_pk = power_n ? sprintf("%.4f", power_peak) : "NA"
            printf "%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s", samples, gpu_avg, gpu_pk, mem_util_avg, mem_util_pk, mem_used_avg, mem_used_pk, power_avg, power_pk
        }
    ' "$file"
}

run_qdyn_step() {
    local input="$1"
    local base="${input%.inp}"
    local start end rc
    local fep_name="${CURRENT_FEP_NAME:-unknown_fep}"
    local system_label="${CURRENT_SYSTEM_LABEL:-unknown_system}"
    local replicate="${CURRENT_REPLICATE:-unknown_rep}"

    start="$(date +%s)"
    log "START fep=$fep_name system=$system_label rep=$replicate step=$input"
    set +e
    "$QDYN" --gpu "$input" > "${base}.log" 2> "${base}.err"
    rc=$?
    set -e
    end="$(date +%s)"
    printf '%s\t%s\t%s\t%s\t%s\n' "$input" "$start" "$end" "$((end - start))" "$rc" >> qgpu_steps.tsv
    log "DONE fep=$fep_name system=$system_label rep=$replicate step=$input wall_sec=$((end - start)) exit_code=$rc"
    return "$rc"
}

run_qfep_step() {
    local start end rc
    local fep_name="${CURRENT_FEP_NAME:-unknown_fep}"
    local system_label="${CURRENT_SYSTEM_LABEL:-unknown_system}"
    local replicate="${CURRENT_REPLICATE:-unknown_rep}"

    start="$(date +%s)"
    log "START fep=$fep_name system=$system_label rep=$replicate step=qfep.inp"
    set +e
    if command -v timeout >/dev/null; then
        timeout 3m "$QFEP" < qfep.inp > qfep.out 2> qfep.err
        rc=$?
    else
        "$QFEP" < qfep.inp > qfep.out 2> qfep.err
        rc=$?
    fi
    set -e
    end="$(date +%s)"
    printf '%s\t%s\t%s\t%s\t%s\n' "qfep.inp" "$start" "$end" "$((end - start))" "$rc" >> qgpu_steps.tsv
    log "DONE fep=$fep_name system=$system_label rep=$replicate step=qfep.inp wall_sec=$((end - start)) exit_code=$rc"

    [[ "$rc" -eq 0 || "$rc" -eq 124 ]]
}

cleanup_replicate_outputs() {
    if [[ "$KEEP_QFEP_ONLY" == "1" ]]; then
        find . -maxdepth 1 -type f ! -name 'qfep.out' -delete
    else
        rm -f ./*.dcd ./*.inp
    fi
}

stage_replicate_inputs() {
    local fep_root="$1"
    local run_num="$2"
    local temperature="$3"
    local seed="$4"
    local fepfile="$5"
    local inputfiles="$fep_root/inputfiles"
    local rundir="$fep_root/FEP1/$temperature/$run_num"

    mkdir -p "$rundir"
    cp "$inputfiles"/md*.inp "$rundir"/
    cp "$inputfiles"/eq*.inp "$rundir"/
    cp "$inputfiles"/*.top "$rundir"/
    cp "$inputfiles"/qfep.inp "$rundir"/
    cp "$inputfiles"/"$fepfile" "$rundir"/

    (
        cd "$rundir"
        sed -i "s/SEED_VAR/$seed/g" eq1.inp
        sed -i "s/T_VAR/$temperature/g" ./*.inp
        sed -i "s/FEP_VAR/$fepfile/g" ./*.inp
        printf 'step\tstart_epoch\tend_epoch\twall_sec\texit_code\n' > qgpu_steps.tsv
    )

    printf '%s\n' "$rundir"
}

run_replicate() {
    local fep_root="$1"
    local run_num="$2"
    local temperature="$3"
    local seed="$4"
    local fepfile="$5"
    shift 5
    local inputs=("$@")
    local rundir input
    CURRENT_FEP_NAME="$(basename "$fep_root")"
    CURRENT_SYSTEM_LABEL="$(system_label_from_path "$fep_root")"
    CURRENT_REPLICATE="$run_num"

    rundir="$(stage_replicate_inputs "$fep_root" "$run_num" "$temperature" "$seed" "$fepfile")"

    (
        cd "$rundir"
        log "Starting replicate $run_num in $rundir, T=$temperature, seed=$seed"
        for input in "${inputs[@]}"; do
            [[ -f "$input" ]] || die "Missing input file in $rundir: $input"
            run_qdyn_step "$input"
        done

        run_qfep_step

        if [[ "$CLEAN_AFTER" == "1" ]]; then
            cleanup_replicate_outputs
        fi

        log "Finished replicate $run_num in $rundir"
    )
}

run_system() {
    local fep_root="$1"
    local fep_name system_label run_script inputfiles tag cpu_raw gpu_raw rep_raw
    local start_epoch end_epoch start_iso end_iso status wall_sec
    local seeds=() temperatures=() fepfiles=() inputs=()
    local worker_pids=() worker_reps=()
    local cpu_sampler_pid gpu_sampler_pid status_sampler_pid done_count=0 failures=0

    fep_root="$(cd "$fep_root" && pwd)"
    fep_name="$(basename "$fep_root")"
    system_label="$(system_label_from_path "$fep_root")"
    run_script="$fep_root/inputfiles/runSNELLIUS.sh"
    inputfiles="$fep_root/inputfiles"
    [[ -f "$run_script" ]] || die "Missing run script: $run_script"

    read -r -a seeds <<< "$(parse_array_assignment "$run_script" "seeds")"
    read -r -a temperatures <<< "$(parse_array_assignment "$run_script" "temperatures")"
    read -r -a fepfiles <<< "$(parse_array_assignment "$run_script" "fepfiles")"
    mapfile -t inputs < <(extract_qdyn_inputs "$run_script")

    ((${#seeds[@]} == 10)) || die "$run_script: expected 10 seeds, got ${#seeds[@]}"
    ((${#temperatures[@]} == 1)) || die "$run_script: expected 1 temperature, got ${#temperatures[@]}"
    ((${#fepfiles[@]} == 1)) || die "$run_script: this local runner currently expects exactly 1 FEP file, got ${#fepfiles[@]}"
    ((${#inputs[@]} > 0)) || die "$run_script: could not extract qdyn input order"
    [[ -d "$inputfiles" ]] || die "Missing inputfiles directory: $inputfiles"

    tag="$(safe_tag "$fep_name.$system_label")"
    cpu_raw="$RAW_METRICS_DIR/$tag.cpu_mem.csv"
    gpu_raw="$RAW_METRICS_DIR/$tag.gpu.csv"
    rep_raw="$RAW_METRICS_DIR/$tag.replicates.tsv"

    log "Running $fep_name $system_label with 10 concurrent replicates"
    printf 'replicate\tpid\texit_code\tstatus\n' > "$rep_raw"

    start_epoch="$(date +%s)"
    start_iso="$(date -Iseconds)"

    for run_num in $(seq 1 10); do
        local seed="${seeds[$((run_num - 1))]}"
        local runner_log="$RAW_METRICS_DIR/$tag.replicate_$(printf '%02d' "$run_num").runner.log"
        (
            DUPLICATE_LOG_TO_MAIN=1
            run_replicate "$fep_root" "$run_num" "${temperatures[0]}" "$seed" "${fepfiles[0]}" "${inputs[@]}"
        ) > "$runner_log" 2>&1 &
        worker_pids+=("$!")
        worker_reps+=("$run_num")
    done
    ACTIVE_WORKERS=("${worker_pids[@]}")

    sample_cpu_mem "$cpu_raw" "$METRIC_INTERVAL" "${worker_pids[@]}" &
    cpu_sampler_pid="$!"
    sample_gpu "$gpu_raw" "$METRIC_INTERVAL" "$GPU_ID" &
    gpu_sampler_pid="$!"
    sample_current_status "$STATUS_FILE" "$METRIC_INTERVAL" "$fep_name" "$system_label" "$start_epoch" "$rep_raw" "${worker_pids[@]}" &
    status_sampler_pid="$!"
    ACTIVE_SAMPLERS=("$cpu_sampler_pid" "$gpu_sampler_pid" "$status_sampler_pid")

    for idx in "${!worker_pids[@]}"; do
        local pid="${worker_pids[$idx]}"
        local rep="${worker_reps[$idx]}"
        local rc
        set +e
        wait "$pid"
        rc=$?
        set -e
        if [[ "$rc" -eq 0 ]]; then
            done_count=$((done_count + 1))
            printf '%s\t%s\t%s\t%s\n' "$rep" "$pid" "$rc" "ok" >> "$rep_raw"
        else
            failures=$((failures + 1))
            printf '%s\t%s\t%s\t%s\n' "$rep" "$pid" "$rc" "failed" >> "$rep_raw"
        fi
    done

    kill "$cpu_sampler_pid" "$gpu_sampler_pid" "$status_sampler_pid" 2>/dev/null || true
    wait "$cpu_sampler_pid" "$gpu_sampler_pid" "$status_sampler_pid" 2>/dev/null || true
    ACTIVE_SAMPLERS=()
    ACTIVE_WORKERS=()

    end_epoch="$(date +%s)"
    end_iso="$(date -Iseconds)"
    wall_sec="$((end_epoch - start_epoch))"
    if ((failures)); then
        status="failed"
    else
        status="ok"
    fi
    write_current_status_snapshot "$STATUS_FILE" "$fep_name" "$system_label" "$start_epoch" "$status" "$rep_raw" "${worker_pids[@]}"

    local cpu_summary gpu_summary
    cpu_summary="$(cpu_stats "$cpu_raw")"
    gpu_summary="$(gpu_stats "$gpu_raw")"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$fep_name" "$system_label" "$fep_root" "$start_iso" "$end_iso" "$wall_sec" "$status" "$done_count" \
        "$cpu_summary" "$gpu_summary" >> "$SUMMARY_FILE"

    log "Finished $fep_name $system_label: status=$status wall_sec=$wall_sec replicates_done=$done_count"
    [[ "$status" == "ok" ]]
}

resolve_targets() {
    local targets=()
    local fep_names=()
    local only_path

    if [[ -n "$ONLY" ]]; then
        if [[ -d "$ONLY" ]]; then
            only_path="$(cd "$ONLY" && pwd)"
            targets+=("$only_path")
        elif [[ -d "$REPO_ROOT/$ONLY" ]]; then
            only_path="$(cd "$REPO_ROOT/$ONLY" && pwd)"
            targets+=("$only_path")
        elif [[ "$ONLY" == FEP_* ]]; then
            fep_names+=("$ONLY")
        else
            die "--only value is neither an existing path nor an FEP name: $ONLY"
        fi
    else
        while IFS= read -r fep; do
            fep_names+=("$fep")
        done < <(find "$CDK2_DIR/2.protein" -maxdepth 1 -type d -name 'FEP_*' -printf '%f\n' | sort)
    fi

    if ((${#fep_names[@]})); then
        local count=0
        local fep_name system_dir path
        for fep_name in "${fep_names[@]}"; do
            if ((LIMIT > 0 && count >= LIMIT)); then
                break
            fi
            for system_dir in 2.protein 1.water; do
                path="$CDK2_DIR/$system_dir/$fep_name"
                [[ -d "$path/inputfiles" ]] || die "Missing paired system path: $path"
                targets+=("$path")
            done
            count=$((count + 1))
        done
    fi

    printf '%s\n' "${targets[@]}"
}

main() {
    parse_args "$@"
    mapfile -t targets < <(resolve_targets)
    ((${#targets[@]})) || die "No FEP targets resolved"

    if ((DRY_RUN)); then
        printf 'Execution order:\n'
        printf '  %s\n' "${targets[@]}"
        exit 0
    fi

    require_runtime_commands
    init_metrics
    start_mps

    log "QDYN=$QDYN"
    log "QFEP=$QFEP"
    log "GPU_ID=$GPU_ID CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES"
    log "Metrics summary: $SUMMARY_FILE"

    local target
    for target in "${targets[@]}"; do
        if ! run_system "$target"; then
            if [[ "$CONTINUE_ON_ERROR" == "1" ]]; then
                log "Continuing after failed system: $target"
            else
                die "Stopping after failed system: $target"
            fi
        fi
    done

    log "All requested FEP systems finished"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

main "$@"
