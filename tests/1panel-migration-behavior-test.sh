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

test_v2_edition_detection_from_database() {
    local tmp_dir
    local panel_dir

    tmp_dir=$(mktemp -d)
    TEST_TMP_DIRS+=("$tmp_dir")
    panel_dir="$tmp_dir/1panel"
    mkdir -p "$panel_dir/db"
    sqlite3 "$panel_dir/db/core.db" \
        "CREATE TABLE settings (key TEXT, value TEXT); INSERT INTO settings VALUES ('Edition', 'intl');"

    assert_eq "intl" "$(read_panel_edition_from_db v2 "$panel_dir")" \
        "V2 international edition should be detected from core.db"
}

test_v2_missing_edition_defaults_to_cn() {
    local tmp_dir
    local panel_dir

    tmp_dir=$(mktemp -d)
    TEST_TMP_DIRS+=("$tmp_dir")
    panel_dir="$tmp_dir/1panel"
    mkdir -p "$panel_dir/db"
    sqlite3 "$panel_dir/db/core.db" "CREATE TABLE settings (key TEXT, value TEXT);"

    assert_eq "cn" "$(resolve_panel_edition v2 "$panel_dir" /nonexistent/1pctl v2.1.1)" \
        "V2 installations before v2.1.2 should default to cn when Edition is missing"
}

test_v2_1_2_or_newer_missing_edition_requires_confirmation() {
    local tmp_dir
    local panel_dir

    tmp_dir=$(mktemp -d)
    TEST_TMP_DIRS+=("$tmp_dir")
    panel_dir="$tmp_dir/1panel"
    mkdir -p "$panel_dir/db"
    sqlite3 "$panel_dir/db/core.db" "CREATE TABLE settings (key TEXT, value TEXT);"

    if resolve_panel_edition v2 "$panel_dir" /nonexistent/1pctl v2.1.2 >/dev/null; then
        fail "V2.1.2 or newer without Edition should require explicit edition confirmation"
    fi
}

test_edition_download_source_mapping() {
    assert_eq "https://resource.fit2cloud.com/1panel/package/v2" \
        "$(panel_download_base v2 cn)" "V2 cn should use the Fit2Cloud package source"
    assert_eq "https://resource.1panel.pro/v2" \
        "$(panel_download_base v2 intl)" "V2 intl should use the international package source"
    assert_eq "https://resource.fit2cloud.com/1panel/package" \
        "$(panel_download_base v1 cn)" "V1 cn should use the Fit2Cloud package source"
    assert_eq "https://resource.1panel.pro" \
        "$(panel_download_base v1 intl)" "V1 intl should use the international package source"
}

test_panel_version_validation() {
    is_valid_panel_version "v2.2.3" || fail "a normal V2 version should be accepted"
    is_valid_panel_version "v1.10.34-lts" || fail "a V1 LTS version should be accepted"
    if is_valid_panel_version "../../latest"; then
        fail "path-like version values must be rejected"
    fi
}

test_moelin_image_tag_mapping() {
    assert_eq "moelin/1panel:v2.2.3" "$(moelin_image_tag v2 cn v2.2.3)" \
        "V2 cn should use the normal exact-version image"
    assert_eq "moelin/1panel:global-v2.2.3" "$(moelin_image_tag v2 intl v2.2.3)" \
        "V2 intl should use the global exact-version image"
    assert_eq "moelin/1panel:v2" "$(moelin_image_tag v2 cn)" \
        "V2 cn fallback should use the v2 alias"
    assert_eq "moelin/1panel:global-v2" "$(moelin_image_tag v2 intl)" \
        "V2 intl fallback should use the global-v2 alias"
    assert_eq "moelin/1panel:global-v1" "$(moelin_image_tag v1 intl)" \
        "V1 intl fallback should use the global-v1 alias"
}

test_default_image_prefers_exact_tag_when_available() {
    local actual

    actual=$(
        # shellcheck disable=SC2317
        docker_image_tag_exists() { return 0; }
        select_default_moelin_image v2 intl v2.2.3
    )

    assert_eq "moelin/1panel:global-v2.2.3" "$actual" \
        "an available exact international image should be preferred"
}

test_default_image_falls_back_to_edition_alias() {
    local actual

    actual=$(
        # shellcheck disable=SC2317
        docker_image_tag_exists() { return 1; }
        select_default_moelin_image v2 intl v2.1.2 2>/dev/null
    )

    assert_eq "moelin/1panel:global-v2" "$actual" \
        "a missing exact international image should fall back to the edition alias"
}

test_panel_edition_is_written_to_1pctl() {
    local tmp_dir
    local ctl_file

    tmp_dir=$(mktemp -d)
    TEST_TMP_DIRS+=("$tmp_dir")
    ctl_file="$tmp_dir/1pctl"
    printf 'PANEL_EDITION=cn\n' >"$ctl_file"

    sync_panel_edition_to_ctl "$ctl_file" "intl"

    assert_eq "PANEL_EDITION=intl" "$(sed -n '/^PANEL_EDITION=/p' "$ctl_file")" \
        "1pctl should retain the detected international edition"
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
test_v2_edition_detection_from_database
test_v2_missing_edition_defaults_to_cn
test_v2_1_2_or_newer_missing_edition_requires_confirmation
test_edition_download_source_mapping
test_panel_version_validation
test_moelin_image_tag_mapping
test_default_image_prefers_exact_tag_when_available
test_default_image_falls_back_to_edition_alias
test_panel_edition_is_written_to_1pctl
test_set_ctl_value_escapes_sed_replacement
test_apply_panel_permissions_keeps_sensitive_files_private
test_no_insecure_download_or_blanket_panel_chmod

echo "1Panel migration behavior tests passed"
