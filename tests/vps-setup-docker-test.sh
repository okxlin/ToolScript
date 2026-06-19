#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
TEST_TMP_DIRS=()

cleanup() {
    local tmp_dir

    for tmp_dir in "${TEST_TMP_DIRS[@]}"; do
        rm -rf "$tmp_dir"
    done
}
trap cleanup EXIT

# shellcheck source=../tools/vps-setup.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/tools/vps-setup.sh"

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

assert_jq() {
    local filter="$1"
    local file="$2"
    local message="$3"

    jq -e "$filter" "$file" >/dev/null || fail "$message"
}

with_os_release() {
    local content="$1"
    local tmp_dir

    tmp_dir=$(mktemp -d)
    TEST_TMP_DIRS+=("$tmp_dir")
    printf '%s\n' "$content" >"$tmp_dir/os-release"
    OS_RELEASE_FILE="$tmp_dir/os-release"
    export OS_RELEASE_FILE
}

test_docker_ce_source_override_is_first() {
    local first

    first=$(DOCKER_CE_SOURCE="mirrors.huaweicloud.com/docker-ce" docker_repo_sources | sed -n '1p')

    assert_eq "https://mirrors.huaweicloud.com/docker-ce" "$first" \
        "DOCKER_CE_SOURCE should be normalized and tried first"
}

test_docker_ce_source_rejects_unsafe_value() {
    if DOCKER_CE_SOURCE="mirrors.example.com/docker-ce bad" docker_repo_sources >/dev/null 2>&1; then
        fail "DOCKER_CE_SOURCE should reject values with spaces"
    fi
}

test_linux_mint_uses_ubuntu_codename() {
    with_os_release 'ID=linuxmint
NAME="Linux Mint"
ID_LIKE="ubuntu debian"
VERSION_CODENAME=virginia
UBUNTU_CODENAME=jammy'

    assert_eq "ubuntu" "$(docker_apt_os)" "Linux Mint should use the Ubuntu Docker CE branch"
    assert_eq "jammy" "$(docker_apt_codename)" "Linux Mint should use UBUNTU_CODENAME"
}

test_kali_maps_to_debian_stable_codename() {
    with_os_release 'ID=kali
NAME="Kali GNU/Linux"
ID_LIKE=debian
VERSION_CODENAME=kali-rolling'

    assert_eq "debian" "$(docker_apt_os)" "Kali should use the Debian Docker CE branch"
    assert_eq "trixie" "$(docker_apt_codename)" "Kali rolling should use a supported Debian codename"
}

test_registry_mirror_creates_daemon_json() {
    local tmp_dir

    tmp_dir=$(mktemp -d)
    TEST_TMP_DIRS+=("$tmp_dir")
    DOCKER_DAEMON_JSON="$tmp_dir/daemon.json" \
    DOCKER_REGISTRY_MIRROR="docker.1ms.run,docker.m.daocloud.io" \
        configure_docker_registry_mirror

    assert_jq '.["registry-mirrors"] == ["https://docker.1ms.run","https://docker.m.daocloud.io"]' \
        "$tmp_dir/daemon.json" "registry mirrors should be written as a JSON array"
}

test_registry_mirror_blank_setting_is_noop() {
    local tmp_dir

    tmp_dir=$(mktemp -d)
    TEST_TMP_DIRS+=("$tmp_dir")
    DOCKER_DAEMON_JSON="$tmp_dir/daemon.json" \
    DOCKER_REGISTRY_MIRROR="   " \
        configure_docker_registry_mirror

    [ ! -e "$tmp_dir/daemon.json" ] || fail "blank registry mirror setting should not create daemon.json"
}

test_registry_mirror_preserves_existing_config() {
    local tmp_dir

    tmp_dir=$(mktemp -d)
    TEST_TMP_DIRS+=("$tmp_dir")
    printf '{"log-driver":"json-file"}\n' >"$tmp_dir/daemon.json"

    DOCKER_DAEMON_JSON="$tmp_dir/daemon.json" \
    DOCKER_REGISTRY_MIRROR="https://docker.1panel.live/" \
        configure_docker_registry_mirror

    assert_jq '.["log-driver"] == "json-file"' "$tmp_dir/daemon.json" \
        "existing daemon.json keys should be preserved"
    assert_jq '.["registry-mirrors"] == ["https://docker.1panel.live"]' "$tmp_dir/daemon.json" \
        "registry mirror should be normalized before writing"
    [ -f "$tmp_dir/daemon.json.bak" ] || fail "existing daemon.json should be backed up"
}

test_registry_mirror_official_removes_config_key() {
    local tmp_dir

    tmp_dir=$(mktemp -d)
    TEST_TMP_DIRS+=("$tmp_dir")
    printf '{"log-driver":"json-file","registry-mirrors":["https://docker.1ms.run"]}\n' >"$tmp_dir/daemon.json"

    DOCKER_DAEMON_JSON="$tmp_dir/daemon.json" \
    DOCKER_REGISTRY_MIRROR="registry.hub.docker.com" \
        configure_docker_registry_mirror

    assert_jq 'has("registry-mirrors") | not' "$tmp_dir/daemon.json" \
        "official Docker Hub should remove registry-mirrors"
    assert_jq '.["log-driver"] == "json-file"' "$tmp_dir/daemon.json" \
        "other daemon.json keys should remain"
}

test_docker_ce_source_override_is_first
test_docker_ce_source_rejects_unsafe_value
test_linux_mint_uses_ubuntu_codename
test_kali_maps_to_debian_stable_codename
test_registry_mirror_creates_daemon_json
test_registry_mirror_blank_setting_is_noop
test_registry_mirror_preserves_existing_config
test_registry_mirror_official_removes_config_key

echo "vps-setup Docker tests passed"
