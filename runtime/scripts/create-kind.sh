#!/usr/bin/env bash
set -euo pipefail

show_help() {
  cat <<'USAGE'
사용법: create-kind.sh --session-id <id> [--exam-type <type>] [--exam-set-id <id>] [--session-root <dir>] [--image <image>] [--api-server-address <ip>] [--dry-run] [--verbose]

세션별 kind cluster를 생성하고 kubeconfig를 /var/lib/cka/sessions/<session_id>/kubeconfig/kind.conf에 분리 저장한다.
USAGE
}

SESSION_ID=""
EXAM_TYPE="CKA"
EXAM_SET_ID=""
SESSION_ROOT="${CKA_SESSION_ROOT:-/var/lib/cka/sessions}"
KIND_IMAGE="${CKA_KIND_IMAGE:-kindest/node:v1.30.0}"
API_SERVER_ADDRESS="${CKA_KIND_API_SERVER_ADDRESS:-127.0.0.1}"
DRY_RUN=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-id) SESSION_ID="${2:-}"; shift 2 ;;
    --exam-type) EXAM_TYPE="${2:-}"; shift 2 ;;
    --exam-set-id) EXAM_SET_ID="${2:-}"; shift 2 ;;
    --session-root) SESSION_ROOT="${2:-}"; shift 2 ;;
    --image) KIND_IMAGE="${2:-}"; shift 2 ;;
    --api-server-address) API_SERVER_ADDRESS="${2:-}"; shift 2 ;;
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
require_safe_session_id "${SESSION_ID}"
require_absolute_path "--session-root" "${SESSION_ROOT}"

CLUSTER_NAME="cka-${SESSION_ID}-kind"
SESSION_DIR="${SESSION_ROOT}/${SESSION_ID}"
KIND_DIR="${SESSION_DIR}/kind"
KUBECONFIG_DIR="${SESSION_DIR}/kubeconfig"
KIND_CONFIG="${KIND_DIR}/kind-config.yaml"
KUBECONFIG_FILE="${KUBECONFIG_DIR}/kind.conf"

if [[ "${DRY_RUN}" == true ]]; then
  printf '{"sessionId":"%s","examType":"%s","examSetId":"%s","clusterName":"%s","kubeconfig":"%s","dryRun":true}\n' \
    "${SESSION_ID}" "${EXAM_TYPE}" "${EXAM_SET_ID}" "${CLUSTER_NAME}" "${KUBECONFIG_FILE}"
  exit 0
fi

if ! command -v kind >/dev/null 2>&1; then
  echo "kind 명령을 찾을 수 없습니다." >&2
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl 명령을 찾을 수 없습니다." >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker 명령을 찾을 수 없습니다." >&2
  exit 1
fi

mkdir -p "${KIND_DIR}" "${KUBECONFIG_DIR}"
chmod 700 "${KUBECONFIG_DIR}"

if kind get clusters | grep -Fxq "${CLUSTER_NAME}"; then
  echo "이미 같은 session_id의 kind cluster가 존재합니다: ${CLUSTER_NAME}" >&2
  exit 1
fi

cat >"${KIND_CONFIG}" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
nodes:
  - role: control-plane
    image: ${KIND_IMAGE}
    labels:
      cka/session-id: ${SESSION_ID}
networking:
  apiServerAddress: "${API_SERVER_ADDRESS}"
EOF

kind create cluster --name "${CLUSTER_NAME}" --config "${KIND_CONFIG}" --kubeconfig "${KUBECONFIG_FILE}"
kubectl --kubeconfig "${KUBECONFIG_FILE}" config rename-context "kind-${CLUSTER_NAME}" cka-kind
kubectl --kubeconfig "${KUBECONFIG_FILE}" config use-context cka-kind >/dev/null
chmod 600 "${KUBECONFIG_FILE}"

NODE_CONTAINER="${CLUSTER_NAME}-control-plane"
docker update \
  --cpus "${CKA_KIND_CPUS:-2}" \
  --memory "${CKA_KIND_MEMORY:-3g}" \
  --memory-swap "${CKA_KIND_MEMORY_SWAP:-${CKA_KIND_MEMORY:-3g}}" \
  --pids-limit "${CKA_KIND_PIDS_LIMIT:-2048}" \
  "${NODE_CONTAINER}" >/dev/null

kubectl --kubeconfig "${KUBECONFIG_FILE}" wait --for=condition=Ready nodes --all --timeout=180s

if [[ "${VERBOSE}" == true ]]; then
  printf '{"sessionId":"%s","clusterName":"%s","kubeconfig":"%s","created":true}\n' \
    "${SESSION_ID}" "${CLUSTER_NAME}" "${KUBECONFIG_FILE}"
fi
