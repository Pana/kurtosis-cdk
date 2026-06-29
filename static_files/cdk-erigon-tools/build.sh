#!/bin/bash
# Build smt-genesis inside a Debian bookworm container so the resulting
# binary is dynamically linked against the older glibc that ships in
# kurtosis-cdk's agglayer-contracts image (node:22-bookworm, glibc 2.36).
#
# The binary must run inside the contracts container during
# `run-create-agglayer-rollup.sh` to pre-compute the SMT genesis root that
# is then written into L1 batchNumToStateRoot[0]. See
# doc-report/fix-plan-invalidProof.md for context.
#
# Usage:
#   ./build.sh
#
# Output:
#   ../kurtosis-cdk/static_files/cdk-erigon-tools/smt-genesis

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Layout:
#   $SCRIPT_DIR                       -> kurtosis-cdk/static_files/cdk-erigon-tools/
#   $SCRIPT_DIR/../../../cdk-erigon   -> cdk-erigon repo (the source we build from)
ERIGON_DIR="$(cd "$SCRIPT_DIR/../../../cdk-erigon" && pwd)"
OUT_FILE="$SCRIPT_DIR/smt-genesis"

echo "==> Building smt-genesis inside node:22-bookworm (matches contracts container)"

docker run --rm \
    -v "$ERIGON_DIR:/src" \
    -w /src \
    node:22-bookworm \
    bash -c '
        set -euo pipefail
        apt-get update >/dev/null 2>&1
        apt-get install -y --no-install-recommends \
            gcc libc6-dev ca-certificates curl git >/dev/null 2>&1
        if ! command -v go >/dev/null; then
            curl -fsSL https://go.dev/dl/go1.23.4.linux-amd64.tar.gz -o /tmp/go.tgz
            tar -C /usr/local -xzf /tmp/go.tgz
        fi
        export PATH=/usr/local/go/bin:$PATH
        CGO_ENABLED=1 GOFLAGS="-mod=mod" \
            /usr/local/go/bin/go build -buildvcs=false \
                -tags "nosqlite,noboltdb" \
                -o /src/cmd/read-smt-genesis/smt-genesis-bookworm \
                ./cmd/read-smt-genesis/
    '

cp "$ERIGON_DIR/cmd/read-smt-genesis/smt-genesis-bookworm" "$OUT_FILE"
rm -f "$ERIGON_DIR/cmd/read-smt-genesis/smt-genesis-bookworm"
chmod +x "$OUT_FILE"

echo "==> Built: $OUT_FILE"
ls -la "$OUT_FILE"
file "$OUT_FILE"
echo
echo "==> Smoke test (should print a 0x-prefixed 32-byte root):"
"$OUT_FILE" --alloc "$ERIGON_DIR/core/allocs/hermez-etrog.json" 2>/dev/null
