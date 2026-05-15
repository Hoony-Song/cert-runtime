#!/usr/bin/env bash
set -euo pipefail

show_help() {
  cat <<'USAGE'
Usage: inspect-session.sh --session-id <id> [--exam-type <type>] [--exam-set-id <id>] [--dry-run] [--verbose]
USAGE
}

SESSION_ID=""
EXAM_TYPE="CKA"
EXAM_SET_ID=""
DRY_RUN=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-id) SESSION_ID="${2:-}"; shift 2 ;;
    --exam-type) EXAM_TYPE="${2:-}"; shift 2 ;;
    --exam-set-id) EXAM_SET_ID="${2:-}"; shift 2 ;;
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

require_safe_session_id() {
  local value="$1"

  if [[ ! "${value}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]]; then
    echo "session_id는 영문자, 숫자, 점, 밑줄, 하이픈만 사용할 수 있고 1~63자여야 합니다." >&2
    exit 2
  fi
}

vm_ip() {
  local hostname="$1"

  if ! command -v virsh >/dev/null 2>&1; then
    printf ''
    return 0
  fi

  virsh net-dhcp-leases default 2>/dev/null | awk -v host="${hostname}" '$0 ~ host { print $5; exit }' | cut -d/ -f1
}

vm_state() {
  local domain="$1"

  if ! command -v virsh >/dev/null 2>&1; then
    printf 'UNKNOWN'
    return 0
  fi

  virsh domstate "${domain}" 2>/dev/null || printf 'NOT_FOUND'
}

require_value "--session-id" "${SESSION_ID}"
require_safe_session_id "${SESSION_ID}"

CP_NODE_NAME="cka0001"
KIND_NODE_NAME="cka0002"
WORKER_NODE_NAME="cka0003"
CP_DOMAIN="${SESSION_ID}-${CP_NODE_NAME}"
KIND_DOMAIN="${SESSION_ID}-${KIND_NODE_NAME}"
WORKER_DOMAIN="${SESSION_ID}-${WORKER_NODE_NAME}"

if [[ "${DRY_RUN}" == true ]]; then
  printf '{"sessionId":"%s","examType":"%s","examSetId":"%s","status":"READY","vms":[{"name":"%s","domain":"%s","ip":"","role":"kubeadm-cp"},{"name":"%s","domain":"%s","ip":"","role":"kind"},{"name":"%s","domain":"%s","ip":"","role":"kubeadm-worker"}],"contexts":["cka-vm","cka-kind"],"adminCommands":["ssh cka-runtime@runtime virsh console %s","ssh cka-runtime@runtime virsh console %s","ssh cka-runtime@runtime virsh console %s"],"dryRun":true}\n' \
    "${SESSION_ID}" "${EXAM_TYPE}" "${EXAM_SET_ID}" \
    "${CP_NODE_NAME}" "${CP_DOMAIN}" \
    "${KIND_NODE_NAME}" "${KIND_DOMAIN}" \
    "${WORKER_NODE_NAME}" "${WORKER_DOMAIN}" \
    "${CP_DOMAIN}" "${KIND_DOMAIN}" "${WORKER_DOMAIN}"
  exit 0
fi

CP_IP="$(vm_ip "${CP_NODE_NAME}")"
KIND_IP="$(vm_ip "${KIND_NODE_NAME}")"
WORKER_IP="$(vm_ip "${WORKER_NODE_NAME}")"
CP_STATE="$(vm_state "${CP_DOMAIN}")"
KIND_STATE="$(vm_state "${KIND_DOMAIN}")"
WORKER_STATE="$(vm_state "${WORKER_DOMAIN}")"

if [[ "${VERBOSE}" == true ]]; then
  printf '{"sessionId":"%s","status":"INSPECTING"}\n' "${SESSION_ID}" >&2
fi

printf '{"sessionId":"%s","examType":"%s","examSetId":"%s","status":"READY","vms":[{"name":"%s","domain":"%s","ip":"%s","role":"kubeadm-cp","state":"%s"},{"name":"%s","domain":"%s","ip":"%s","role":"kind","state":"%s"},{"name":"%s","domain":"%s","ip":"%s","role":"kubeadm-worker","state":"%s"}],"contexts":["cka-vm","cka-kind"],"adminCommands":["ssh cka-runtime@runtime virsh console %s","ssh cka-runtime@runtime virsh console %s","ssh cka-runtime@runtime virsh console %s"]}\n' \
  "${SESSION_ID}" "${EXAM_TYPE}" "${EXAM_SET_ID}" \
  "${CP_NODE_NAME}" "${CP_DOMAIN}" "${CP_IP}" "${CP_STATE}" \
  "${KIND_NODE_NAME}" "${KIND_DOMAIN}" "${KIND_IP}" "${KIND_STATE}" \
  "${WORKER_NODE_NAME}" "${WORKER_DOMAIN}" "${WORKER_IP}" "${WORKER_STATE}" \
  "${CP_DOMAIN}" "${KIND_DOMAIN}" "${WORKER_DOMAIN}"
