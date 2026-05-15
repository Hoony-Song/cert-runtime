#!/usr/bin/env bash
set -euo pipefail

show_help() {
  cat <<'USAGE'
사용법: create-cloud-init-iso.sh --session-id <id> --vm-role <role> --vm-hostname <hostname> --ssh-public-key-file <path> [--ssh-private-key-file <path>] [--output-dir <dir>] [--iso-path <path>] [--exam-type <type>] [--vm-username <user>] [--vm-interface <name>] [--network-mode dhcp|static] [--vm-ip-cidr <cidr>] [--vm-gateway <ip>] [--vm-dns <ip,ip>] [--dry-run] [--verbose]

세션 VM별 cloud-init user-data, meta-data, network-config를 렌더링하고 ISO를 생성한다.
USAGE
}

SESSION_ID=""
VM_ROLE=""
VM_HOSTNAME=""
SSH_PUBLIC_KEY_FILE=""
SSH_PRIVATE_KEY_FILE=""
ADMIN_SSH_PUBLIC_KEY_FILE=""
OUTPUT_DIR=""
ISO_PATH=""
EXAM_TYPE="CKA"
VM_USERNAME="ubuntu"
VM_INTERFACE="enp1s0"
NETWORK_MODE="dhcp"
VM_IP_CIDR=""
VM_GATEWAY=""
VM_DNS=""
DRY_RUN=false
VERBOSE=false
LIBVIRT_ACCESS_GROUP="${CKA_VM_LIBVIRT_ACCESS_GROUP:-kvm}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-id) SESSION_ID="${2:-}"; shift 2 ;;
    --vm-role) VM_ROLE="${2:-}"; shift 2 ;;
    --vm-hostname) VM_HOSTNAME="${2:-}"; shift 2 ;;
    --ssh-public-key-file) SSH_PUBLIC_KEY_FILE="${2:-}"; shift 2 ;;
    --ssh-private-key-file) SSH_PRIVATE_KEY_FILE="${2:-}"; shift 2 ;;
    --admin-ssh-public-key-file) ADMIN_SSH_PUBLIC_KEY_FILE="${2:-}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --iso-path) ISO_PATH="${2:-}"; shift 2 ;;
    --exam-type) EXAM_TYPE="${2:-}"; shift 2 ;;
    --vm-username) VM_USERNAME="${2:-}"; shift 2 ;;
    --vm-interface) VM_INTERFACE="${2:-}"; shift 2 ;;
    --network-mode) NETWORK_MODE="${2:-}"; shift 2 ;;
    --vm-ip-cidr) VM_IP_CIDR="${2:-}"; shift 2 ;;
    --vm-gateway) VM_GATEWAY="${2:-}"; shift 2 ;;
    --vm-dns) VM_DNS="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --verbose) VERBOSE=true; shift ;;
    --help|-h) show_help; exit 0 ;;
    *) echo "알 수 없는 인자입니다: $1" >&2; show_help >&2; exit 2 ;;
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

require_safe_name() {
  local name="$1"
  local value="$2"

  if [[ ! "${value}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]]; then
    echo "${name} 값은 영문자, 숫자, 점, 밑줄, 하이픈만 사용할 수 있고 1~63자여야 합니다." >&2
    exit 2
  fi
}

require_absolute_path() {
  local name="$1"
  local value="$2"

  if [[ "${value}" != /* ]]; then
    echo "${name}에는 절대 경로를 사용해야 합니다: ${value}" >&2
    exit 2
  fi
}

require_value "--session-id" "${SESSION_ID}"
require_value "--vm-role" "${VM_ROLE}"
require_value "--vm-hostname" "${VM_HOSTNAME}"
require_value "--ssh-public-key-file" "${SSH_PUBLIC_KEY_FILE}"
require_safe_name "--session-id" "${SESSION_ID}"
require_safe_name "--vm-role" "${VM_ROLE}"

case "${NETWORK_MODE}" in
  dhcp|static) ;;
  *) echo "--network-mode는 dhcp 또는 static이어야 합니다." >&2; exit 2 ;;
esac

if [[ "${NETWORK_MODE}" == "static" ]]; then
  require_value "--vm-ip-cidr" "${VM_IP_CIDR}"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${OUTPUT_DIR}" ]]; then
  OUTPUT_DIR="/var/lib/cka/sessions/${SESSION_ID}/cloud-init/${VM_ROLE}"
fi

if [[ -z "${ISO_PATH}" ]]; then
  ISO_PATH="${OUTPUT_DIR}/${SESSION_ID}-${VM_ROLE}-cloud-init.iso"
fi

require_absolute_path "--output-dir" "${OUTPUT_DIR}"
require_absolute_path "--iso-path" "${ISO_PATH}"

USER_DATA="${OUTPUT_DIR}/user-data"
META_DATA="${OUTPUT_DIR}/meta-data"
NETWORK_CONFIG="${OUTPUT_DIR}/network-config"

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

if [[ -n "${SSH_PRIVATE_KEY_FILE}" && ! -f "${SSH_PRIVATE_KEY_FILE}" ]]; then
  echo "SSH private key 파일이 없습니다: ${SSH_PRIVATE_KEY_FILE}" >&2
  exit 1
fi

if [[ -e "${ISO_PATH}" ]]; then
  echo "이미 cloud-init ISO가 존재합니다: ${ISO_PATH}" >&2
  exit 1
fi

render_static_network_config() {
  {
    printf 'version: 2\n'
    printf 'ethernets:\n'
    printf '  %s:\n' "${VM_INTERFACE}"
    printf '    dhcp4: false\n'
    printf '    dhcp6: false\n'
    printf '    addresses:\n'
    printf '      - %s\n' "${VM_IP_CIDR}"

    if [[ -n "${VM_GATEWAY}" ]]; then
      printf '    routes:\n'
      printf '      - to: default\n'
      printf '        via: %s\n' "${VM_GATEWAY}"
    fi

    if [[ -n "${VM_DNS}" ]]; then
      printf '    nameservers:\n'
      printf '      addresses:\n'
      local dns_entry
      IFS=',' read -r -a dns_entries <<< "${VM_DNS}"
      for dns_entry in "${dns_entries[@]}"; do
        if [[ -n "${dns_entry}" ]]; then
          printf '        - %s\n' "${dns_entry}"
        fi
      done
    fi
  } > "${NETWORK_CONFIG}"
}

if [[ "${DRY_RUN}" == true ]]; then
  printf '{"sessionId":"%s","vmRole":"%s","vmHostname":"%s","outputDir":"%s","isoPath":"%s","networkMode":"%s","dryRun":true}\n' \
    "${SESSION_ID}" "${VM_ROLE}" "${VM_HOSTNAME}" "${OUTPUT_DIR}" "${ISO_PATH}" "${NETWORK_MODE}"
  exit 0
fi

if ! command -v cloud-localds >/dev/null 2>&1; then
  echo "cloud-localds 명령을 찾을 수 없습니다." >&2
  exit 1
fi

mkdir -p "${OUTPUT_DIR}"
if getent group "${LIBVIRT_ACCESS_GROUP}" >/dev/null 2>&1; then
  chgrp "${LIBVIRT_ACCESS_GROUP}" "${OUTPUT_DIR}"
fi
chmod 2770 "${OUTPUT_DIR}"

RENDER_ARGS=(
  --session-id "${SESSION_ID}"
  --vm-role "${VM_ROLE}"
  --vm-hostname "${VM_HOSTNAME}"
  --ssh-public-key-file "${SSH_PUBLIC_KEY_FILE}"
  --output-dir "${OUTPUT_DIR}"
  --exam-type "${EXAM_TYPE}"
  --vm-username "${VM_USERNAME}"
  --vm-interface "${VM_INTERFACE}"
)

if [[ -n "${SSH_PRIVATE_KEY_FILE}" ]]; then
  RENDER_ARGS+=(--ssh-private-key-file "${SSH_PRIVATE_KEY_FILE}")
fi

if [[ -n "${ADMIN_SSH_PUBLIC_KEY_FILE}" && -f "${ADMIN_SSH_PUBLIC_KEY_FILE}" ]]; then
  RENDER_ARGS+=(--admin-ssh-public-key-file "${ADMIN_SSH_PUBLIC_KEY_FILE}")
fi

"${SCRIPT_DIR}/render-cloud-init.sh" "${RENDER_ARGS[@]}"

if getent group "${LIBVIRT_ACCESS_GROUP}" >/dev/null 2>&1; then
  chgrp "${LIBVIRT_ACCESS_GROUP}" "${OUTPUT_DIR}"
fi
chmod 2770 "${OUTPUT_DIR}"

if [[ "${NETWORK_MODE}" == "static" ]]; then
  render_static_network_config
  chmod 0644 "${NETWORK_CONFIG}"
fi

cloud-localds --network-config="${NETWORK_CONFIG}" "${ISO_PATH}" "${USER_DATA}" "${META_DATA}"
if getent group "${LIBVIRT_ACCESS_GROUP}" >/dev/null 2>&1; then
  chgrp "${LIBVIRT_ACCESS_GROUP}" "${ISO_PATH}"
fi
chmod 0640 "${ISO_PATH}"

if [[ "${VERBOSE}" == true ]]; then
  printf '{"sessionId":"%s","vmRole":"%s","outputDir":"%s","isoPath":"%s","created":true}\n' \
    "${SESSION_ID}" "${VM_ROLE}" "${OUTPUT_DIR}" "${ISO_PATH}"
fi
