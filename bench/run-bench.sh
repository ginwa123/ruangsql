#!/usr/bin/env bash
# Build and run the ruangsql sqlite benchmark inside a podman container with
# pinned resources, so the numbers are comparable across runs and hosts.
#
# Usage: bench/run-bench.sh [output-dir]
#
# Pinned specs (the whole point of the container):
#   --cpus=2            2 CPU cores of quota
#   --memory=2g         hard memory ceiling
#   --memory-swap=2g    no swap, so the ceiling is real
#   --ulimit nofile=1024  matches the host default; the reader pool derives
#                       its fd budget from RLIMIT_NOFILE, so pinning this
#                       pins the pool's ceiling too
#   --tmpfs /tmp        the benchmark's DB lives on tmpfs
set -euo pipefail

cd "$(dirname "$0")/.."

OUT_DIR="${1:-bench/results}"
mkdir -p "$OUT_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_FILE="$OUT_DIR/bench-$STAMP.json"

echo "==> building benchmark binary (ReleaseSafe)"
zig build install -Doptimize=ReleaseSafe
test -x zig-out/bin/bench

echo "==> building image"
podman build -f bench/Containerfile -t ruangsql-bench .

echo "==> running benchmark (2 cpu / 2g / nofile=1024)"
podman run --rm \
    --cpus=2 \
    --memory=2g \
    --memory-swap=2g \
    --ulimit nofile=1024 \
    --tmpfs /tmp:rw,size=512m,mode=1777 \
    ruangsql-bench | tee "$OUT_FILE"

echo "==> wrote $OUT_FILE"
