#!/usr/bin/env bash
set -euo pipefail

show_help() {
  cat <<'USAGE'
사용법: create-bastion.sh --session-id <id> [--exam-type <type>] [--exam-set-id <id>] [--session-root <dir>] [--image <image>] [--dry-run] [--verbose]

세션별 Bastion container를 생성하고 kubeconfig와 문제 파일 디렉토리를 읽기 전용으로 연결한다.
USAGE
}

SESSION_ID=""
EXAM_TYPE="CKA"
EXAM_SET_ID=""
SESSION_ROOT="${CKA_SESSION_ROOT:-/var/lib/cka/sessions}"
IMAGE="${CKA_BASTION_IMAGE:-cka-bastion:local}"
CPU_LIMIT="${CKA_BASTION_CPUS:-1}"
MEMORY_LIMIT="${CKA_BASTION_MEMORY:-1g}"
PIDS_LIMIT="${CKA_BASTION_PIDS_LIMIT:-512}"
VM_NETWORK_CIDR="${CKA_VM_NETWORK_CIDR:-192.168.122.0/24}"
VM_NETWORK_IFACE="${CKA_VM_NETWORK_IFACE:-virbr0}"
DRY_RUN=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-id) SESSION_ID="${2:-}"; shift 2 ;;
    --exam-type) EXAM_TYPE="${2:-}"; shift 2 ;;
    --exam-set-id) EXAM_SET_ID="${2:-}"; shift 2 ;;
    --session-root) SESSION_ROOT="${2:-}"; shift 2 ;;
    --image) IMAGE="${2:-}"; shift 2 ;;
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

require_existing_dir() {
  local name="$1"
  local value="$2"

  if [[ ! -d "${value}" ]]; then
    echo "${name} 디렉토리가 없습니다: ${value}" >&2
    exit 1
  fi
}

require_value "--session-id" "${SESSION_ID}"
require_safe_session_id "${SESSION_ID}"
require_absolute_path "--session-root" "${SESSION_ROOT}"

CONTAINER_NAME="cka-${SESSION_ID}-bastion"
SESSION_DIR="${SESSION_ROOT}/${SESSION_ID}"
BASTION_DIR="${SESSION_DIR}/bastion"
KUBECONFIG_DIR="${SESSION_DIR}/kubeconfig"
PROBLEMS_DIR="${SESSION_DIR}/problems"
WORK_DIR="${SESSION_DIR}/work"

if [[ "${DRY_RUN}" == true ]]; then
  printf '{"sessionId":"%s","examType":"%s","examSetId":"%s","containerName":"%s","image":"%s","dryRun":true}\n' \
    "${SESSION_ID}" "${EXAM_TYPE}" "${EXAM_SET_ID}" "${CONTAINER_NAME}" "${IMAGE}"
  exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker 명령을 찾을 수 없습니다." >&2
  exit 1
fi

require_existing_dir "kubeconfig" "${KUBECONFIG_DIR}"
mkdir -p "${BASTION_DIR}" "${PROBLEMS_DIR}" "${WORK_DIR}"
chown 1000:1000 "${BASTION_DIR}" "${WORK_DIR}"
chmod 0755 "${KUBECONFIG_DIR}" "${PROBLEMS_DIR}"
find "${KUBECONFIG_DIR}" -maxdepth 1 -type f -name '*.conf' -exec chmod 0644 {} +
if [[ -f "${KUBECONFIG_DIR}/config" ]]; then
  chmod 0644 "${KUBECONFIG_DIR}/config"
fi

if docker ps -a --format '{{.Names}}' | grep -Fxq "${CONTAINER_NAME}"; then
  echo "이미 같은 session_id의 Bastion container가 존재합니다: ${CONTAINER_NAME}" >&2
  exit 1
fi

docker run -d \
  --name "${CONTAINER_NAME}" \
  --hostname "bastion-${SESSION_ID}" \
  --label "cka.session_id=${SESSION_ID}" \
  --label "cka.exam_type=${EXAM_TYPE}" \
  --cpus "${CPU_LIMIT}" \
  --memory "${MEMORY_LIMIT}" \
  --pids-limit "${PIDS_LIMIT}" \
  --security-opt no-new-privileges \
  --cap-drop ALL \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=128m \
  --tmpfs /run:rw,noexec,nosuid,size=64m \
  --mount "type=bind,src=${KUBECONFIG_DIR},dst=/home/cka/.kube,readonly" \
  --mount "type=bind,src=${PROBLEMS_DIR},dst=/home/cka/problems,readonly" \
  --mount "type=bind,src=${WORK_DIR},dst=/home/cka/work" \
  --workdir /home/cka/work \
  "${IMAGE}" >/dev/null

BASTION_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${CONTAINER_NAME}")"
if [[ -n "${BASTION_IP}" ]] && command -v iptables >/dev/null 2>&1; then
  iptables -C LIBVIRT_FWI -s "${BASTION_IP}/32" -d "${VM_NETWORK_CIDR}" -o "${VM_NETWORK_IFACE}" -j ACCEPT >/dev/null 2>&1 \
    || iptables -I LIBVIRT_FWI 1 -s "${BASTION_IP}/32" -d "${VM_NETWORK_CIDR}" -o "${VM_NETWORK_IFACE}" -j ACCEPT
fi

if [[ "${VERBOSE}" == true ]]; then
  printf '{"sessionId":"%s","containerName":"%s","image":"%s","containerIp":"%s","created":true}\n' \
    "${SESSION_ID}" "${CONTAINER_NAME}" "${IMAGE}" "${BASTION_IP}"
fi
