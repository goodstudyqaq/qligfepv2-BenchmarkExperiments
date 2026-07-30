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

backup_qgpu_mps() {
    local requested_archive="${1:-}"
    local requested_root="${2:-.}"
    local source_root archive source_name timestamp file_list file_count
    local threads="${QGPU_BACKUP_THREADS:-2}"
    local level="${QGPU_BACKUP_LEVEL:-1}"

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

    # Keep analysis data and reproducibility metadata. In particular:
    #   - .en permits qfep to be rerun with different analysis settings.
    #   - qfep.out contains the calculated FEP result.
    #   - jobs, logs, and metrics contain Slurm status and benchmark data.
    # Large .dcd, .re, and MD .log files below FEP1 are intentionally omitted.
    if ! (
        cd "$source_root" &&
            find . \( -type f -o -type l \) \
                \( \
                    \( -path '*/FEP1/*' \
                        \( -name '*.en' \
                            -o -name 'qfep.out*' \
                            -o -name 'qfep.err' \
                            -o -name 'qgpu_steps.tsv' \) \) \
                    -o \( -path '*/inputfiles/*' \
                        \( -name 'fep_config.json' \
                            -o -name 'qfep.inp' \
                            -o -name '*.fep' \) \) \
                    -o -path '*/jobs/*' \
                    -o -path '*/logs/*' \
                    -o -path '*/metrics/*' \
                    -o -name 'slurm*.out' \
                    -o -name 'ligands.sdf' \
                    -o -name 'water.pdb' \
                    -o -name 'protein.pdb' \
                    -o -name '*.json' \
                    -o -name 'run_qgpu_mps_*.sh' \
                \) \
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
    printf 'Excluding FEP1 trajectories, restart files, and MD logs\n'

    if ! (
        set -o pipefail
        (
            cd "$source_root" &&
                tar --create --file=- --null --no-recursion \
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
