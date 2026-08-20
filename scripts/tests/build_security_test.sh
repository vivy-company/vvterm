#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Load the verification functions without running the build command.
source "${PROJECT_ROOT}/scripts/build.sh"

test_directory="$(mktemp -d /tmp/vvterm-build-security.XXXXXX)"
trap 'rm -rf "${test_directory}"' EXIT
fixture="${test_directory}/fixture"
printf 'trusted source\n' > "${fixture}"

verify_sha256 \
    "${fixture}" \
    "0d301983eb3192881964b7196c6d937eb821a3af1f60df8828563ad9599bb42e"

if verify_sha256 \
    "${fixture}" \
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" \
    >/dev/null 2>&1; then
    echo "Expected a mismatched archive hash to fail" >&2
    exit 1
fi

validate_git_commit "268a0a9d761fb19673f05d28042488e2002300f2"

if validate_git_commit "custom-io"; then
    echo "Expected a moving Git ref to fail" >&2
    exit 1
fi

echo "Native source verification tests passed"
