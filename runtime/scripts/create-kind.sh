#!/usr/bin/env bash
set -euo pipefail

show_help() {
  cat <<'USAGE'
사용법: create-kind.sh --session-id <id> --kind-host <ip> --ssh-key <path> [--ssh-user <user>] [--ssh-known-hosts <path>] [--exam-type <type>] [--exam-set-id <id>] [--session-root <dir>] [--image <image>] [--api-server-address <ip>] [--dry-run] [--verbose]

cka0002 VM 안에서 세션별 kind cluster를 생성하고 kubeconfig를 /var/lib/cka/sessions/<session_id>/kubeconfig/kind.conf로 수집한다.
전역 kind 이름은 cka0002-kind 형식을 사용한다.
Kubernetes node name은 시험 화면에서 kubeadm control-plane과 동일하게 master로 표시한다.
USAGE
}

SESSION_ID=""
EXAM_TYPE="CKA"
EXAM_SET_ID=""
SESSION_ROOT="${CKA_SESSION_ROOT:-/var/lib/cka/sessions}"
KIND_IMAGE="${CKA_KIND_IMAGE:-kindest/node:v1.30.0}"
API_SERVER_ADDRESS="${CKA_KIND_API_SERVER_ADDRESS:-127.0.0.1}"
KIND_HOST=""
SSH_USER="${CKA_VM_SSH_USER:-ubuntu}"
SSH_KEY=""
SSH_KNOWN_HOSTS=""
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
    --kind-host) KIND_HOST="${2:-}"; shift 2 ;;
    --ssh-user) SSH_USER="${2:-}"; shift 2 ;;
    --ssh-key) SSH_KEY="${2:-}"; shift 2 ;;
    --ssh-known-hosts) SSH_KNOWN_HOSTS="${2:-}"; shift 2 ;;
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

CLUSTER_NAME="cka0002-kind"
SESSION_DIR="${SESSION_ROOT}/${SESSION_ID}"
KIND_DIR="${SESSION_DIR}/kind"
KUBECONFIG_DIR="${SESSION_DIR}/kubeconfig"
KIND_CONFIG="${KIND_DIR}/kind-config.yaml"
KUBECONFIG_FILE="${KUBECONFIG_DIR}/kind.conf"
REMOTE_SESSION_DIR="/var/lib/cka/sessions/${SESSION_ID}"
REMOTE_KIND_DIR="${REMOTE_SESSION_DIR}/kind"
REMOTE_KUBECONFIG_FILE="${REMOTE_SESSION_DIR}/kubeconfig/kind.conf"
SSH_COMMON_ARGS=(
  -i "${SSH_KEY}"
  -o StrictHostKeyChecking=accept-new
)

if [[ -n "${SSH_KNOWN_HOSTS}" ]]; then
  SSH_COMMON_ARGS+=(-o "UserKnownHostsFile=${SSH_KNOWN_HOSTS}")
fi

if [[ "${DRY_RUN}" == true ]]; then
  printf '{"sessionId":"%s","examType":"%s","examSetId":"%s","clusterName":"%s","kindHost":"%s","kubeconfig":"%s","remoteKubeconfig":"%s","dryRun":true}\n' \
    "${SESSION_ID}" "${EXAM_TYPE}" "${EXAM_SET_ID}" "${CLUSTER_NAME}" "${KIND_HOST}" "${KUBECONFIG_FILE}" "${REMOTE_KUBECONFIG_FILE}"
  exit 0
fi

require_value "--kind-host" "${KIND_HOST}"
require_value "--ssh-key" "${SSH_KEY}"
require_absolute_path "--ssh-key" "${SSH_KEY}"

if [[ ! -f "${SSH_KEY}" ]]; then
  echo "SSH key 파일이 없습니다: ${SSH_KEY}" >&2
  exit 1
fi

mkdir -p "${KIND_DIR}" "${KUBECONFIG_DIR}"
chmod 700 "${KUBECONFIG_DIR}"

cat >"${KIND_CONFIG}" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
nodes:
  - role: control-plane
    image: ${KIND_IMAGE}
    labels:
      cka/session-id: ${SESSION_ID}
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          name: master
networking:
  apiServerAddress: "${API_SERVER_ADDRESS}"
EOF

ssh "${SSH_COMMON_ARGS[@]}" "${SSH_USER}@${KIND_HOST}" bash -s -- "${REMOTE_KIND_DIR}" "${REMOTE_SESSION_DIR}/kubeconfig" <<'REMOTE_MKDIR'
set -euo pipefail
mkdir -p "$1" "$2"
REMOTE_MKDIR
scp "${SSH_COMMON_ARGS[@]}" "${KIND_CONFIG}" "${SSH_USER}@${KIND_HOST}:${REMOTE_KIND_DIR}/kind-config.yaml" >/dev/null

ssh "${SSH_COMMON_ARGS[@]}" "${SSH_USER}@${KIND_HOST}" bash -s -- \
  "${SESSION_ID}" "${CLUSTER_NAME}" "${REMOTE_KIND_DIR}/kind-config.yaml" "${REMOTE_KUBECONFIG_FILE}" <<'REMOTE_SCRIPT'
set -euo pipefail

SESSION_ID="$1"
CLUSTER_NAME="$2"
KIND_CONFIG="$3"
KUBECONFIG_FILE="$4"

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

if kind get clusters | grep -Fxq "${CLUSTER_NAME}"; then
  echo "이미 같은 session_id의 kind cluster가 존재합니다: ${CLUSTER_NAME}" >&2
  exit 1
fi

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
printf '{"sessionId":"%s","clusterName":"%s","remoteKubeconfig":"%s","created":true}\n' "${SESSION_ID}" "${CLUSTER_NAME}" "${KUBECONFIG_FILE}"
REMOTE_SCRIPT

scp "${SSH_COMMON_ARGS[@]}" "${SSH_USER}@${KIND_HOST}:${REMOTE_KUBECONFIG_FILE}" "${KUBECONFIG_FILE}" >/dev/null
chmod 600 "${KUBECONFIG_FILE}"

if [[ "${VERBOSE}" == true ]]; then
  printf '{"sessionId":"%s","clusterName":"%s","kindHost":"%s","kubeconfig":"%s","created":true}\n' \
    "${SESSION_ID}" "${CLUSTER_NAME}" "${KIND_HOST}" "${KUBECONFIG_FILE}"
fi
