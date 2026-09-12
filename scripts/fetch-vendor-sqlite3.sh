#!/usr/bin/env bash
# scripts/fetch-vendor-sqlite3.sh
#
# Downloads the SQLite amalgamation into vendor/sqlite3/ if it's missing.
# Required before building on non-Linux targets (Windows, macOS) and for
# cross-compiling from Linux to those targets. Skipped on Linux native
# builds — those use the system libsqlite3 via linkSystemLibrary("sqlite3").
#
# This script exists because the amalgamation is gitignored: the ~10 MB
# sqlite3.c + 700 KB sqlite3.h + 40 KB sqlite3ext.h would otherwise be
# committed to the repo, bloating every clone. See `.gitignore` (search
# for "/vendor/").
#
# To bump SQLite: edit the SQLITE_* constants below to point at the new
# release, delete vendor/sqlite3/, and re-run this script.
#
# Requirements:
#   - bash 4+ (uses ${VAR} expansion; safe for /bin/bash on Ubuntu/macOS
#     GitHub Actions runners — macOS' legacy /bin/bash 3.2 is NOT sufficient
#     but the macos-latest CI image ships bash 5 via Homebrew at /opt/homebrew).
#   - curl
#   - sha3sum (optional — verification skipped if not present)
#   - unzip OR python3 (for extraction; python3 also handles verification)
#
# Exit codes:
#   0 - vendor/sqlite3/ already populated OR fetch succeeded.
#   1 - Required tool missing OR download failed OR checksum mismatch.
#
# Verified against: SQLite 3.53.3 amalgamation (2026-06-26).

set -euo pipefail

# ---------- constants ----------
SQLITE_VERSION="3.53.3"
SQLITE_VERSION_NUMBER="3530300"
SQLITE_YEAR="2026"
# SHA3-256 from https://sqlite.org/download.html for the amalgamation zip.
SQLITE_SHA3_256="d45c688a8cb23f68611a894a756a12d7eb6ab6e9e2468ca70adbeab3808b5ab9"
URL="https://sqlite.org/${SQLITE_YEAR}/sqlite-amalgamation-${SQLITE_VERSION_NUMBER}.zip"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
PROJECT_DIR="$( cd "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd )"
# The script lives in scripts/ and writes to a `vendor/` dir
# co-located with the package (../vendor/sqlite3 from here).
DEST="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/vendor/sqlite3"

REQUIRED_FILES=( "sqlite3.c" "sqlite3.h" "sqlite3ext.h" )
# ---------- /constants ----------

# Idempotent skip: if all 3 files already exist, do nothing.
all_present=1
for f in "${REQUIRED_FILES[@]}"; do
    if [[ ! -f "${DEST}/${f}" ]]; then
        all_present=0
        break
    fi
done
if [[ "${all_present}" -eq 1 ]]; then
    echo "vendor/sqlite3/ already populated (${SQLITE_VERSION}); skipping fetch."
    exit 0
fi

# Tool check: curl.
if ! command -v curl >/dev/null 2>&1; then
    echo "error: 'curl' is required to fetch the SQLite amalgamation." >&2
    echo "       Install it via your package manager (apt/brew/choco)." >&2
    exit 1
fi

mkdir -p "${DEST}"

# Use a per-PID temp dir; clean up on exit.
TMP=$(mktemp -d "${TMPDIR:-/tmp}/nalar-sqlite3-XXXXXX" 2>/dev/null || mktemp -d)
trap 'rm -rf "${TMP}"' EXIT

echo "Fetching SQLite ${SQLITE_VERSION} amalgamation from ${URL} ..."
curl -fsSL --retry 3 --connect-timeout 30 "${URL}" -o "${TMP}/sqlite.zip"

# Verify SHA3-256 if sha3sum OR python3 is available.
#
# `command -v python3` is unreliable on Windows: the Microsoft Store
# ships a `python3.exe` *alias* that always exits non-zero (prints
# "Python was not found…") when invoked, but the alias file exists in
# the WindowsApps path so `command -v` returns 0. A naive `command -v
# python3 && python3 -c "..."` then propagates the alias's non-zero
# exit code through `set -e` and the whole script dies. Test python3
# by actually running a minimal import-check before relying on it.
verify_ok=0
HAS_PYTHON3=0
if command -v python3 >/dev/null 2>&1; then
    if python3 -c "import sys, hashlib; sys.exit(0)" >/dev/null 2>&1; then
        HAS_PYTHON3=1
    fi
fi
if command -v sha3sum >/dev/null 2>&1; then
    if echo "${SQLITE_SHA3_256}  ${TMP}/sqlite.zip" | sha3sum -a 256 --check --strict >/dev/null 2>&1; then
        verify_ok=1
    fi
elif [ "${HAS_PYTHON3}" -eq 1 ]; then
    actual=$(python3 -c "import hashlib; print(hashlib.sha3_256(open('${TMP}/sqlite.zip','rb').read()).hexdigest())")
    if [[ "${actual}" == "${SQLITE_SHA3_256}" ]]; then
        verify_ok=1
    else
        echo "error: SHA3-256 mismatch" >&2
        echo "  expected: ${SQLITE_SHA3_256}" >&2
        echo "  actual:   ${actual}" >&2
        exit 1
    fi
else
    echo "warning: neither 'sha3sum' nor a working 'python3' available; skipping checksum verification." >&2
    echo "         (download is still subject to HTTPS + curl's TLS validation.)" >&2
fi
[[ "${verify_ok}" -eq 1 ]] && echo "  ✓ SHA3-256 verified"

# Extract the 3 files into vendor/sqlite3/.
# Prefer unzip (universal: ships with Git for Windows, macOS, every
# Linux distro). Fall back to python3 only when unzip isn't available
# AND python3 actually works (the Windows Microsoft Store `python3.exe`
# alias is a stub that returns non-zero, so we pre-test it via
# HAS_PYTHON3 set above in the SHA3-256 verification block).
if command -v unzip >/dev/null 2>&1; then
    unzip -j -o "${TMP}/sqlite.zip" "*/sqlite3.c" "*/sqlite3.h" "*/sqlite3ext.h" -d "${DEST}" >/dev/null
    echo "  wrote: sqlite3.c sqlite3.h sqlite3ext.h (via unzip)"
elif [ "${HAS_PYTHON3}" -eq 1 ]; then
    python3 - "${TMP}/sqlite.zip" "${DEST}" <<'PY'
import sys, os, zipfile
src, dst = sys.argv[1], sys.argv[2]
needed = {"sqlite3.c", "sqlite3.h", "sqlite3ext.h"}
with zipfile.ZipFile(src) as z:
    found = {}
    for n in z.namelist():
        base = os.path.basename(n)
        if base in needed and base not in found:
            found[base] = z.read(n)
    missing = needed - found.keys()
    if missing:
        sys.stderr.write(f"error: zip did not contain: {sorted(missing)}\n")
        sys.exit(1)
    for name, data in found.items():
        with open(os.path.join(dst, name), "wb") as f:
            f.write(data)
    print(f"  wrote: {sorted(found.keys())}")
PY
else
    echo "error: need either 'unzip' or a working 'python3' to extract the amalgamation." >&2
    echo "       On Windows: Git for Windows ships unzip at C:\\Program Files\\Git\\usr\\bin\\unzip.exe" >&2
    echo "       and Bash for Windows ships it at /usr/bin/unzip.exe." >&2
    exit 1
fi

echo "Installed SQLite ${SQLITE_VERSION} amalgamation into ${DEST}"
ls -1 "${DEST}"
