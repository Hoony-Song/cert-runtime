#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: package-runtime-bundle.sh [--version <version>] [--output-dir <dir>]

Create a cert-runtime tarball that can be extracted under /var/lib/cka.
USAGE
}

VERSION="v$(date -u +%Y%m%d%H%M%S)"
OUTPUT_DIR="dist"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${VERSION}" ]]; then
  echo "--version must not be empty" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "${REPO_ROOT}/${OUTPUT_DIR}"

ARCHIVE_NAME="cert-runtime-${VERSION}.tar.gz"
ARCHIVE_PATH="${REPO_ROOT}/${OUTPUT_DIR}/${ARCHIVE_NAME}"
SHA_PATH="${ARCHIVE_PATH}.sha256"

tar -C "${REPO_ROOT}" \
  --exclude='s3.env' \
  --exclude='.git' \
  --exclude='.venv' \
  --exclude='venv' \
  --exclude='dist' \
  --exclude='__pycache__' \
  --exclude='*.pyc' \
  --exclude='*.qcow2' \
  --exclude='*.iso' \
  -czf "${ARCHIVE_PATH}" \
  README.md \
  LICENSE \
  ansible \
  bastion \
  cloud-init \
  docs \
  runtime

(
  cd "${REPO_ROOT}/${OUTPUT_DIR}"
  sha256sum "${ARCHIVE_NAME}" > "${ARCHIVE_NAME}.sha256"
)

printf 'archive=%s\n' "${ARCHIVE_PATH}"
printf 'sha256=%s\n' "${SHA_PATH}"
