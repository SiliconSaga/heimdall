#!/usr/bin/env bash
# test.sh — Run kuttl tests via Docker on Windows (Rancher Desktop / k3d)
#
# Usage: bash test.sh [kuttl-args...]
#   bash test.sh                    # run all tests
#   bash test.sh --test stack-deploys  # run one test suite
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Preparing kubeconfig for Docker..."

# Flatten current kubeconfig, swap localhost for host.docker.internal,
# and skip TLS verify (local cluster self-signed certs)
TEMP_KUBECONFIG=$(mktemp)
kubectl config view --minify --flatten \
  | sed 's/127\.0\.0\.1/host.docker.internal/g' \
  | sed 's/localhost/host.docker.internal/g' \
  | sed 's/certificate-authority-data:.*/insecure-skip-tls-verify: true/' \
  > "$TEMP_KUBECONFIG"

cleanup() { rm -f "$TEMP_KUBECONFIG"; }
trap cleanup EXIT

echo "Running kuttl via Docker..."

# Convert Git Bash paths to Windows paths for Docker volume mounts,
# then use MSYS_NO_PATHCONV to prevent mangling of container-side paths.
DOCKER_SCRIPT_DIR="$(cygpath -w "$SCRIPT_DIR" 2>/dev/null || echo "$SCRIPT_DIR")"
DOCKER_KUBECONFIG="$(cygpath -w "$TEMP_KUBECONFIG" 2>/dev/null || echo "$TEMP_KUBECONFIG")"

MSYS_NO_PATHCONV=1 docker run --rm \
  -v "$DOCKER_KUBECONFIG:/kubeconfig" \
  -v "$DOCKER_SCRIPT_DIR:/workspace" \
  -e KUBECONFIG=/kubeconfig \
  --add-host host.docker.internal:host-gateway \
  --entrypoint /bin/sh \
  kudobuilder/kuttl:latest \
  -c "mkdir -p /tmp/work \
    && cp /workspace/kuttl-test.yaml /tmp/work/ \
    && ln -s /workspace/tests /tmp/work/tests \
    && cd /tmp/work \
    && kubectl-kuttl test --config kuttl-test.yaml $*"
