#!/usr/bin/env bash

set -Eeuo pipefail

ARCHIVE_NAME="energies.tar.gz"

usage() {
    cat <<'EOF'
Usage:
  ./archive_en_replicates.sh ROOT [ROOT ...]

Replace the individual *.en files in every replicate directory below ROOT
with one verified energies.tar.gz archive. Original files are removed only
after the archive has been created and tested successfully.

Extract one replicate for QFEP reanalysis with:
  tar -xzf energies.tar.gz
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

archive_replicate() {
    local replicate_dir="$1"
    local archive
    local temporary
    local energy_path
    local energy_files=()

    replicate_dir="$(cd "$replicate_dir" && pwd)"
    archive="$replicate_dir/$ARCHIVE_NAME"

    while IFS= read -r -d '' energy_path; do
        energy_files+=("${energy_path##*/}")
    done < <(
        find "$replicate_dir" -maxdepth 1 -type f -name '*.en' -print0 |
            sort -z
    )

    ((${#energy_files[@]})) || return 0
    [[ ! -e "$archive" ]] || \
        die "refusing to overwrite an existing archive while *.en files remain: $archive"

    temporary="$(mktemp "$replicate_dir/.${ARCHIVE_NAME}.tmp.XXXXXX")"
    if ! (
        cd "$replicate_dir"
        tar -czf "$temporary" -- "${energy_files[@]}"
    ); then
        rm -f -- "$temporary"
        die "could not create energy archive in $replicate_dir"
    fi
    if ! tar -tzf "$temporary" >/dev/null; then
        rm -f -- "$temporary"
        die "energy archive verification failed in $replicate_dir"
    fi
    if [[ "$(tar -tzf "$temporary" | wc -l)" -ne "${#energy_files[@]}" ]]; then
        rm -f -- "$temporary"
        die "energy archive member count is incorrect in $replicate_dir"
    fi

    mv -- "$temporary" "$archive"
    for energy_path in "${energy_files[@]}"; do
        rm -f -- "$replicate_dir/$energy_path"
    done
    printf 'Archived %d energy files: %s\n' "${#energy_files[@]}" "$archive"
}

main() {
    local root replicate_dir
    local replicate_dirs=()

    if (($# == 0)); then
        usage >&2
        return 2
    fi
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        return 0
    fi
    command -v tar >/dev/null 2>&1 || die "tar is required"

    for root in "$@"; do
        [[ -d "$root" ]] || die "root directory does not exist: $root"
        while IFS= read -r -d '' replicate_dir; do
            replicate_dirs+=("$replicate_dir")
        done < <(
            find "$root" -type f -name '*.en' -printf '%h\0' |
                sort -zu
        )
    done

    for replicate_dir in "${replicate_dirs[@]}"; do
        archive_replicate "$replicate_dir"
    done
    printf 'Created %d per-replicate energy archive(s)\n' "${#replicate_dirs[@]}"
}

main "$@"
