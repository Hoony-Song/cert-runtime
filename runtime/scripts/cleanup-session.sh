#!/usr/bin/env bash
set -euo pipefail

show_help() {
  cat <<'USAGE'
사용법: cleanup-session.sh --session-id <id> [--exam-type <type>] [--exam-set-id <id>] [--session-root <dir>] [--session-disk-dir <dir>] [--dry-run] [--verbose]

세션별 Bastion, kind, libvirt VM, disk, cloud-init ISO, kubeconfig, 임시 파일을 idempotent하게 삭제한다.
USAGE
}

SESSION_ID=""
EXAM_TYPE="CKA"
EXAM_SET_ID=""
SESSION_ROOT="${CKA_SESSION_ROOT:-/var/lib/cka/sessions}"
SESSION_DISK_DIR="${CKA_VM_SESSION_DISK_DIR:-/var/lib/cka/images/sessions}"
DRY_RUN=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-id) SESSION_ID="${2:-}"; shift 2 ;;
    --exam-type) EXAM_TYPE="${2:-}"; shift 2 ;;
    --exam-set-id) EXAM_SET_ID="${2:-}"; shift 2 ;;
    --session-root) SESSION_ROOT="${2:-}"; shift 2 ;;
    --session-disk-dir) SESSION_DISK_DIR="${2:-}"; shift 2 ;;
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

require_safe_session_id() {
  local value="$1"

  if [[ ! "${value}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]]; then
    echo "session_id는 영문자, 숫자, 점, 밑줄, 하이픈만 사용할 수 있고 1~63자여야 합니다." >&2
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

record_action() {
  local action="$1"
  local status="$2"

  CLEANUP_ACTIONS+=("{\"action\":\"${action}\",\"status\":\"${status}\"}")
  if [[ "${VERBOSE}" == true ]]; then
    printf '{"sessionId":"%s","action":"%s","status":"%s"}\n' "${SESSION_ID}" "${action}" "${status}" >&2
  fi
}

remove_bastion_firewall_rule() {
  local container_name="$1"
  local container_ip

  if ! command -v iptables >/dev/null 2>&1 || ! command -v docker >/dev/null 2>&1; then
    return 0
  fi

  container_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${container_name}" 2>/dev/null || true)"
  if [[ -z "${container_ip}" ]]; then
    return 0
  fi

  while iptables -C LIBVIRT_FWI -s "${container_ip}/32" -d 192.168.122.0/24 -o virbr0 -j ACCEPT >/dev/null 2>&1; do
    iptables -D LIBVIRT_FWI -s "${container_ip}/32" -d 192.168.122.0/24 -o virbr0 -j ACCEPT || break
  done
}

require_value "--session-id" "${SESSION_ID}"
require_safe_session_id "${SESSION_ID}"
require_absolute_path "--session-root" "${SESSION_ROOT}"
require_absolute_path "--session-disk-dir" "${SESSION_DISK_DIR}"

export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

SESSION_DIR="${SESSION_ROOT}/${SESSION_ID}"
BASTION_CONTAINER="${SESSION_ID}-bastion"
KIND_CLUSTER="cka0002-kind"
CP_VM="${SESSION_ID}-cka0001"
KIND_VM="${SESSION_ID}-cka0002"
WORKER_VM="${SESSION_ID}-cka0003"
CLEANUP_ACTIONS=()

if [[ "${DRY_RUN}" == true ]]; then
  printf '{"sessionId":"%s","examType":"%s","examSetId":"%s","resources":{"bastion":"%s","kind":"%s","vms":["%s","%s","%s"],"sessionDir":"%s","sessionDiskDir":"%s"},"dryRun":true}\n' \
    "${SESSION_ID}" "${EXAM_TYPE}" "${EXAM_SET_ID}" "${BASTION_CONTAINER}" "${KIND_CLUSTER}" "${CP_VM}" "${KIND_VM}" "${WORKER_VM}" "${SESSION_DIR}" "${SESSION_DISK_DIR}"
  exit 0
fi

if command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' | grep -Fxq "${BASTION_CONTAINER}"; then
  remove_bastion_firewall_rule "${BASTION_CONTAINER}"
  docker rm -f "${BASTION_CONTAINER}" >/dev/null
  record_action "bastion" "deleted"
else
  record_action "bastion" "not_found"
fi

if command -v kind >/dev/null 2>&1 && kind get clusters 2>/dev/null | grep -Fxq "${KIND_CLUSTER}"; then
  kind delete cluster --name "${KIND_CLUSTER}" >/dev/null
  record_action "kind" "deleted"
else
  record_action "kind" "not_found"
fi

if command -v virsh >/dev/null 2>&1; then
  for vm_name in "${CP_VM}" "${KIND_VM}" "${WORKER_VM}"; do
    if virsh dominfo "${vm_name}" >/dev/null 2>&1; then
      virsh destroy "${vm_name}" >/dev/null 2>&1 || true
      virsh undefine "${vm_name}" --nvram >/dev/null 2>&1 || virsh undefine "${vm_name}" >/dev/null 2>&1 || true
      record_action "${vm_name}" "deleted"
    else
      record_action "${vm_name}" "not_found"
    fi
  done
fi

rm -f \
  "${SESSION_DISK_DIR}/${SESSION_ID}-cka0001.qcow2" \
  "${SESSION_DISK_DIR}/${SESSION_ID}-cka0002.qcow2" \
  "${SESSION_DISK_DIR}/${SESSION_ID}-cka0003.qcow2" \
  "${SESSION_DISK_DIR}/${SESSION_ID}.disks"
record_action "session-disks" "deleted"

rm -rf "${SESSION_DIR}"
record_action "session-dir" "deleted"

printf '{"sessionId":"%s","examType":"%s","examSetId":"%s","status":"CLEANED","actions":[%s]}\n' \
  "${SESSION_ID}" "${EXAM_TYPE}" "${EXAM_SET_ID}" "$(IFS=,; printf '%s' "${CLEANUP_ACTIONS[*]}")"
