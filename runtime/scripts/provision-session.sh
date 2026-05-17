#!/usr/bin/env bash
set -Eeuo pipefail

show_help() {
  cat <<'USAGE'
사용법: provision-session.sh --session-id <id> --exam-type <type> --exam-set-id <id> [--session-root <dir>] [--base-image <path>] [--kind-api-server-address <ip>] [--bastion-image <image>] [--dry-run] [--verbose]

세션별 Runtime 환경을 생성한다.

이 스크립트는 Runtime Node에서 실행하는 것을 기본 전제로 한다.
전역 자원 이름은 <session_id>-cka0001, <session_id>-cka0002, <session_id>-cka0003 형식을 사용한다.
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
  local step_status=0
  shift

  CURRENT_STEP="${step}"
  write_state "PROVISIONING" "${step}"

  if [[ "${VERBOSE}" == true ]]; then
    printf '{"sessionId":"%s","step":"%s","status":"RUNNING"}\n' "${SESSION_ID}" "${step}"
  fi

  "$@" >"${LOG_DIR}/${step}.log" 2>&1 || step_status=$?
  if (( step_status != 0 )); then
    handle_failure "${step_status}"
  fi
}

discover_vm_ip() {
  local node_name="$1"
  local domain_name="${SESSION_ID}-${node_name}"
  local deadline
  local ip

  # Use virsh domifaddr which queries the VM directly by domain name,
  # avoiding stale DHCP lease matches from prior sessions with the same hostname.
  deadline=$((SECONDS + 180))
  while (( SECONDS < deadline )); do
    ip="$(virsh domifaddr "${domain_name}" 2>/dev/null | awk '/ipv4/ { print $4; exit }' | cut -d/ -f1)"
    if [[ -n "${ip}" ]]; then
      printf '%s\n' "${ip}"
      return 0
    fi
    sleep 3
  done

  echo "VM IP를 찾지 못했습니다: ${domain_name}" >&2
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

ADMIN_SSH_PUBLIC_KEY_FILE="${CKA_ADMIN_SSH_PUBLIC_KEY_FILE:-/home/cka-runtime/.ssh/cert-ssh.pub}"
RUNTIME_SSH_TARGET="${CKA_RUNTIME_SSH_TARGET:-cka-runtime@runtime}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SESSION_DIR="${SESSION_ROOT}/${SESSION_ID}"
SSH_DIR="${SESSION_DIR}/ssh"
LOG_DIR="${SESSION_DIR}/logs"
KUBECONFIG_DIR="${SESSION_DIR}/kubeconfig"
STATE_FILE="${SESSION_DIR}/state.json"
INVENTORY_FILE="${SESSION_DIR}/inventory.ini"
FAILURE_LOG_ROOT="${CKA_FAILURE_LOG_ROOT:-/var/lib/cka/logs/provision-failures}"
CURRENT_STEP="init"
CP_NODE_NAME="cka0001"
KIND_NODE_NAME="cka0002"
WORKER_NODE_NAME="cka0003"

if [[ "${DRY_RUN}" == true ]]; then
  printf '{"sessionId":"%s","examType":"%s","examSetId":"%s","sessionRoot":"%s","baseImage":"%s","vms":[{"name":"%s","domain":"%s-%s","role":"kubeadm-cp"},{"name":"%s","domain":"%s-%s","role":"kind"},{"name":"%s","domain":"%s-%s","role":"kubeadm-worker"}],"contexts":["cka-vm","cka-kind"],"steps":["session-directory","ssh-key","vm-disks","cloud-init","vm-cluster","dhcp-discovery","kubeadm-bootstrap","kind-host-bootstrap","kind","kubeconfig-injection","terminal-files","question-setup","bastion"],"dryRun":true}\n' \
    "${SESSION_ID}" "${EXAM_TYPE}" "${EXAM_SET_ID}" "${SESSION_ROOT}" "${BASE_IMAGE}" \
    "${CP_NODE_NAME}" "${SESSION_ID}" "${CP_NODE_NAME}" \
    "${KIND_NODE_NAME}" "${SESSION_ID}" "${KIND_NODE_NAME}" \
    "${WORKER_NODE_NAME}" "${SESSION_ID}" "${WORKER_NODE_NAME}"
  exit 0
fi

export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

require_command python3
require_command ssh-keygen
require_command virsh
require_command docker
require_command ansible-playbook
require_command kubectl
require_command scp
require_command ssh

if [[ -e "${SESSION_DIR}" ]]; then
  echo "이미 같은 session_id의 session directory가 존재합니다: ${SESSION_DIR}" >&2
  exit 1
fi

mkdir -p "${SSH_DIR}" "${LOG_DIR}" "${KUBECONFIG_DIR}" "${SESSION_DIR}/artifacts" "${SESSION_DIR}/problems" "${SESSION_DIR}/work"
chmod 0700 "${SESSION_DIR}" "${SSH_DIR}" "${KUBECONFIG_DIR}" "${LOG_DIR}"
# chmod 0700 on SESSION_DIR resets the ACL mask to ---, blocking the inherited libvirt-qemu:r-x entry.
# Restore traverse access so QEMU can open cloud-init ISOs and disk images inside this directory.
setfacl -m u:libvirt-qemu:rx "${SESSION_DIR}"
write_state "PROVISIONING" "init"

handle_failure() {
  local exit_code="${1:-$?}"
  local message
  local failure_log_dir

  message="step ${CURRENT_STEP} 실패"
  failure_log_dir="${FAILURE_LOG_ROOT}/${SESSION_ID}"
  write_state "PROVISION_FAILED" "${CURRENT_STEP}" "${message}"

  mkdir -p "${failure_log_dir}" 2>/dev/null || failure_log_dir="${LOG_DIR}"
  if [[ -d "${LOG_DIR}" ]]; then
    cp -a "${LOG_DIR}/." "${failure_log_dir}/" 2>/dev/null || true
  fi
  if [[ -f "${STATE_FILE}" ]]; then
    cp -f "${STATE_FILE}" "${failure_log_dir}/state.json" 2>/dev/null || true
  fi

  {
    printf 'provision failed at step: %s\n' "${CURRENT_STEP}"
    printf 'failure log dir: %s\n' "${failure_log_dir}"
    if [[ -f "${LOG_DIR}/${CURRENT_STEP}.log" ]]; then
      printf '%s\n' "--- ${CURRENT_STEP}.log tail ---"
      tail -n 80 "${LOG_DIR}/${CURRENT_STEP}.log" || true
    fi
  } >&2

  "${SCRIPT_DIR}/cleanup-session.sh" --session-id "${SESSION_ID}" --exam-type "${EXAM_TYPE}" --exam-set-id "${EXAM_SET_ID}" --verbose >>"${failure_log_dir}/cleanup-after-failure.log" 2>&1 || true
  printf '{"sessionId":"%s","status":"PROVISION_FAILED","failedStep":"%s","logDir":"%s","failureLogDir":"%s"}\n' "${SESSION_ID}" "${CURRENT_STEP}" "${LOG_DIR}" "${failure_log_dir}" >&2
  exit "${exit_code}"
}
trap handle_failure ERR

run_step "ssh-key" ssh-keygen -t ed25519 -N "" -f "${SSH_DIR}/session_vm" -C "${SESSION_ID}@cka-session"
# The sessions/ directory has a default ACL with group::r-x which propagates to new files,
# making the private key appear as 0640. SSH rejects keys that are group/other readable.
setfacl -b "${SSH_DIR}/session_vm"
chmod 0600 "${SSH_DIR}/session_vm"

run_step "vm-disks" "${SCRIPT_DIR}/create-vm-disks.sh" \
  --session-id "${SESSION_ID}" \
  --exam-type "${EXAM_TYPE}" \
  --exam-set-id "${EXAM_SET_ID}" \
  --base-image "${BASE_IMAGE}" \
  --session-disk-dir "${SESSION_DISK_DIR}" \
  --verbose

ADMIN_KEY_ARG=()
if [[ -f "${ADMIN_SSH_PUBLIC_KEY_FILE}" ]]; then
  ADMIN_KEY_ARG=(--admin-ssh-public-key-file "${ADMIN_SSH_PUBLIC_KEY_FILE}")
fi

run_step "cloud-init-cp" "${SCRIPT_DIR}/create-cloud-init-iso.sh" \
  --session-id "${SESSION_ID}" \
  --vm-role "${CP_NODE_NAME}" \
  --vm-hostname "${CP_NODE_NAME}" \
  --ssh-public-key-file "${SSH_DIR}/session_vm.pub" \
  --ssh-private-key-file "${SSH_DIR}/session_vm" \
  --exam-type "${EXAM_TYPE}" \
  "${ADMIN_KEY_ARG[@]}" \
  --verbose

run_step "cloud-init-kind" "${SCRIPT_DIR}/create-cloud-init-iso.sh" \
  --session-id "${SESSION_ID}" \
  --vm-role "${KIND_NODE_NAME}" \
  --vm-hostname "${KIND_NODE_NAME}" \
  --ssh-public-key-file "${SSH_DIR}/session_vm.pub" \
  --ssh-private-key-file "${SSH_DIR}/session_vm" \
  --exam-type "${EXAM_TYPE}" \
  "${ADMIN_KEY_ARG[@]}" \
  --verbose

run_step "cloud-init-worker" "${SCRIPT_DIR}/create-cloud-init-iso.sh" \
  --session-id "${SESSION_ID}" \
  --vm-role "${WORKER_NODE_NAME}" \
  --vm-hostname "${WORKER_NODE_NAME}" \
  --ssh-public-key-file "${SSH_DIR}/session_vm.pub" \
  --ssh-private-key-file "${SSH_DIR}/session_vm" \
  --exam-type "${EXAM_TYPE}" \
  "${ADMIN_KEY_ARG[@]}" \
  --verbose

run_step "vm-cluster" "${SCRIPT_DIR}/create-vm-cluster.sh" \
  --session-id "${SESSION_ID}" \
  --exam-type "${EXAM_TYPE}" \
  --exam-set-id "${EXAM_SET_ID}" \
  --verbose

CURRENT_STEP="dhcp-discovery"
CP_IP="$(discover_vm_ip "${CP_NODE_NAME}")"
KIND_IP="$(discover_vm_ip "${KIND_NODE_NAME}")"
WORKER_IP="$(discover_vm_ip "${WORKER_NODE_NAME}")"

cat >"${INVENTORY_FILE}" <<EOF
[session_vms]
${CP_NODE_NAME} ansible_host=${CP_IP} vm_role=control-plane kube_node_name=master
${KIND_NODE_NAME} ansible_host=${KIND_IP} vm_role=kind
${WORKER_NODE_NAME} ansible_host=${WORKER_IP} vm_role=worker kube_node_name=worker

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

run_step "kind-host-bootstrap" env ANSIBLE_CONFIG="${REPO_ROOT}/ansible/ansible.cfg" ansible-playbook \
  -i "${INVENTORY_FILE}" \
  "${REPO_ROOT}/ansible/playbooks/kind-host-bootstrap.yml"

run_step "kind" "${SCRIPT_DIR}/create-kind.sh" \
  --session-id "${SESSION_ID}" \
  --exam-type "${EXAM_TYPE}" \
  --exam-set-id "${EXAM_SET_ID}" \
  --kind-host "${KIND_IP}" \
  --ssh-user ubuntu \
  --ssh-key "${SSH_DIR}/session_vm" \
  --ssh-known-hosts "${SSH_DIR}/known_hosts" \
  --api-server-address "${KIND_IP:-${KIND_API_SERVER_ADDRESS}}" \
  --verbose

run_step "kubeconfig-injection" "${SCRIPT_DIR}/inject-kubeconfig.sh" \
  --session-id "${SESSION_ID}" \
  --exam-type "${EXAM_TYPE}" \
  --exam-set-id "${EXAM_SET_ID}" \
  --verbose

install_terminal_files() {
  local -a ssh_args
  local target_ip
  local context
  local kubeconfig_copy
  ssh_args=(-i "${SSH_DIR}/session_vm" -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=${SSH_DIR}/known_hosts")

  for target_ip in "${CP_IP}" "${KIND_IP}" "${WORKER_IP}"; do
    context="cka-vm"
    if [[ "${target_ip}" == "${KIND_IP}" ]]; then
      context="cka-kind"
    fi
    kubeconfig_copy="${KUBECONFIG_DIR}/config-${context}"
    cp "${KUBECONFIG_DIR}/config" "${kubeconfig_copy}"
    kubectl --kubeconfig "${kubeconfig_copy}" config use-context "${context}" >/dev/null

    ssh "${ssh_args[@]}" "ubuntu@${target_ip}" "mkdir -p /home/ubuntu/.kube /home/ubuntu/problems"
    scp "${ssh_args[@]}" "${kubeconfig_copy}" "ubuntu@${target_ip}:/home/ubuntu/.kube/config" >/dev/null
    # shellcheck disable=SC2029
    ssh "${ssh_args[@]}" "ubuntu@${target_ip}" "cat > /home/ubuntu/.ssh/config <<EOF
Host cka0001
  HostName ${CP_IP}
  User ubuntu
  IdentityFile ~/.ssh/session_vm
  StrictHostKeyChecking accept-new
  UserKnownHostsFile ~/.ssh/known_hosts

Host cka0002
  HostName ${KIND_IP}
  User ubuntu
  IdentityFile ~/.ssh/session_vm
  StrictHostKeyChecking accept-new
  UserKnownHostsFile ~/.ssh/known_hosts

Host cka0003
  HostName ${WORKER_IP}
  User ubuntu
  IdentityFile ~/.ssh/session_vm
  StrictHostKeyChecking accept-new
  UserKnownHostsFile ~/.ssh/known_hosts
EOF
chmod 700 /home/ubuntu/.ssh /home/ubuntu/.kube && chmod 600 /home/ubuntu/.ssh/config /home/ubuntu/.kube/config"
  done
}

run_step "terminal-files" install_terminal_files

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
READY_JSON="$(printf '{"sessionId":"%s","examType":"%s","examSetId":"%s","status":"READY","vms":[{"name":"%s","domain":"%s-%s","ip":"%s","role":"kubeadm-cp"},{"name":"%s","domain":"%s-%s","ip":"%s","role":"kind"},{"name":"%s","domain":"%s-%s","ip":"%s","role":"kubeadm-worker"}],"contexts":["cka-vm","cka-kind"],"adminCommands":["ssh %s virsh console %s-%s","ssh %s virsh console %s-%s","ssh %s virsh console %s-%s"],"kubeconfig":"%s"}' \
  "${SESSION_ID}" "${EXAM_TYPE}" "${EXAM_SET_ID}" \
  "${CP_NODE_NAME}" "${SESSION_ID}" "${CP_NODE_NAME}" "${CP_IP}" \
  "${KIND_NODE_NAME}" "${SESSION_ID}" "${KIND_NODE_NAME}" "${KIND_IP}" \
  "${WORKER_NODE_NAME}" "${SESSION_ID}" "${WORKER_NODE_NAME}" "${WORKER_IP}" \
  "${RUNTIME_SSH_TARGET}" "${SESSION_ID}" "${CP_NODE_NAME}" \
  "${RUNTIME_SSH_TARGET}" "${SESSION_ID}" "${KIND_NODE_NAME}" \
  "${RUNTIME_SSH_TARGET}" "${SESSION_ID}" "${WORKER_NODE_NAME}" \
  "${KUBECONFIG_DIR}/config")"
printf '%s\n' "${READY_JSON}" >"${STATE_FILE}"
chmod 0600 "${STATE_FILE}"
printf '%s\n' "${READY_JSON}"
