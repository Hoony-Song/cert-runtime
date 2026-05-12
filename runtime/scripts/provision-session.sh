#!/usr/bin/env bash
set -euo pipefail

show_help() {
  cat <<'USAGE'
사용법: provision-session.sh --session-id <id> --exam-type <type> --exam-set-id <id> [--session-root <dir>] [--base-image <path>] [--kind-api-server-address <ip>] [--bastion-image <image>] [--dry-run] [--verbose]

세션별 Runtime 환경을 생성한다.

이 스크립트는 Runtime Node에서 실행하는 것을 기본 전제로 한다.
USAGE
}

SESSION_ID=""
EXAM_TYPE="CKA"
EXAM_SET_ID=""
SESSION_ROOT="${CKA_SESSION_ROOT:-/var/lib/cka/sessions}"
BASE_IMAGE="${CKA_VM_BASE_IMAGE:-/var/lib/cka/images/base/cka-ubuntu-22.04-kubeadm-1.30-v1/cka-ubuntu-22.04-kubeadm-1.30-v1.qcow2}"
SESSION_DISK_DIR="${CKA_VM_SESSION_DISK_DIR:-/var/lib/cka/images/sessions}"
KIND_API_SERVER_ADDRESS="${CKA_KIND_API_SERVER_ADDRESS:-127.0.0.1}"
BASTION_IMAGE="${CKA_BASTION_IMAGE:-cka-bastion:local}"
DRY_RUN=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-id) SESSION_ID="${2:-}"; shift 2 ;;
    --exam-type) EXAM_TYPE="${2:-}"; shift 2 ;;
    --exam-set-id) EXAM_SET_ID="${2:-}"; shift 2 ;;
    --session-root) SESSION_ROOT="${2:-}"; shift 2 ;;
    --base-image) BASE_IMAGE="${2:-}"; shift 2 ;;
    --session-disk-dir) SESSION_DISK_DIR="${2:-}"; shift 2 ;;
    --kind-api-server-address) KIND_API_SERVER_ADDRESS="${2:-}"; shift 2 ;;
    --bastion-image) BASTION_IMAGE="${2:-}"; shift 2 ;;
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

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])'
}

require_command() {
  local command_name="$1"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "필수 명령을 찾을 수 없습니다: ${command_name}" >&2
    exit 1
  fi
}

write_state() {
  local status="$1"
  local step="$2"
  local message="${3:-}"
  local escaped_message

  escaped_message="$(printf '%s' "${message}" | json_escape)"
  cat >"${STATE_FILE}" <<EOF
{
  "sessionId": "${SESSION_ID}",
  "examType": "${EXAM_TYPE}",
  "examSetId": "${EXAM_SET_ID}",
  "status": "${status}",
  "step": "${step}",
  "message": "${escaped_message}",
  "updatedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
  chmod 0600 "${STATE_FILE}"
}

run_step() {
  local step="$1"
  shift

  CURRENT_STEP="${step}"
  write_state "PROVISIONING" "${step}"

  if [[ "${VERBOSE}" == true ]]; then
    printf '{"sessionId":"%s","step":"%s","status":"RUNNING"}\n' "${SESSION_ID}" "${step}"
  fi

  "$@" >"${LOG_DIR}/${step}.log" 2>&1
}

discover_vm_ip() {
  local hostname="$1"
  local deadline
  local lease

  deadline=$((SECONDS + 180))
  while (( SECONDS < deadline )); do
    lease="$(virsh net-dhcp-leases default 2>/dev/null | awk -v host="${hostname}" '$0 ~ host { print $5; exit }' | cut -d/ -f1)"
    if [[ -n "${lease}" ]]; then
      printf '%s\n' "${lease}"
      return 0
    fi
    sleep 3
  done

  echo "VM DHCP lease를 찾지 못했습니다: ${hostname}" >&2
  return 1
}

build_bastion_image_if_needed() {
  if docker image inspect "${BASTION_IMAGE}" >/dev/null 2>&1; then
    return 0
  fi

  docker build -t "${BASTION_IMAGE}" "${REPO_ROOT}/bastion"
}

require_value "--session-id" "${SESSION_ID}"
require_value "--exam-type" "${EXAM_TYPE}"
require_value "--exam-set-id" "${EXAM_SET_ID}"
require_safe_session_id "${SESSION_ID}"
require_absolute_path "--session-root" "${SESSION_ROOT}"
require_absolute_path "--session-disk-dir" "${SESSION_DISK_DIR}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SESSION_DIR="${SESSION_ROOT}/${SESSION_ID}"
SSH_DIR="${SESSION_DIR}/ssh"
LOG_DIR="${SESSION_DIR}/logs"
KUBECONFIG_DIR="${SESSION_DIR}/kubeconfig"
STATE_FILE="${SESSION_DIR}/state.json"
INVENTORY_FILE="${SESSION_DIR}/inventory.ini"
CURRENT_STEP="init"

if [[ "${DRY_RUN}" == true ]]; then
  printf '{"sessionId":"%s","examType":"%s","examSetId":"%s","sessionRoot":"%s","baseImage":"%s","steps":["session-directory","ssh-key","vm-disks","cloud-init","vm-cluster","dhcp-discovery","kubeadm-bootstrap","kind","kubeconfig-injection","question-setup","bastion"],"dryRun":true}\n' \
    "${SESSION_ID}" "${EXAM_TYPE}" "${EXAM_SET_ID}" "${SESSION_ROOT}" "${BASE_IMAGE}"
  exit 0
fi

require_command python3
require_command ssh-keygen
require_command virsh
require_command docker
require_command ansible-playbook
require_command kubectl

if [[ -e "${SESSION_DIR}" ]]; then
  echo "이미 같은 session_id의 session directory가 존재합니다: ${SESSION_DIR}" >&2
  exit 1
fi

mkdir -p "${SSH_DIR}" "${LOG_DIR}" "${KUBECONFIG_DIR}" "${SESSION_DIR}/artifacts" "${SESSION_DIR}/problems" "${SESSION_DIR}/work"
chmod 0700 "${SESSION_DIR}" "${SSH_DIR}" "${KUBECONFIG_DIR}" "${LOG_DIR}"
write_state "PROVISIONING" "init"

handle_failure() {
  local exit_code=$?
  local message

  message="step ${CURRENT_STEP} 실패"
  write_state "PROVISION_FAILED" "${CURRENT_STEP}" "${message}"
  "${SCRIPT_DIR}/cleanup-session.sh" --session-id "${SESSION_ID}" --exam-type "${EXAM_TYPE}" --exam-set-id "${EXAM_SET_ID}" --verbose >>"${LOG_DIR}/cleanup-after-failure.log" 2>&1 || true
  printf '{"sessionId":"%s","status":"PROVISION_FAILED","failedStep":"%s","logDir":"%s"}\n' "${SESSION_ID}" "${CURRENT_STEP}" "${LOG_DIR}" >&2
  exit "${exit_code}"
}
trap handle_failure ERR

run_step "ssh-key" ssh-keygen -t ed25519 -N "" -f "${SSH_DIR}/session_vm" -C "${SESSION_ID}@cka-session"

run_step "vm-disks" "${SCRIPT_DIR}/create-vm-disks.sh" \
  --session-id "${SESSION_ID}" \
  --exam-type "${EXAM_TYPE}" \
  --exam-set-id "${EXAM_SET_ID}" \
  --base-image "${BASE_IMAGE}" \
  --session-disk-dir "${SESSION_DISK_DIR}" \
  --verbose

run_step "cloud-init-cp" "${SCRIPT_DIR}/create-cloud-init-iso.sh" \
  --session-id "${SESSION_ID}" \
  --vm-role cp \
  --vm-hostname "${SESSION_ID}-cp" \
  --ssh-public-key-file "${SSH_DIR}/session_vm.pub" \
  --exam-type "${EXAM_TYPE}" \
  --verbose

run_step "cloud-init-worker" "${SCRIPT_DIR}/create-cloud-init-iso.sh" \
  --session-id "${SESSION_ID}" \
  --vm-role worker \
  --vm-hostname "${SESSION_ID}-worker" \
  --ssh-public-key-file "${SSH_DIR}/session_vm.pub" \
  --exam-type "${EXAM_TYPE}" \
  --verbose

run_step "vm-cluster" "${SCRIPT_DIR}/create-vm-cluster.sh" \
  --session-id "${SESSION_ID}" \
  --exam-type "${EXAM_TYPE}" \
  --exam-set-id "${EXAM_SET_ID}" \
  --verbose

CURRENT_STEP="dhcp-discovery"
CP_IP="$(discover_vm_ip "${SESSION_ID}-cp")"
WORKER_IP="$(discover_vm_ip "${SESSION_ID}-worker")"

cat >"${INVENTORY_FILE}" <<EOF
[session_vms]
cka-${SESSION_ID}-cp ansible_host=${CP_IP} vm_role=control-plane
cka-${SESSION_ID}-worker ansible_host=${WORKER_IP} vm_role=worker

[session_vms:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=${SSH_DIR}/session_vm
ansible_ssh_common_args='-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${SSH_DIR}/known_hosts'
ansible_become=true
session_id=${SESSION_ID}
EOF
chmod 0600 "${INVENTORY_FILE}"

run_step "kubeadm-bootstrap" env ANSIBLE_CONFIG="${REPO_ROOT}/ansible/ansible.cfg" ansible-playbook \
  -i "${INVENTORY_FILE}" \
  "${REPO_ROOT}/ansible/playbooks/kubeadm-bootstrap.yml"

run_step "kind" "${SCRIPT_DIR}/create-kind.sh" \
  --session-id "${SESSION_ID}" \
  --exam-type "${EXAM_TYPE}" \
  --exam-set-id "${EXAM_SET_ID}" \
  --api-server-address "${KIND_API_SERVER_ADDRESS}" \
  --verbose

run_step "kubeconfig-injection" "${SCRIPT_DIR}/inject-kubeconfig.sh" \
  --session-id "${SESSION_ID}" \
  --exam-type "${EXAM_TYPE}" \
  --exam-set-id "${EXAM_SET_ID}" \
  --verbose

run_step "question-setup" "${SCRIPT_DIR}/setup-question-env.sh" \
  --session-id "${SESSION_ID}" \
  --exam-type "${EXAM_TYPE}" \
  --exam-set-id "${EXAM_SET_ID}" \
  --verbose

run_step "bastion-image" build_bastion_image_if_needed

run_step "bastion" "${SCRIPT_DIR}/create-bastion.sh" \
  --session-id "${SESSION_ID}" \
  --exam-type "${EXAM_TYPE}" \
  --exam-set-id "${EXAM_SET_ID}" \
  --image "${BASTION_IMAGE}" \
  --verbose

trap - ERR
write_state "READY" "complete"

printf '{"sessionId":"%s","examType":"%s","examSetId":"%s","status":"READY","controlPlaneIp":"%s","workerIp":"%s","bastionContainer":"cka-%s-bastion","kubeconfig":"%s"}\n' \
  "${SESSION_ID}" "${EXAM_TYPE}" "${EXAM_SET_ID}" "${CP_IP}" "${WORKER_IP}" "${SESSION_ID}" "${KUBECONFIG_DIR}/config"
