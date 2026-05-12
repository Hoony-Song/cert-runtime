#!/usr/bin/env bash
set -euo pipefail

show_help() {
  cat <<'USAGE'
Usage: render-cloud-init.sh --session-id <id> --vm-role <role> --vm-hostname <hostname> --ssh-public-key-file <path> --output-dir <dir> [--exam-type <type>] [--vm-username <user>] [--vm-interface <name>] [--dry-run] [--verbose]

Renders cloud-init user-data, meta-data, and network-config for a session VM.
The SSH public key is read at VM creation time and is never stored in the Golden Image.
USAGE
}

SESSION_ID=""
VM_ROLE=""
VM_HOSTNAME=""
SSH_PUBLIC_KEY_FILE=""
OUTPUT_DIR=""
EXAM_TYPE="CKA"
VM_USERNAME="ubuntu"
VM_INTERFACE="enp1s0"
DRY_RUN=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-id) SESSION_ID="${2:-}"; shift 2 ;;
    --vm-role) VM_ROLE="${2:-}"; shift 2 ;;
    --vm-hostname) VM_HOSTNAME="${2:-}"; shift 2 ;;
    --ssh-public-key-file) SSH_PUBLIC_KEY_FILE="${2:-}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --exam-type) EXAM_TYPE="${2:-}"; shift 2 ;;
    --vm-username) VM_USERNAME="${2:-}"; shift 2 ;;
    --vm-interface) VM_INTERFACE="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --verbose) VERBOSE=true; shift ;;
    --help|-h) show_help; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; show_help >&2; exit 2 ;;
  esac
done

require_value() {
  local name="$1"
  local value="$2"
  if [[ -z "${value}" ]]; then
    echo "필수 인자가 비어 있습니다: ${name}" >&2
    exit 2
  fi
}

require_value "--session-id" "${SESSION_ID}"
require_value "--vm-role" "${VM_ROLE}"
require_value "--vm-hostname" "${VM_HOSTNAME}"
require_value "--ssh-public-key-file" "${SSH_PUBLIC_KEY_FILE}"
require_value "--output-dir" "${OUTPUT_DIR}"

if [[ ! -f "${SSH_PUBLIC_KEY_FILE}" ]]; then
  echo "SSH public key 파일이 없습니다: ${SSH_PUBLIC_KEY_FILE}" >&2
  exit 1
fi

SSH_PUBLIC_KEY="$(tr -d '\r\n' < "${SSH_PUBLIC_KEY_FILE}")"

case "${SSH_PUBLIC_KEY}" in
  ssh-rsa\ *|ssh-ed25519\ *|ecdsa-sha2-nistp256\ *|ecdsa-sha2-nistp384\ *|ecdsa-sha2-nistp521\ *) ;;
  *) echo "지원하지 않는 SSH public key 형식입니다." >&2; exit 1 ;;
esac

if grep -q "PRIVATE KEY" "${SSH_PUBLIC_KEY_FILE}"; then
  echo "private key로 보이는 파일은 cloud-init에 사용할 수 없습니다." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEMPLATE_DIR="${REPO_ROOT}/cloud-init"

render_template() {
  local template_path="$1"
  local output_path="$2"

  sed \
    -e "s|\${SESSION_ID}|${SESSION_ID}|g" \
    -e "s|\${VM_ROLE}|${VM_ROLE}|g" \
    -e "s|\${VM_HOSTNAME}|${VM_HOSTNAME}|g" \
    -e "s|\${VM_USERNAME}|${VM_USERNAME}|g" \
    -e "s|\${VM_INTERFACE}|${VM_INTERFACE}|g" \
    -e "s|\${EXAM_TYPE}|${EXAM_TYPE}|g" \
    -e "s|\${SSH_PUBLIC_KEY}|${SSH_PUBLIC_KEY}|g" \
    "${template_path}" > "${output_path}"
}

if [[ "${DRY_RUN}" == true ]]; then
  printf '{"sessionId":"%s","vmRole":"%s","vmHostname":"%s","outputDir":"%s","dryRun":true}\n' \
    "${SESSION_ID}" "${VM_ROLE}" "${VM_HOSTNAME}" "${OUTPUT_DIR}"
  exit 0
fi

mkdir -p "${OUTPUT_DIR}"
chmod 0700 "${OUTPUT_DIR}"

render_template "${TEMPLATE_DIR}/user-data.tpl" "${OUTPUT_DIR}/user-data"
render_template "${TEMPLATE_DIR}/meta-data.tpl" "${OUTPUT_DIR}/meta-data"
render_template "${TEMPLATE_DIR}/network-config.tpl" "${OUTPUT_DIR}/network-config"

chmod 0600 "${OUTPUT_DIR}/user-data"
chmod 0644 "${OUTPUT_DIR}/meta-data" "${OUTPUT_DIR}/network-config"

if [[ "${VERBOSE}" == true ]]; then
  printf '{"sessionId":"%s","vmRole":"%s","vmHostname":"%s","outputDir":"%s","rendered":true}\n' \
    "${SESSION_ID}" "${VM_ROLE}" "${VM_HOSTNAME}" "${OUTPUT_DIR}"
fi
