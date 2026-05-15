#!/usr/bin/env bash
set -euo pipefail

show_help() {
  cat <<'USAGE'
Usage: create-vm-disks.sh --session-id <id> [--exam-type <type>] [--exam-set-id <id>] [--base-image <path>] [--session-disk-dir <dir>] [--dry-run] [--verbose]

세션별 VM 디스크를 qcow2 backing file 방식으로 생성한다.
전역 디스크 이름은 <session_id>-cka0001, <session_id>-cka0002, <session_id>-cka0003 형식을 사용한다.
USAGE
}

SESSION_ID=""
EXAM_TYPE="CKA"
EXAM_SET_ID=""
BASE_IMAGE="${CKA_VM_BASE_IMAGE:-/var/lib/cka/images/base/cka-ubuntu-22.04-kubeadm-1.30-v1/cka-ubuntu-22.04-kubeadm-1.30-v1.qcow2}"
SESSION_DISK_DIR="${CKA_VM_SESSION_DISK_DIR:-/var/lib/cka/images/sessions}"
DRY_RUN=false
VERBOSE=false
LIBVIRT_ACCESS_GROUP="${CKA_VM_LIBVIRT_ACCESS_GROUP:-kvm}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-id) SESSION_ID="${2:-}"; shift 2 ;;
    --exam-type) EXAM_TYPE="${2:-}"; shift 2 ;;
    --exam-set-id) EXAM_SET_ID="${2:-}"; shift 2 ;;
    --base-image) BASE_IMAGE="${2:-}"; shift 2 ;;
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

require_value "--session-id" "${SESSION_ID}"
require_value "--base-image" "${BASE_IMAGE}"
require_value "--session-disk-dir" "${SESSION_DISK_DIR}"
require_safe_session_id "${SESSION_ID}"
require_absolute_path "--base-image" "${BASE_IMAGE}"
require_absolute_path "--session-disk-dir" "${SESSION_DISK_DIR}"

CP_DISK="${SESSION_DISK_DIR}/${SESSION_ID}-cka0001.qcow2"
KIND_DISK="${SESSION_DISK_DIR}/${SESSION_ID}-cka0002.qcow2"
WORKER_DISK="${SESSION_DISK_DIR}/${SESSION_ID}-cka0003.qcow2"
MANIFEST="${SESSION_DISK_DIR}/${SESSION_ID}.disks"

if [[ -e "${CP_DISK}" || -e "${KIND_DISK}" || -e "${WORKER_DISK}" || -e "${MANIFEST}" ]]; then
  echo "이미 같은 session_id의 VM 디스크가 존재합니다: ${SESSION_ID}" >&2
  exit 1
fi

if [[ "${DRY_RUN}" == true ]]; then
  printf '{"sessionId":"%s","examType":"%s","examSetId":"%s","baseImage":"%s","sessionDiskDir":"%s","disks":["%s","%s","%s"],"dryRun":true}\n' \
    "${SESSION_ID}" "${EXAM_TYPE}" "${EXAM_SET_ID}" "${BASE_IMAGE}" "${SESSION_DISK_DIR}" "${CP_DISK}" "${KIND_DISK}" "${WORKER_DISK}"
  exit 0
fi

if ! command -v qemu-img >/dev/null 2>&1; then
  echo "qemu-img 명령을 찾을 수 없습니다." >&2
  exit 1
fi

if [[ ! -f "${BASE_IMAGE}" ]]; then
  echo "base image 파일이 없습니다: ${BASE_IMAGE}" >&2
  exit 1
fi

mkdir -p "${SESSION_DISK_DIR}"
if getent group "${LIBVIRT_ACCESS_GROUP}" >/dev/null 2>&1; then
  chgrp "${LIBVIRT_ACCESS_GROUP}" "${SESSION_DISK_DIR}"
fi
chmod 2770 "${SESSION_DISK_DIR}"

CREATED_DISKS=()
cleanup_partial_disks() {
  local disk

  for disk in "${CREATED_DISKS[@]}"; do
    rm -f "${disk}"
  done
  rm -f "${MANIFEST}"
}
trap cleanup_partial_disks ERR

create_overlay_disk() {
  local target="$1"

  qemu-img create -f qcow2 -F qcow2 -b "${BASE_IMAGE}" "${target}" >/dev/null
  if getent group "${LIBVIRT_ACCESS_GROUP}" >/dev/null 2>&1; then
    chgrp "${LIBVIRT_ACCESS_GROUP}" "${target}"
  fi
  chmod 0660 "${target}"
  CREATED_DISKS+=("${target}")
}

create_overlay_disk "${CP_DISK}"
create_overlay_disk "${KIND_DISK}"
create_overlay_disk "${WORKER_DISK}"

{
  printf 'session_id=%s\n' "${SESSION_ID}"
  printf 'exam_type=%s\n' "${EXAM_TYPE}"
  printf 'exam_set_id=%s\n' "${EXAM_SET_ID}"
  printf 'base_image=%s\n' "${BASE_IMAGE}"
  printf 'cka0001_disk=%s\n' "${CP_DISK}"
  printf 'cka0002_disk=%s\n' "${KIND_DISK}"
  printf 'cka0003_disk=%s\n' "${WORKER_DISK}"
} > "${MANIFEST}"
if getent group "${LIBVIRT_ACCESS_GROUP}" >/dev/null 2>&1; then
  chgrp "${LIBVIRT_ACCESS_GROUP}" "${MANIFEST}"
fi
chmod 0660 "${MANIFEST}"

trap - ERR

if [[ "${VERBOSE}" == true ]]; then
  printf '{"sessionId":"%s","baseImage":"%s","disks":["%s","%s","%s"],"created":true}\n' \
    "${SESSION_ID}" "${BASE_IMAGE}" "${CP_DISK}" "${KIND_DISK}" "${WORKER_DISK}"
fi
