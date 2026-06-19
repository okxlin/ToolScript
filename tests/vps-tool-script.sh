#!/bin/bash

# vps-tool-script test suite
# Run: bash tests/vps-tool-script.sh

skip_if_not_run_by_ci_or_vps() {
    if [[ -z "${CI+x}" ]]; then
        if ! command -v ssh &>/dev/null; then
            echo "skip: not in CI and no ssh available"
            return 1
        fi
    fi
}

setup_vps_vars() {
    export VPS_SSH_HOST="test-vps.local"
    export VPS_SSH_PORT="22"
    export VPS_SSH_USER="root"
    export VPS_SSH_KEY="~/.ssh/id_rsa_test"
}

test_vps_tool_script_dry_run() {
    echo "TAP version 14"
    echo "1..1"
    if bash tools/vps-tool-script.sh --help &>/dev/null; then
        echo "ok 1 - vps-tool-script.sh dry run passes"
    else
        echo "not ok 1 - vps-tool-script.sh dry run fails"
    fi
}

test_vps_tool_script_with_sshin() {
    local result
    result=$(bash tools/vps-tool-script.sh --dry-run --sshin "/path/to/sshin" 2>&1)
    if echo "$result" | grep -q "dry-run"; then
        echo "ok 2 - with sshin flag works"
    else
        echo "not ok 2 - with sshin flag fails"
    fi
}

test_vps_tool_script_no_sshin() {
    local result
    result=$(bash tools/vps-tool-script.sh --dry-run 2>&1)
    if [[ "$?" -eq 0 ]]; then
        echo "ok 3 - without sshin works"
    else
        echo "not ok 3 - without sshin fails"
    fi
}

test_vps_tool_script_sshin_with_space() {
    local result
    result=$(bash tools/vps-tool-script.sh --dry-run --sshin "/path/with spaces/key" 2>&1)
    if echo "$result" | grep -q "dry-run"; then
        echo "ok 4 - sshin with space in path works"
    else
        echo "not ok 4 - sshin with space in path fails"
    fi
}

test_vps_tool_script_sshin_multi_line() {
    local result
    # Simulate multi-line sshin entries
    result=$(bash tools/vps-tool-script.sh --dry-run --sshin $/path/firstn/path/second 2>&1)
    if echo "$result" | grep -q "dry-run"; then
        echo "ok 5 - sshin multi-line works"
    else
        echo "not ok 5 - sshin multi-line fails"
    fi
}

# Run tests
test_vps_tool_script_dry_run
test_vps_tool_script_with_sshin
test_vps_tool_script_no_sshin
test_vps_tool_script_sshin_with_space
test_vps_tool_script_sshin_multi_line
