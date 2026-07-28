#!/usr/bin/env bash
#SBATCH --job-name=parallel_rm
#SBATCH --partition=rome
#SBATCH --time=08:00:00
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --output=my_rm.%j.log

set -Eeuo pipefail

BATCH_SIZE="${BATCH_SIZE:-1000}"

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

validate_target() {
    local target="$1"
    local current_uid target_uid user_name

    [[ "$target" == /* ]] || die "Target must be an absolute path: $target"
    [[ -d "$target" ]] || die "Target directory does not exist: $target"
    [[ ! -L "$target" ]] || die "Refusing to remove a symbolic link: $target"

    user_name="${USER:-${LOGNAME:-}}"
    case "$target" in
        /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
            die "Refusing to remove protected directory: $target"
            ;;
    esac
    if [[ -n "$user_name" ]]; then
        case "$target" in
            "/home/$user_name"|"/scratch-shared/$user_name"|"/scratch-shared/$user_name/qgpu_batch")
                die "Refusing to remove protected user root: $target"
                ;;
        esac
    fi

    [[ ! -d "$target/.git" ]] || die "Refusing to remove a Git repository root: $target"
    if command -v mountpoint >/dev/null 2>&1 && mountpoint -q -- "$target"; then
        die "Refusing to remove a mount point: $target"
    fi

    current_uid="$(id -u)"
    target_uid="$(stat -c '%u' -- "$target")"
    [[ "$target_uid" == "$current_uid" ]] ||
        die "Target is not owned by uid $current_uid: $target"
}

[[ -n "${SLURM_JOB_ID:-}" ]] || die "Submit this script with sbatch"
[[ $# -eq 1 ]] || die "Usage: sbatch $0 /absolute/path/to/directory"
[[ "$BATCH_SIZE" =~ ^[1-9][0-9]*$ ]] || die "BATCH_SIZE must be a positive integer"

requested="$1"
[[ "$requested" == /* ]] || die "Use an absolute target path: $requested"
[[ ! -L "$requested" ]] || die "Refusing to remove a symbolic link: $requested"
target="$(realpath -e -- "$requested")"
[[ "$target" == "$requested" ]] ||
    die "Target must be canonical: requested=$requested resolved=$target"
validate_target "$target"

submission_dir="$(realpath -e -- "${SLURM_SUBMIT_DIR:-$PWD}")"
[[ "$submission_dir" != "$target" && "$submission_dir" != "$target/"* ]] ||
    die "Submit the job from outside the removal target so its log is preserved"

workers="${SLURM_CPUS_PER_TASK:-1}"
[[ "$workers" =~ ^[1-9][0-9]*$ ]] || die "Invalid worker count: $workers"

printf '[%s] Removing non-directory entries from %s (workers=%s, batch=%s)\n' \
    "$(date -Iseconds)" "$target" "$workers" "$BATCH_SIZE"

find "$target" -xdev -mindepth 1 ! -type d -print0 |
    xargs -0 -r -n "$BATCH_SIZE" -P "$workers" rm -f --

printf '[%s] Removing empty directories\n' "$(date -Iseconds)"
find "$target" -xdev -depth -mindepth 1 -type d -empty -delete

if find "$target" -mindepth 1 -print -quit | grep -q .; then
    die "Target is not empty after cleanup; refusing to remove it: $target"
fi

rmdir -- "$target"
printf '[%s] Removed directory: %s\n' "$(date -Iseconds)" "$target"
