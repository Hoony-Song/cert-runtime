#!/usr/bin/env bash
set -euo pipefail

show_help() {
  cat <<'USAGE'
사용법: create-vm-cluster.sh --session-id <id> [--exam-type <type>] [--exam-set-id <id>] [--session-disk-dir <dir>] [--session-root <dir>] [--cp-disk <path>] [--kind-disk <path>] [--worker-disk <path>] [--cp-cloud-init-iso <path>] [--kind-cloud-init-iso <path>] [--worker-cloud-init-iso <path>] [--network <name>] [--cp-vcpus <n>] [--kind-vcpus <n>] [--worker-vcpus <n>] [--cp-memory-mib <mib>] [--kind-memory-mib <mib>] [--worker-memory-mib <mib>] [--os-variant <name>] [--dry-run] [--verbose]

세션별 VM 3대(cka0001, cka0002, cka0003)를 libvirt로 생성하고 부팅 상태를 확인한다.
USAGE
}

SESSION_ID=""
EXAM_TYPE="CKA"
EXAM_SET_ID=""
SESSION_DISK_DIR="${CKA_VM_SESSION_DISK_DIR:-/var/lib/cka/images/sessions}"
SESSION_ROOT="${CKA_SESSION_ROOT:-/var/lib/cka/sessions}"
CP_DISK=""
KIND_DISK=""
WORKER_DISK=""
CP_CLOUD_INIT_ISO=""
KIND_CLOUD_INIT_ISO=""
WORKER_CLOUD_INIT_ISO=""
NETWORK="${CKA_VM_NETWORK:-default}"
CP_VCPUS="${CKA_VM_CP_VCPUS:-2}"
KIND_VCPUS="${CKA_VM_KIND_VCPUS:-2}"
WORKER_VCPUS="${CKA_VM_WORKER_VCPUS:-2}"
CP_MEMORY_MIB="${CKA_VM_CP_MEMORY_MIB:-2560}"
KIND_MEMORY_MIB="${CKA_VM_KIND_MEMORY_MIB:-3584}"
WORKER_MEMORY_MIB="${CKA_VM_WORKER_MEMORY_MIB:-2048}"
OS_VARIANT="${CKA_VM_OS_VARIANT:-ubuntu22.04}"
BOOT_WAIT_SECONDS="${CKA_VM_BOOT_WAIT_SECONDS:-60}"
DRY_RUN=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-id) SESSION_ID="${2:-}"; shift 2 ;;
    --exam-type) EXAM_TYPE="${2:-}"; shift 2 ;;
    --exam-set-id) EXAM_SET_ID="${2:-}"; shift 2 ;;
    --session-disk-dir) SESSION_DISK_DIR="${2:-}"; shift 2 ;;
    --session-root) SESSION_ROOT="${2:-}"; shift 2 ;;
    --cp-disk) CP_DISK="${2:-}"; shift 2 ;;
    --kind-disk) KIND_DISK="${2:-}"; shift 2 ;;
    --worker-disk) WORKER_DISK="${2:-}"; shift 2 ;;
    --cp-cloud-init-iso) CP_CLOUD_INIT_ISO="${2:-}"; shift 2 ;;
    --kind-cloud-init-iso) KIND_CLOUD_INIT_ISO="${2:-}"; shift 2 ;;
    --worker-cloud-init-iso) WORKER_CLOUD_INIT_ISO="${2:-}"; shift 2 ;;
    --network) NETWORK="${2:-}"; shift 2 ;;
    --cp-vcpus) CP_VCPUS="${2:-}"; shift 2 ;;
    --kind-vcpus) KIND_VCPUS="${2:-}"; shift 2 ;;
    --worker-vcpus) WORKER_VCPUS="${2:-}"; shift 2 ;;
    --cp-memory-mib) CP_MEMORY_MIB="${2:-}"; shift 2 ;;
    --kind-memory-mib) KIND_MEMORY_MIB="${2:-}"; shift 2 ;;
    --worker-memory-mib) WORKER_MEMORY_MIB="${2:-}"; shift 2 ;;
    --os-variant) OS_VARIANT="${2:-}"; shift 2 ;;
    --boot-wait-seconds) BOOT_WAIT_SECONDS="${2:-}"; shift 2 ;;
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

require_positive_integer() {
  local name="$1"
  local value="$2"

  if [[ ! "${value}" =~ ^[1-9][0-9]*$ ]]; then
    echo "${name} 값은 양의 정수여야 합니다: ${value}" >&2
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

require_existing_file() {
  local name="$1"
  local value="$2"

  if [[ ! -f "${value}" ]]; then
    echo "${name} 파일이 없습니다: ${value}" >&2
    exit 1
  fi
}

require_value "--session-id" "${SESSION_ID}"
require_safe_session_id "${SESSION_ID}"
require_positive_integer "--cp-vcpus" "${CP_VCPUS}"
require_positive_integer "--kind-vcpus" "${KIND_VCPUS}"
require_positive_integer "--worker-vcpus" "${WORKER_VCPUS}"
require_positive_integer "--cp-memory-mib" "${CP_MEMORY_MIB}"
require_positive_integer "--kind-memory-mib" "${KIND_MEMORY_MIB}"
require_positive_integer "--worker-memory-mib" "${WORKER_MEMORY_MIB}"
require_positive_integer "--boot-wait-seconds" "${BOOT_WAIT_SECONDS}"
require_absolute_path "--session-disk-dir" "${SESSION_DISK_DIR}"
require_absolute_path "--session-root" "${SESSION_ROOT}"

CP_NODE_NAME="cka0001"
KIND_NODE_NAME="cka0002"
WORKER_NODE_NAME="cka0003"
CP_VM_NAME="${SESSION_ID}-${CP_NODE_NAME}"
KIND_VM_NAME="${SESSION_ID}-${KIND_NODE_NAME}"
WORKER_VM_NAME="${SESSION_ID}-${WORKER_NODE_NAME}"

if [[ -z "${CP_DISK}" ]]; then
  CP_DISK="${SESSION_DISK_DIR}/${SESSION_ID}-${CP_NODE_NAME}.qcow2"
fi

if [[ -z "${WORKER_DISK}" ]]; then
  WORKER_DISK="${SESSION_DISK_DIR}/${SESSION_ID}-${WORKER_NODE_NAME}.qcow2"
fi

if [[ -z "${KIND_DISK}" ]]; then
  KIND_DISK="${SESSION_DISK_DIR}/${SESSION_ID}-${KIND_NODE_NAME}.qcow2"
fi

if [[ -z "${CP_CLOUD_INIT_ISO}" ]]; then
  CP_CLOUD_INIT_ISO="${SESSION_ROOT}/${SESSION_ID}/cloud-init/${CP_NODE_NAME}/${SESSION_ID}-${CP_NODE_NAME}-cloud-init.iso"
fi

if [[ -z "${KIND_CLOUD_INIT_ISO}" ]]; then
  KIND_CLOUD_INIT_ISO="${SESSION_ROOT}/${SESSION_ID}/cloud-init/${KIND_NODE_NAME}/${SESSION_ID}-${KIND_NODE_NAME}-cloud-init.iso"
fi

if [[ -z "${WORKER_CLOUD_INIT_ISO}" ]]; then
  WORKER_CLOUD_INIT_ISO="${SESSION_ROOT}/${SESSION_ID}/cloud-init/${WORKER_NODE_NAME}/${SESSION_ID}-${WORKER_NODE_NAME}-cloud-init.iso"
fi

require_absolute_path "--cp-disk" "${CP_DISK}"
require_absolute_path "--kind-disk" "${KIND_DISK}"
require_absolute_path "--worker-disk" "${WORKER_DISK}"
require_absolute_path "--cp-cloud-init-iso" "${CP_CLOUD_INIT_ISO}"
require_absolute_path "--kind-cloud-init-iso" "${KIND_CLOUD_INIT_ISO}"
require_absolute_path "--worker-cloud-init-iso" "${WORKER_CLOUD_INIT_ISO}"

if [[ "${DRY_RUN}" == true ]]; then
  printf '{"sessionId":"%s","examType":"%s","examSetId":"%s","vms":[{"name":"%s","domain":"%s","disk":"%s","cloudInitIso":"%s","vcpus":%s,"memoryMiB":%s},{"name":"%s","domain":"%s","disk":"%s","cloudInitIso":"%s","vcpus":%s,"memoryMiB":%s},{"name":"%s","domain":"%s","disk":"%s","cloudInitIso":"%s","vcpus":%s,"memoryMiB":%s}],"network":"%s","dryRun":true}\n' \
    "${SESSION_ID}" "${EXAM_TYPE}" "${EXAM_SET_ID}" \
    "${CP_NODE_NAME}" "${CP_VM_NAME}" "${CP_DISK}" "${CP_CLOUD_INIT_ISO}" "${CP_VCPUS}" "${CP_MEMORY_MIB}" \
    "${KIND_NODE_NAME}" "${KIND_VM_NAME}" "${KIND_DISK}" "${KIND_CLOUD_INIT_ISO}" "${KIND_VCPUS}" "${KIND_MEMORY_MIB}" \
    "${WORKER_NODE_NAME}" "${WORKER_VM_NAME}" "${WORKER_DISK}" "${WORKER_CLOUD_INIT_ISO}" "${WORKER_VCPUS}" "${WORKER_MEMORY_MIB}" \
    "${NETWORK}"
  exit 0
fi

if ! command -v virsh >/dev/null 2>&1; then
  echo "virsh 명령을 찾을 수 없습니다." >&2
  exit 1
fi

if ! command -v virt-install >/dev/null 2>&1; then
  echo "virt-install 명령을 찾을 수 없습니다." >&2
  exit 1
fi

require_existing_file "--cp-disk" "${CP_DISK}"
require_existing_file "--kind-disk" "${KIND_DISK}"
require_existing_file "--worker-disk" "${WORKER_DISK}"
require_existing_file "--cp-cloud-init-iso" "${CP_CLOUD_INIT_ISO}"
require_existing_file "--kind-cloud-init-iso" "${KIND_CLOUD_INIT_ISO}"
require_existing_file "--worker-cloud-init-iso" "${WORKER_CLOUD_INIT_ISO}"

if ! virsh net-info "${NETWORK}" >/dev/null 2>&1; then
  echo "libvirt network를 찾을 수 없습니다: ${NETWORK}" >&2
  exit 1
fi

if [[ "$(virsh net-info "${NETWORK}" | awk -F': *' '/^Active:/ { print $2 }')" != "yes" ]]; then
  echo "libvirt network가 활성 상태가 아닙니다: ${NETWORK}" >&2
  exit 1
fi

vm_exists() {
  local vm_name="$1"

  virsh dominfo "${vm_name}" >/dev/null 2>&1
}

if vm_exists "${CP_VM_NAME}" || vm_exists "${KIND_VM_NAME}" || vm_exists "${WORKER_VM_NAME}"; then
  echo "이미 같은 session_id의 VM이 존재합니다: ${SESSION_ID}" >&2
  exit 1
fi

CREATED_VMS=()

cleanup_partial_vms() {
  local vm_name

  for vm_name in "${CREATED_VMS[@]}"; do
    virsh destroy "${vm_name}" >/dev/null 2>&1 || true
    virsh undefine "${vm_name}" --nvram >/dev/null 2>&1 || true
  done
}
trap cleanup_partial_vms ERR

create_vm() {
  local vm_name="$1"
  local disk_path="$2"
  local cloud_init_iso="$3"
  local vcpus="$4"
  local memory_mib="$5"

  virt-install \
    --name "${vm_name}" \
    --import \
    --memory "${memory_mib}" \
    --vcpus "${vcpus}" \
    --os-variant "${OS_VARIANT}" \
    --disk "path=${disk_path},format=qcow2,bus=virtio" \
    --disk "path=${cloud_init_iso},device=cdrom,readonly=on" \
    --network "network=${NETWORK},model=virtio" \
    --graphics none \
    --console pty,target_type=serial \
    --noautoconsole \
    --wait 0

  CREATED_VMS+=("${vm_name}")
}

wait_for_vm_running() {
  local vm_name="$1"
  local deadline
  local state

  deadline=$((SECONDS + BOOT_WAIT_SECONDS))

  while (( SECONDS < deadline )); do
    state="$(virsh domstate "${vm_name}" 2>/dev/null || true)"
    if [[ "${state}" == "running" ]]; then
      return 0
    fi
    sleep 2
  done

  echo "VM이 제한 시간 안에 running 상태가 되지 않았습니다: ${vm_name}" >&2
  return 1
}

create_vm "${CP_VM_NAME}" "${CP_DISK}" "${CP_CLOUD_INIT_ISO}" "${CP_VCPUS}" "${CP_MEMORY_MIB}"
create_vm "${KIND_VM_NAME}" "${KIND_DISK}" "${KIND_CLOUD_INIT_ISO}" "${KIND_VCPUS}" "${KIND_MEMORY_MIB}"
create_vm "${WORKER_VM_NAME}" "${WORKER_DISK}" "${WORKER_CLOUD_INIT_ISO}" "${WORKER_VCPUS}" "${WORKER_MEMORY_MIB}"

wait_for_vm_running "${CP_VM_NAME}"
wait_for_vm_running "${KIND_VM_NAME}"
wait_for_vm_running "${WORKER_VM_NAME}"

trap - ERR

if [[ "${VERBOSE}" == true ]]; then
  printf '{"sessionId":"%s","vms":[{"name":"%s","domain":"%s"},{"name":"%s","domain":"%s"},{"name":"%s","domain":"%s"}],"network":"%s","created":true}\n' \
    "${SESSION_ID}" "${CP_NODE_NAME}" "${CP_VM_NAME}" "${KIND_NODE_NAME}" "${KIND_VM_NAME}" "${WORKER_NODE_NAME}" "${WORKER_VM_NAME}" "${NETWORK}"
fi
