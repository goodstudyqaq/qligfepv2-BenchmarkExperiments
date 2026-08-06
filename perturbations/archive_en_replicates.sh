#!/usr/bin/env bash

set -Eeuo pipefail

REPLICATE_ARCHIVE_NAME="energies.tar.gz"

usage() {
    cat <<'EOF'
Usage:
  ./archive_en_replicates.sh --replicate REPLICATE_DIR
  ./archive_en_replicates.sh --edge EDGE_ARCHIVE BASE_DIR ROOT [ROOT ...]
  ./archive_en_replicates.sh ROOT [ROOT ...]

--replicate replaces the individual *.en files in one replicate directory
with one verified energies.tar.gz archive.

--edge combines the per-replicate energies.tar.gz files found below ROOT into
one uncompressed EDGE_ARCHIVE. Archive members are stored relative to BASE_DIR.
The per-replicate archives are removed only after the edge archive is verified.

The legacy ROOT form archives every replicate containing *.en below each ROOT.

Extract an edge and then one replicate for QFEP reanalysis with:
  tar -xf EDGE_ARCHIVE -C BASE_DIR
  tar -xzf BASE_DIR/path/to/replicate/energies.tar.gz -C BASE_DIR/path/to/replicate
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

archive_replicate() {
    local replicate_dir="$1"
    local archive temporary energy_path
    local energy_files=()

    replicate_dir="$(cd "$replicate_dir" && pwd)"
    archive="$replicate_dir/$REPLICATE_ARCHIVE_NAME"

    while IFS= read -r -d '' energy_path; do
        energy_files+=("${energy_path##*/}")
    done < <(
        find "$replicate_dir" -maxdepth 1 -type f -name '*.en' -print0 |
            sort -z
    )

    if ((${#energy_files[@]} == 0)); then
        [[ -f "$archive" ]] || die "no *.en files or replicate archive found in $replicate_dir"
        tar -tzf "$archive" >/dev/null ||
            die "existing replicate archive is unreadable: $archive"
        return 0
    fi

    if [[ -e "$archive" ]]; then
        tar -tzf "$archive" >/dev/null ||
            die "existing replicate archive is unreadable: $archive"
        for energy_path in "${energy_files[@]}"; do
            if ! tar -xOzf "$archive" -- "$energy_path" |
                cmp -s - "$replicate_dir/$energy_path"; then
                die "existing archive copy differs from remaining file: $replicate_dir/$energy_path"
            fi
        done
        printf 'Resuming cleanup from verified replicate archive: %s\n' "$archive"
    else
        temporary="$(mktemp "$replicate_dir/.${REPLICATE_ARCHIVE_NAME}.tmp.XXXXXX")"
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
        if ! diff -q \
            <(printf '%s\n' "${energy_files[@]}") \
            <(tar -tzf "$temporary" | sort) >/dev/null; then
            rm -f -- "$temporary"
            die "energy archive members are incorrect in $replicate_dir"
        fi
        mv -- "$temporary" "$archive"
    fi

    for energy_path in "${energy_files[@]}"; do
        rm -f -- "$replicate_dir/$energy_path"
    done
    printf 'Archived %d energy files: %s\n' "${#energy_files[@]}" "$archive"
}

archive_edge() {
    local requested_archive="$1"
    local base_dir="$2"
    shift 2
    local roots=("$@")
    local archive archive_dir temporary replicate_archive relative_path root index
    local qfep_output qfep_count=0
    local replicate_archives=() archive_members=() expected_members=()

    base_dir="$(cd "$base_dir" && pwd)"
    if [[ "$requested_archive" == /* ]]; then
        archive="$requested_archive"
    else
        archive="$PWD/$requested_archive"
    fi
    archive_dir="$(dirname "$archive")"
    mkdir -p "$archive_dir"
    archive_dir="$(cd "$archive_dir" && pwd)"
    archive="$archive_dir/$(basename "$archive")"

    for root in "${roots[@]}"; do
        root="$(cd "$root" && pwd)"
        case "$root/" in
            "$base_dir"/*) ;;
            *) die "edge root is outside BASE_DIR: $root" ;;
        esac
        while IFS= read -r -d '' replicate_archive; do
            replicate_archives+=("$replicate_archive")
            relative_path="${replicate_archive#"$base_dir"/}"
            tar -tzf "$replicate_archive" >/dev/null ||
                die "per-replicate energy archive is unreadable: $replicate_archive"
            archive_members+=("$relative_path")
        done < <(
            find "$root" -type f -name "$REPLICATE_ARCHIVE_NAME" -print0 |
                sort -z
        )
        while IFS= read -r -d '' qfep_output; do
            qfep_count=$((qfep_count + 1))
            relative_path="${qfep_output#"$base_dir"/}"
            expected_members+=("${relative_path%/qfep.out}/$REPLICATE_ARCHIVE_NAME")
        done < <(
            find "$root" -type f -name 'qfep.out' -print0
        )
    done

    if [[ -e "$archive" ]]; then
        if ! diff -q \
            <(printf '%s\n' "${expected_members[@]}" | sort) \
            <(tar -tf "$archive" | sort) >/dev/null; then
            die "existing edge archive does not match expected qfep outputs: $archive"
        fi
        for index in "${!replicate_archives[@]}"; do
            if ! tar -xOf "$archive" -- "${archive_members[$index]}" |
                cmp -s - "${replicate_archives[$index]}"; then
                die "existing edge archive copy differs from ${replicate_archives[$index]}"
            fi
        done
        printf 'Resuming cleanup from verified edge archive: %s\n' "$archive"
    else
        ((${#replicate_archives[@]})) || die "no per-replicate energy archives found"
        if ! diff -q \
            <(printf '%s\n' "${expected_members[@]}" | sort) \
            <(printf '%s\n' "${archive_members[@]}" | sort) >/dev/null; then
            die "expected $qfep_count replicate archives (one per qfep.out), found ${#replicate_archives[@]}"
        fi
        temporary="$(mktemp "$archive_dir/.$(basename "$archive").tmp.XXXXXX")"
        if ! tar -cf "$temporary" -C "$base_dir" -- "${archive_members[@]}"; then
            rm -f -- "$temporary"
            die "could not create edge energy archive: $archive"
        fi
        if ! tar -tf "$temporary" >/dev/null; then
            rm -f -- "$temporary"
            die "edge energy archive verification failed: $archive"
        fi
        if ! diff -q \
            <(printf '%s\n' "${archive_members[@]}" | sort) \
            <(tar -tf "$temporary" | sort) >/dev/null; then
            rm -f -- "$temporary"
            die "edge energy archive members are incorrect: $archive"
        fi
        mv -- "$temporary" "$archive"
    fi

    for replicate_archive in "${replicate_archives[@]}"; do
        rm -f -- "$replicate_archive"
    done
    printf 'Edge archive complete; removed %d remaining replicate archive(s): %s\n' "${#replicate_archives[@]}" "$archive"
}

archive_roots() {
    local root replicate_dir
    local replicate_dirs=()

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

main() {
    (($#)) || {
        usage >&2
        return 2
    }
    command -v tar >/dev/null 2>&1 || die "tar is required"
    command -v diff >/dev/null 2>&1 || die "diff is required"
    command -v cmp >/dev/null 2>&1 || die "cmp is required"

    case "$1" in
        -h|--help)
            usage
            ;;
        --replicate)
            [[ $# -eq 2 ]] || die "--replicate requires exactly one directory"
            [[ -d "$2" ]] || die "replicate directory does not exist: $2"
            archive_replicate "$2"
            ;;
        --edge)
            [[ $# -ge 4 ]] || die "--edge requires EDGE_ARCHIVE BASE_DIR and at least one ROOT"
            shift
            archive_edge "$@"
            ;;
        *)
            archive_roots "$@"
            ;;
    esac
}

main "$@"
