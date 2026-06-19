#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
SCRIPT_PATH="$REPO_ROOT/1Panel/1panel-execution-mode/1panel_docker_to_sys.sh"
TEST_TMP_DIRS=()

cleanup() {
    local tmp_dir

    for tmp_dir in "${TEST_TMP_DIRS[@]}"; do
        rm -rf "$tmp_dir"
    done
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    if [ "$expected" != "$actual" ]; then
        fail "$message: expected '$expected', got '$actual'"
    fi
}

mode_of() {
    stat -c '%a' "$1"
}

test_script_has_source_guard() {
    # shellcheck disable=SC2016
    grep -Fq '[[ "${BASH_SOURCE[0]}" == "$0" ]]' "$SCRIPT_PATH" ||
        fail "migration script should be sourceable without running main"
}

test_script_has_source_guard

# shellcheck source=../1Panel/1panel-execution-mode/1panel_docker_to_sys.sh
# shellcheck disable=SC1091
source "$SCRIPT_PATH"

test_dependency_package_mapping() {
    assert_eq "docker.io" "$(package_name_for_dependency apt docker)" \
        "apt should install Docker Engine from docker.io, not the unrelated docker package"
    assert_eq "gawk" "$(package_name_for_dependency apt awk)" \
        "apt should install gawk if the awk command is missing"
    assert_eq "sqlite" "$(package_name_for_dependency dnf sqlite3)" \
        "dnf should install sqlite for the sqlite3 command"
    assert_eq "sqlite" "$(package_name_for_dependency yum sqlite3)" \
        "yum should install sqlite for the sqlite3 command"
    assert_eq "sqlite" "$(package_name_for_dependency apk sqlite3)" \
        "apk should install sqlite for the sqlite3 command"
    assert_eq "gawk" "$(package_name_for_dependency apk awk)" \
        "apk should install gawk if the awk command is missing"
}

test_set_ctl_value_escapes_sed_replacement() {
    local tmp_dir
    local ctl_file
    local wanted
    local actual

    tmp_dir=$(mktemp -d)
    TEST_TMP_DIRS+=("$tmp_dir")
    ctl_file="$tmp_dir/1pctl"
    wanted='/opt/a&b#c\d'
    printf 'BASE_DIR=old\nORIGINAL_ENTRANCE=old\n' >"$ctl_file"

    set_ctl_value "$ctl_file" "BASE_DIR" "$wanted"

    actual=$(sed -n 's/^BASE_DIR=//p' "$ctl_file")
    assert_eq "$wanted" "$actual" "1pctl replacement values should survive &, # and backslashes"
}

test_apply_panel_permissions_keeps_sensitive_files_private() {
    local tmp_dir
    local panel_dir

    tmp_dir=$(mktemp -d)
    TEST_TMP_DIRS+=("$tmp_dir")
    panel_dir="$tmp_dir/1panel"
    mkdir -p "$panel_dir/db" "$panel_dir/tmp" "$panel_dir/ssl"
    touch "$panel_dir/db/core.db" "$panel_dir/db/core.db-wal" "$panel_dir/db/core.db-shm"
    touch "$panel_dir/tmp/.secret" "$panel_dir/ssl/site.key" "$panel_dir/public.txt"
    chmod 640 "$panel_dir/public.txt"

    PANEL_DIR="$panel_dir" apply_panel_permissions

    assert_eq "600" "$(mode_of "$panel_dir/db/core.db")" "database files should be private"
    assert_eq "600" "$(mode_of "$panel_dir/db/core.db-wal")" "WAL files should be private"
    assert_eq "600" "$(mode_of "$panel_dir/db/core.db-shm")" "SHM files should be private"
    assert_eq "600" "$(mode_of "$panel_dir/tmp/.secret")" "1Panel secret should be private"
    assert_eq "600" "$(mode_of "$panel_dir/ssl/site.key")" "private key files should be private"
    assert_eq "640" "$(mode_of "$panel_dir/public.txt")" "ordinary files should not be broadened"
}

test_no_insecure_download_or_blanket_panel_chmod() {
    if grep -nE 'curl .*-([^ ]*)k|curl .*--insecure|--no-check-certificate' "$SCRIPT_PATH"; then
        fail "migration script should not disable TLS verification"
    fi

    if grep -nE 'chmod[[:space:]]+-R[[:space:]]+755[[:space:]]+.*PANEL_DIR' "$SCRIPT_PATH"; then
        fail "migration script should not chmod the whole panel data directory to 755"
    fi
}

test_dependency_package_mapping
test_set_ctl_value_escapes_sed_replacement
test_apply_panel_permissions_keeps_sensitive_files_private
test_no_insecure_download_or_blanket_panel_chmod

echo "1Panel migration behavior tests passed"
