#!/usr/bin/env bash
set -euo pipefail

show_help() {
  cat <<'USAGE'
사용법: inject-kubeconfig.sh --session-id <id> [--exam-type <type>] [--exam-set-id <id>] [--session-root <dir>] [--dry-run] [--verbose]

VM/kind kubeconfig를 Bastion 사용자가 사용할 단일 kubeconfig로 병합한다.
USAGE
}

SESSION_ID=""
EXAM_TYPE="CKA"
EXAM_SET_ID=""
SESSION_ROOT="${CKA_SESSION_ROOT:-/var/lib/cka/sessions}"
DRY_RUN=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-id) SESSION_ID="${2:-}"; shift 2 ;;
    --exam-type) EXAM_TYPE="${2:-}"; shift 2 ;;
    --exam-set-id) EXAM_SET_ID="${2:-}"; shift 2 ;;
    --session-root) SESSION_ROOT="${2:-}"; shift 2 ;;
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
require_absolute_path "--session-root" "${SESSION_ROOT}"

KUBECONFIG_DIR="${SESSION_ROOT}/${SESSION_ID}/kubeconfig"
VM_KUBECONFIG="${KUBECONFIG_DIR}/vm-admin.conf"
KIND_KUBECONFIG="${KUBECONFIG_DIR}/kind.conf"
BASTION_KUBECONFIG="${KUBECONFIG_DIR}/config"

if [[ "${DRY_RUN}" == true ]]; then
  printf '{"sessionId":"%s","examType":"%s","examSetId":"%s","vmKubeconfig":"%s","kindKubeconfig":"%s","bastionKubeconfig":"%s","dryRun":true}\n' \
    "${SESSION_ID}" "${EXAM_TYPE}" "${EXAM_SET_ID}" "${VM_KUBECONFIG}" "${KIND_KUBECONFIG}" "${BASTION_KUBECONFIG}"
  exit 0
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl 명령을 찾을 수 없습니다." >&2
  exit 1
fi

require_existing_file "VM kubeconfig" "${VM_KUBECONFIG}"
require_existing_file "kind kubeconfig" "${KIND_KUBECONFIG}"

mkdir -p "${KUBECONFIG_DIR}"
umask 077
KUBECONFIG="${VM_KUBECONFIG}:${KIND_KUBECONFIG}" kubectl config view --flatten >"${BASTION_KUBECONFIG}"
kubectl --kubeconfig "${BASTION_KUBECONFIG}" config use-context cka-kind >/dev/null
chmod 600 "${BASTION_KUBECONFIG}"

if [[ "${VERBOSE}" == true ]]; then
  printf '{"sessionId":"%s","bastionKubeconfig":"%s","contexts":["cka-kind","cka-vm"],"injected":true}\n' \
    "${SESSION_ID}" "${BASTION_KUBECONFIG}"
fi
