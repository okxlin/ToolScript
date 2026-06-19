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

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"

    grep -Fq -- "$needle" <<<"$haystack" || fail "$message"
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"

    if grep -Fq -- "$needle" <<<"$haystack"; then
        fail "$message"
    fi
}

test_legacy_bbr_instructions_are_manual_and_guarded() {
    local output

    output=$(print_legacy_bbr_instructions)

    assert_contains "$output" "teddysun/across" "legacy BBR instructions should reference teddysun/across"
    assert_contains "$output" "sha256sum /opt/bbr.sh" "legacy BBR instructions should ask for a checksum"
    assert_contains "$output" "less /opt/bbr.sh" "legacy BBR instructions should ask the user to inspect the script"
    assert_contains "$output" "bash /opt/bbr.sh" "legacy BBR instructions should include a manual run command"
    assert_not_contains "$output" "--no-check-certificate" "legacy BBR instructions must not disable TLS checks"
    assert_not_contains "$output" "bash <(" "legacy BBR instructions must not pipe remote code directly to bash"
}

test_legacy_docker_compose_command_created_from_plugin() {
    local tmp_dir
    local fake_bin
    local wrapper
    local symlink

    tmp_dir=$(mktemp -d)
    TEST_TMP_DIRS+=("$tmp_dir")
    fake_bin="$tmp_dir/bin"
    wrapper="$tmp_dir/usr/local/bin/docker-compose"
    symlink="$tmp_dir/usr/bin/docker-compose"
    mkdir -p "$fake_bin"

    cat >"$fake_bin/docker" <<'EOF'
#!/bin/sh
if [ "$1" = "compose" ] && [ "$2" = "version" ]; then
    exit 0
fi
if [ "$1" = "compose" ]; then
    exit 0
fi
exit 1
EOF
    chmod +x "$fake_bin/docker"

    PATH="$fake_bin:/usr/bin:/bin" \
    DOCKER_COMPOSE_WRAPPER="$wrapper" \
    DOCKER_COMPOSE_LEGACY_SYMLINK="$symlink" \
        ensure_legacy_docker_compose_command

    [ -x "$wrapper" ] || fail "docker compose plugin should create an executable docker-compose wrapper"
    [ -L "$symlink" ] || fail "docker compose plugin should create a /usr/bin compatible symlink"
    PATH="$fake_bin:/usr/bin:/bin" "$wrapper" version >/dev/null || fail "docker-compose wrapper should delegate to docker compose"
}

test_no_insecure_tls_flags_in_setup_scripts() {
    if grep -n -- '--insecure\|--no-check-certificate' \
        "$REPO_ROOT/tools/timesync.sh" \
        "$REPO_ROOT/tools/vps-setup.sh"; then
        fail "setup scripts should not disable TLS certificate verification"
    fi
}

test_legacy_bbr_instructions_are_manual_and_guarded
test_legacy_docker_compose_command_created_from_plugin
test_no_insecure_tls_flags_in_setup_scripts

echo "vps-setup behavior tests passed"
