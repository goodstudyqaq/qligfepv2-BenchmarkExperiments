#!/usr/bin/env bash

# Source this file, then run backup_qgpu_mps from a qgpu_mps results directory:
#
#   source /path/to/backup_qgpu_mps.sh
#   backup_qgpu_mps
#
# Optional arguments:
#
#   backup_qgpu_mps ARCHIVE_PATH SOURCE_DIRECTORY
#
# Compression can be tuned without editing the function:
#
#   QGPU_BACKUP_THREADS=2 QGPU_BACKUP_LEVEL=1 backup_qgpu_mps
#
# Raw .en energy files are omitted by default for speed. Include them only when
# the backup must support rerunning qfep:
#
#   QGPU_BACKUP_INCLUDE_EN=1 backup_qgpu_mps
#
# To submit one dataset as a staging job, run this from its parent directory:
#
#   back_up bace
#
# This mode always includes .en files. Optional submission settings are
# QGPU_BACKUP_TIME, QGPU_BACKUP_PARTITION, QGPU_BACKUP_MEM, and
# QGPU_BACKUP_THREADS.

backup_qgpu_mps() {
    local requested_archive="${1:-}"
    local requested_root="${2:-.}"
    local source_root archive source_name timestamp file_list file_count
    local command_name data_root replicate_dir result_name result_path
    local threads="${QGPU_BACKUP_THREADS:-2}"
    local level="${QGPU_BACKUP_LEVEL:-1}"
    local include_en="${QGPU_BACKUP_INCLUDE_EN:-0}"

    for command_name in find tar zstd mktemp; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            printf 'ERROR: required command is unavailable: %s\n' "$command_name" >&2
            return 1
        fi
    done

    if [[ ! "$threads" =~ ^[1-9][0-9]*$ ]]; then
        printf 'ERROR: QGPU_BACKUP_THREADS must be a positive integer\n' >&2
        return 1
    fi
    if [[ ! "$level" =~ ^([1-9]|1[0-9])$ ]]; then
        printf 'ERROR: QGPU_BACKUP_LEVEL must be an integer from 1 to 19\n' >&2
        return 1
    fi
    if [[ "$include_en" != "0" && "$include_en" != "1" ]]; then
        printf 'ERROR: QGPU_BACKUP_INCLUDE_EN must be 0 or 1\n' >&2
        return 1
    fi

    if ! source_root="$(cd -P "$requested_root" 2>/dev/null && pwd)"; then
        printf 'ERROR: source directory does not exist: %s\n' "$requested_root" >&2
        return 1
    fi

    source_name="$(basename "$source_root")"
    timestamp="$(date +%Y%m%d_%H%M%S)"
    if [[ -n "$requested_archive" ]]; then
        if [[ "$requested_archive" == /* ]]; then
            archive="$requested_archive"
        else
            archive="$PWD/$requested_archive"
        fi
    else
        archive="$PWD/${source_name}_important_${timestamp}.tar.zst"
    fi

    if [[ -e "$archive" ]]; then
        printf 'ERROR: refusing to overwrite existing archive: %s\n' "$archive" >&2
        return 1
    fi

    if ! file_list="$(mktemp "${TMPDIR:-/tmp}/qgpu_backup_files.XXXXXX")"; then
        printf 'ERROR: could not create the temporary file list\n' >&2
        return 1
    fi

    # Keep final analysis data and run metadata. In particular:
    #   - qfep.out contains the calculated FEP result.
    #   - optional .en files permit qfep to be rerun with different settings.
    #   - jobs, logs, and metrics contain Slurm status and benchmark data.
    # Large .dcd, .re, and MD .log files below FEP1 are intentionally omitted.
    #
    # First discover and prune known data roots. This avoids recursively
    # examining every file below FEP1 while looking for result directories.
    if ! (
        cd "$source_root" || exit 1

        while IFS= read -r -d '' data_root; do
            case "$(basename "$data_root")" in
                FEP1)
                    # The runner writes results as FEP1/TEMPERATURE/REPLICATE.
                    # Stat the three exact final-result names without scanning
                    # every .dcd, .re, and .log entry in each replicate.
                    while IFS= read -r -d '' replicate_dir; do
                        for result_name in qfep.out qfep.err qgpu_steps.tsv; do
                            result_path="$replicate_dir/$result_name"
                            if [[ -f "$result_path" || -L "$result_path" ]]; then
                                printf '%s\0' "$result_path"
                            fi
                        done
                        if [[ "$include_en" == "1" ]]; then
                            find "$replicate_dir" -maxdepth 1 \
                                \( -type f -o -type l \) -name '*.en' -print0
                        fi
                    done < <(
                        find "$data_root" -mindepth 2 -maxdepth 2 \
                            -type d -print0
                    )
                    ;;
                inputfiles)
                    find "$data_root" -maxdepth 1 \
                        \( -type f -o -type l \) \
                        \( -name 'fep_config.json' \
                            -o -name 'qfep.inp' \
                            -o -name '*.fep' \) \
                        -print0
                    ;;
                jobs|logs|metrics)
                    find "$data_root" \( -type f -o -type l \) -print0
                    ;;
            esac
        done < <(
            find . \
                \( -type d -name .git -prune \) \
                -o \( -type d \
                    \( -name FEP1 \
                        -o -name inputfiles \
                        -o -name jobs \
                        -o -name logs \
                        -o -name metrics \) \
                    -print0 -prune \)
        )

        # Dataset-level metadata lives either in the selected dataset or one
        # level below a collection directory such as qgpu_mps.
        find . -maxdepth 2 \( -type f -o -type l \) \
            \( -name 'slurm*.out' \
                -o -name 'ligands.sdf' \
                -o -name 'water.pdb' \
                -o -name 'protein.pdb' \
                -o \( -name '*.json' ! -path '*/inputfiles/*' \) \
                -o -name 'run_qgpu_mps_*.sh' \) \
            -print0
    ) > "$file_list"; then
        printf 'ERROR: failed while finding backup files\n' >&2
        rm -f -- "$file_list"
        return 1
    fi

    if [[ ! -s "$file_list" ]]; then
        printf 'ERROR: no qgpu_mps result files were found below %s\n' "$source_root" >&2
        rm -f -- "$file_list"
        return 1
    fi

    file_count="$(tr -cd '\0' < "$file_list" | wc -c)"
    file_count="${file_count//[[:space:]]/}"
    printf 'Archiving %s important files from %s\n' "$file_count" "$source_root"
    if [[ "$include_en" == "1" ]]; then
        printf 'Including raw .en energy files for qfep reanalysis\n'
    else
        printf 'Fast mode: keeping final qfep results, but not raw .en files\n'
    fi
    printf 'Excluding FEP1 trajectories, restart files, and MD logs\n'

    if ! (
        set -o pipefail
        (
            cd "$source_root" &&
                tar --create --file=- --no-xattrs --null --no-recursion \
                    --files-from="$file_list"
        ) | zstd -T"$threads" -"$level" -q -o "$archive"
    ); then
        rm -f -- "$file_list"
        printf 'ERROR: tar or zstd failed while creating the backup\n' >&2
        rm -f -- "$archive"
        return 1
    fi

    rm -f -- "$file_list"

    printf 'Backup created: %s\n' "$archive"
    printf 'Verify it with: zstd -t %q\n' "$archive"
}

back_up() {
    local requested_dataset="${1:-}"
    local submit_root dataset_root dataset_name job_name timestamp
    local archive log_path script_path script_dir
    local partition="${QGPU_BACKUP_PARTITION:-staging}"
    local time_limit="${QGPU_BACKUP_TIME:-04:00:00}"
    local memory="${QGPU_BACKUP_MEM:-4G}"
    local threads="${QGPU_BACKUP_THREADS:-2}"
    local level="${QGPU_BACKUP_LEVEL:-1}"
    local batch_command wrap_command job_id

    if [[ -z "$requested_dataset" ]]; then
        printf 'Usage: back_up DATASET_DIRECTORY\n' >&2
        printf 'Example: back_up bace\n' >&2
        return 2
    fi
    if ! command -v sbatch >/dev/null 2>&1; then
        printf 'ERROR: sbatch is unavailable; run back_up on the HPC\n' >&2
        return 1
    fi
    if [[ ! "$threads" =~ ^[1-9][0-9]*$ ]]; then
        printf 'ERROR: QGPU_BACKUP_THREADS must be a positive integer\n' >&2
        return 1
    fi
    if [[ ! "$level" =~ ^([1-9]|1[0-9])$ ]]; then
        printf 'ERROR: QGPU_BACKUP_LEVEL must be an integer from 1 to 19\n' >&2
        return 1
    fi

    submit_root="$PWD"
    if ! dataset_root="$(cd -P "$requested_dataset" 2>/dev/null && pwd)"; then
        printf 'ERROR: dataset directory does not exist: %s\n' "$requested_dataset" >&2
        return 1
    fi
    dataset_name="$(basename "$dataset_root")"
    job_name="${dataset_name//[^[:alnum:]_-]/_}"
    timestamp="$(date +%Y%m%d_%H%M%S)"
    archive="$submit_root/${dataset_name}_important_${timestamp}.tar.zst"
    log_path="$submit_root/${dataset_name}_backup.%j.log"

    script_path="${QGPU_BACKUP_SCRIPT:-${BASH_SOURCE[0]}}"
    if [[ ! -f "$script_path" ]]; then
        printf 'ERROR: cannot locate backup script: %s\n' "$script_path" >&2
        printf 'Set QGPU_BACKUP_SCRIPT to its absolute path and try again.\n' >&2
        return 1
    fi
    script_dir="$(cd -P "$(dirname "$script_path")" && pwd)"
    script_path="$script_dir/$(basename "$script_path")"

    # Quote every path for the inner Bash process. sbatch --wrap itself remains
    # fixed, so dataset names containing spaces or shell characters stay safe.
    printf -v batch_command \
        'source %q && QGPU_BACKUP_INCLUDE_EN=1 QGPU_BACKUP_THREADS=%q QGPU_BACKUP_LEVEL=%q backup_qgpu_mps %q %q' \
        "$script_path" "$threads" "$level" "$archive" "$dataset_root"
    printf -v wrap_command 'bash -c %q' "$batch_command"

    if ! job_id="$(
        sbatch \
            --parsable \
            --job-name="qgpu_backup_${job_name}" \
            --partition="$partition" \
            --time="$time_limit" \
            --ntasks=1 \
            --cpus-per-task="$threads" \
            --mem="$memory" \
            --chdir="$submit_root" \
            --output="$log_path" \
            --wrap="$wrap_command"
    )"; then
        printf 'ERROR: failed to submit backup job for %s\n' "$dataset_root" >&2
        return 1
    fi

    printf 'Submitted backup job %s for %s\n' "$job_id" "$dataset_root"
    printf 'Archive: %s\n' "$archive"
    printf 'Log: %s\n' "${log_path//%j/$job_id}"
    printf 'Monitor: squeue -j %q\n' "$job_id"
}
