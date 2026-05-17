#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: publish-runtime-artifacts.sh [options]

Options:
  --version <version>        Artifact version. Default: vYYYYmmddHHMMSS UTC.
  --env-file <path>          R2 credential env file. Default: s3.env.
  --output-dir <dir>         Local output dir. Default: dist.
  --image <path>             Optional golden image qcow2 or qcow2.zst to publish.
  --question-bank-root <dir> Optional question-bank root to publish.
  --cri-dockerd-deb <path>   Optional Q017 cri-dockerd deb asset to publish.
  --public-base-url <url>    Public artifact base URL. Default: https://artifacts.sweetlabs.kr.

The script publishes:
  runtime/installer/install.sh
  runtime/bundles/cert-runtime-<version>.tar.gz
  runtime/bundles/cert-runtime-<version>.tar.gz.sha256
  runtime/images/<image-name>-<version>.<ext>      when --image is provided
  runtime/images/<image-name>-<version>.<ext>.sha256
  runtime/question-bank/cert-question-bank-<version>.tar.gz when --question-bank-root is provided
  runtime/question-bank/cert-question-bank-<version>.tar.gz.sha256
  runtime/assets/<deb-name> when --cri-dockerd-deb is provided
  runtime/assets/<deb-name>.sha256
  runtime/manifests/runtime-node-<version>.json
USAGE
}

VERSION="v$(date -u +%Y%m%d%H%M%S)"
ENV_FILE="s3.env"
OUTPUT_DIR="dist"
IMAGE_PATH=""
QUESTION_BANK_ROOT=""
CRI_DOCKERD_DEB=""
PUBLIC_BASE_URL="https://artifacts.sweetlabs.kr"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --env-file)
      ENV_FILE="${2:-}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --image)
      IMAGE_PATH="${2:-}"
      shift 2
      ;;
    --question-bank-root)
      QUESTION_BANK_ROOT="${2:-}"
      shift 2
      ;;
    --cri-dockerd-deb)
      CRI_DOCKERD_DEB="${2:-}"
      shift 2
      ;;
    --public-base-url)
      PUBLIC_BASE_URL="${2:-}"
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
ENV_FILE_ABS="$(cd "${REPO_ROOT}" && realpath "${ENV_FILE}")"
DIST_DIR="${REPO_ROOT}/${OUTPUT_DIR}"
mkdir -p "${DIST_DIR}"

INSTALLER_PATH="${REPO_ROOT}/scripts/install-runtime-node.sh"
INSTALLER_KEY="runtime/installer/install.sh"
if [[ ! -f "${INSTALLER_PATH}" ]]; then
  echo "runtime node installer not found: ${INSTALLER_PATH}" >&2
  exit 1
fi
python3 "${REPO_ROOT}/scripts/r2_object.py" --env-file "${ENV_FILE_ABS}" put --file "${INSTALLER_PATH}" --key "${INSTALLER_KEY}" --content-type text/x-shellscript >/dev/null

"${REPO_ROOT}/scripts/package-runtime-bundle.sh" --version "${VERSION}" --output-dir "${OUTPUT_DIR}" >/dev/null

BUNDLE_NAME="cert-runtime-${VERSION}.tar.gz"
BUNDLE_PATH="${DIST_DIR}/${BUNDLE_NAME}"
BUNDLE_SHA_PATH="${BUNDLE_PATH}.sha256"
BUNDLE_SHA="$(awk '{print $1}' "${BUNDLE_SHA_PATH}")"
BUNDLE_SIZE="$(stat -c '%s' "${BUNDLE_PATH}")"
BUNDLE_KEY="runtime/bundles/${BUNDLE_NAME}"
BUNDLE_SHA_KEY="${BUNDLE_KEY}.sha256"

python3 "${REPO_ROOT}/scripts/r2_object.py" --env-file "${ENV_FILE_ABS}" put --file "${BUNDLE_PATH}" --key "${BUNDLE_KEY}" --content-type application/gzip >/dev/null
python3 "${REPO_ROOT}/scripts/r2_object.py" --env-file "${ENV_FILE_ABS}" put --file "${BUNDLE_SHA_PATH}" --key "${BUNDLE_SHA_KEY}" --content-type text/plain >/dev/null

GOLDEN_JSON="null"
if [[ -n "${IMAGE_PATH}" ]]; then
  IMAGE_ABS="$(realpath "${IMAGE_PATH}")"
  if [[ ! -f "${IMAGE_ABS}" ]]; then
    echo "golden image not found: ${IMAGE_PATH}" >&2
    exit 2
  fi
  IMAGE_BASENAME="$(basename "${IMAGE_ABS}")"
  IMAGE_OUTPUT_NAME="${IMAGE_BASENAME}"
  IMAGE_SOURCE="${IMAGE_ABS}"
  IMAGE_CANONICAL_NAME="${IMAGE_BASENAME%.zst}"
  IMAGE_FAMILY_NAME="${IMAGE_CANONICAL_NAME%.qcow2}"
  IMAGE_INSTALL_PATH="/var/lib/cka/images/base/${IMAGE_FAMILY_NAME}/${IMAGE_CANONICAL_NAME}"
  if [[ "${IMAGE_BASENAME}" != *.zst ]]; then
    IMAGE_OUTPUT_NAME="${IMAGE_BASENAME}.zst"
    IMAGE_SOURCE="${DIST_DIR}/${IMAGE_OUTPUT_NAME}"
    zstd -T0 -19 -f "${IMAGE_ABS}" -o "${IMAGE_SOURCE}"
  fi
  IMAGE_VERSIONED_NAME="${IMAGE_OUTPUT_NAME%.*}-${VERSION}.${IMAGE_OUTPUT_NAME##*.}"
  if [[ "${IMAGE_OUTPUT_NAME}" == *.qcow2.zst ]]; then
    IMAGE_VERSIONED_NAME="${IMAGE_OUTPUT_NAME%.qcow2.zst}-${VERSION}.qcow2.zst"
  fi
  IMAGE_VERSIONED_PATH="${DIST_DIR}/${IMAGE_VERSIONED_NAME}"
  cp "${IMAGE_SOURCE}" "${IMAGE_VERSIONED_PATH}"
  (
    cd "${DIST_DIR}"
    sha256sum "${IMAGE_VERSIONED_NAME}" > "${IMAGE_VERSIONED_NAME}.sha256"
  )
  IMAGE_SHA_PATH="${IMAGE_VERSIONED_PATH}.sha256"
  IMAGE_SHA="$(awk '{print $1}' "${IMAGE_SHA_PATH}")"
  IMAGE_SIZE="$(stat -c '%s' "${IMAGE_VERSIONED_PATH}")"
  IMAGE_KEY="runtime/images/${IMAGE_VERSIONED_NAME}"
  IMAGE_SHA_KEY="${IMAGE_KEY}.sha256"
  python3 "${REPO_ROOT}/scripts/r2_object.py" --env-file "${ENV_FILE_ABS}" put --file "${IMAGE_VERSIONED_PATH}" --key "${IMAGE_KEY}" --content-type application/zstd >/dev/null
  python3 "${REPO_ROOT}/scripts/r2_object.py" --env-file "${ENV_FILE_ABS}" put --file "${IMAGE_SHA_PATH}" --key "${IMAGE_SHA_KEY}" --content-type text/plain >/dev/null
  GOLDEN_JSON="$(python3 - <<PY
import json
base = ${PUBLIC_BASE_URL@Q}.rstrip("/")
print(json.dumps({
    "key": ${IMAGE_KEY@Q},
    "url": base + "/" + ${IMAGE_KEY@Q},
    "sha256": ${IMAGE_SHA@Q},
    "sizeBytes": int(${IMAGE_SIZE@Q}),
    "compression": "zstd",
    "installPath": ${IMAGE_INSTALL_PATH@Q},
}))
PY
)"
fi

QUESTION_BANK_JSON="null"
if [[ -n "${QUESTION_BANK_ROOT}" ]]; then
  QUESTION_BANK_ABS="$(realpath "${QUESTION_BANK_ROOT}")"
  if [[ ! -d "${QUESTION_BANK_ABS}" ]]; then
    echo "question bank root not found: ${QUESTION_BANK_ROOT}" >&2
    exit 2
  fi
  QUESTION_BANK_NAME="cert-question-bank-${VERSION}.tar.gz"
  QUESTION_BANK_PATH="${DIST_DIR}/${QUESTION_BANK_NAME}"
  tar -C "${QUESTION_BANK_ABS}" \
    --exclude='.git' \
    --exclude='.DS_Store' \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    -czf "${QUESTION_BANK_PATH}" \
    .
  (
    cd "${DIST_DIR}"
    sha256sum "${QUESTION_BANK_NAME}" > "${QUESTION_BANK_NAME}.sha256"
  )
  QUESTION_BANK_SHA_PATH="${QUESTION_BANK_PATH}.sha256"
  QUESTION_BANK_SHA="$(awk '{print $1}' "${QUESTION_BANK_SHA_PATH}")"
  QUESTION_BANK_SIZE="$(stat -c '%s' "${QUESTION_BANK_PATH}")"
  QUESTION_BANK_KEY="runtime/question-bank/${QUESTION_BANK_NAME}"
  QUESTION_BANK_SHA_KEY="${QUESTION_BANK_KEY}.sha256"
  python3 "${REPO_ROOT}/scripts/r2_object.py" --env-file "${ENV_FILE_ABS}" put --file "${QUESTION_BANK_PATH}" --key "${QUESTION_BANK_KEY}" --content-type application/gzip >/dev/null
  python3 "${REPO_ROOT}/scripts/r2_object.py" --env-file "${ENV_FILE_ABS}" put --file "${QUESTION_BANK_SHA_PATH}" --key "${QUESTION_BANK_SHA_KEY}" --content-type text/plain >/dev/null
  QUESTION_BANK_JSON="$(python3 - <<PY
import json
base = ${PUBLIC_BASE_URL@Q}.rstrip("/")
print(json.dumps({
    "key": ${QUESTION_BANK_KEY@Q},
    "url": base + "/" + ${QUESTION_BANK_KEY@Q},
    "sha256": ${QUESTION_BANK_SHA@Q},
    "sizeBytes": int(${QUESTION_BANK_SIZE@Q}),
    "extractTo": "/var/lib/cka/question-bank",
}))
PY
)"
fi

CRI_DOCKERD_JSON="null"
if [[ -n "${CRI_DOCKERD_DEB}" ]]; then
  CRI_DOCKERD_ABS="$(realpath "${CRI_DOCKERD_DEB}")"
  if [[ ! -f "${CRI_DOCKERD_ABS}" ]]; then
    echo "cri-dockerd deb not found: ${CRI_DOCKERD_DEB}" >&2
    exit 2
  fi
  CRI_DOCKERD_NAME="$(basename "${CRI_DOCKERD_ABS}")"
  CRI_DOCKERD_STAGED="${DIST_DIR}/${CRI_DOCKERD_NAME}"
  cp "${CRI_DOCKERD_ABS}" "${CRI_DOCKERD_STAGED}"
  (
    cd "${DIST_DIR}"
    sha256sum "${CRI_DOCKERD_NAME}" > "${CRI_DOCKERD_NAME}.sha256"
  )
  CRI_DOCKERD_SHA_PATH="${CRI_DOCKERD_STAGED}.sha256"
  CRI_DOCKERD_SHA="$(awk '{print $1}' "${CRI_DOCKERD_SHA_PATH}")"
  CRI_DOCKERD_SIZE="$(stat -c '%s' "${CRI_DOCKERD_STAGED}")"
  CRI_DOCKERD_KEY="runtime/assets/${CRI_DOCKERD_NAME}"
  CRI_DOCKERD_SHA_KEY="${CRI_DOCKERD_KEY}.sha256"
  python3 "${REPO_ROOT}/scripts/r2_object.py" --env-file "${ENV_FILE_ABS}" put --file "${CRI_DOCKERD_STAGED}" --key "${CRI_DOCKERD_KEY}" --content-type application/vnd.debian.binary-package >/dev/null
  python3 "${REPO_ROOT}/scripts/r2_object.py" --env-file "${ENV_FILE_ABS}" put --file "${CRI_DOCKERD_SHA_PATH}" --key "${CRI_DOCKERD_SHA_KEY}" --content-type text/plain >/dev/null
  CRI_DOCKERD_JSON="$(python3 - <<PY
import json
base = ${PUBLIC_BASE_URL@Q}.rstrip("/")
print(json.dumps({
    "key": ${CRI_DOCKERD_KEY@Q},
    "url": base + "/" + ${CRI_DOCKERD_KEY@Q},
    "sha256": ${CRI_DOCKERD_SHA@Q},
    "sizeBytes": int(${CRI_DOCKERD_SIZE@Q}),
    "installPath": "/var/lib/cka/assets/${CRI_DOCKERD_NAME}",
}))
PY
)"
fi

MANIFEST_NAME="runtime-node-${VERSION}.json"
MANIFEST_PATH="${DIST_DIR}/${MANIFEST_NAME}"
MANIFEST_KEY="runtime/manifests/${MANIFEST_NAME}"

python3 - <<PY > "${MANIFEST_PATH}"
import datetime as dt
import json

public_base_url = ${PUBLIC_BASE_URL@Q}.rstrip("/")
bundle_key = ${BUNDLE_KEY@Q}
manifest = {
    "schemaVersion": 1,
    "version": ${VERSION@Q},
    "generatedAt": dt.datetime.now(dt.UTC).isoformat(),
    "publicBaseUrl": public_base_url,
    "runtimeRoot": "/var/lib/cka",
    "runtimeBundle": {
        "key": bundle_key,
        "url": public_base_url + "/" + bundle_key,
        "sha256": ${BUNDLE_SHA@Q},
        "sizeBytes": int(${BUNDLE_SIZE@Q}),
        "extractTo": "/var/lib/cka",
    },
    "questionBank": json.loads(${QUESTION_BANK_JSON@Q}),
    "criDockerdDeb": json.loads(${CRI_DOCKERD_JSON@Q}),
    "goldenImage": json.loads(${GOLDEN_JSON@Q}),
    "requiredPackages": [
        "ansible",
        "bridge-utils",
        "ca-certificates",
        "cloud-init",
        "cloud-image-utils",
        "conntrack",
        "curl",
        "dmidecode",
        "docker.io",
        "dnsmasq-base",
        "genisoimage",
        "iptables",
        "jq",
        "libguestfs-tools",
        "qemu-kvm",
        "libvirt-daemon-system",
        "libvirt-clients",
        "mdevctl",
        "parted",
        "python3",
        "qemu-utils",
        "rsync",
        "tar",
        "unzip",
        "virtinst",
        "zstd"
    ],
    "kind": {
        "version": "v0.23.0",
        "url": "https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64",
        "sha256": ""
    },
    "kubectl": {
        "version": "v1.30.0",
        "url": "https://dl.k8s.io/release/v1.30.0/bin/linux/amd64/kubectl",
        "sha256": ""
    },
    "runtimeUser": "cka-runtime",
}
print(json.dumps(manifest, ensure_ascii=False, indent=2))
PY

python3 "${REPO_ROOT}/scripts/r2_object.py" --env-file "${ENV_FILE_ABS}" put --file "${MANIFEST_PATH}" --key "${MANIFEST_KEY}" --content-type application/json >/dev/null

printf 'bundle_url=%s/%s\n' "${PUBLIC_BASE_URL%/}" "${BUNDLE_KEY}"
printf 'installer_url=%s/%s\n' "${PUBLIC_BASE_URL%/}" "${INSTALLER_KEY}"
printf 'manifest_url=%s/%s\n' "${PUBLIC_BASE_URL%/}" "${MANIFEST_KEY}"
if [[ "${GOLDEN_JSON}" != "null" ]]; then
  python3 - <<PY
import json
image = json.loads(${GOLDEN_JSON@Q})
print("golden_image_url=" + image["url"])
PY
fi
