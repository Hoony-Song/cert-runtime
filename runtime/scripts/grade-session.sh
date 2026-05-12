#!/usr/bin/env bash
set -euo pipefail

show_help() {
  cat <<'USAGE'
사용법: grade-session.sh --session-id <id> --exam-type <type> --exam-set-id <id> [--grading-file <path>] [--session-root <dir>] [--output-file <path>] [--dry-run] [--verbose]

question-bank grading DSL 파일을 입력으로 받아 kubernetes/command 채점을 실행하고 결과 JSON을 출력한다.
USAGE
}

SESSION_ID=""
EXAM_TYPE="CKA"
EXAM_SET_ID=""
GRADING_FILE=""
SESSION_ROOT="${CKA_SESSION_ROOT:-/var/lib/cka/sessions}"
OUTPUT_FILE=""
DRY_RUN=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-id) SESSION_ID="${2:-}"; shift 2 ;;
    --exam-type) EXAM_TYPE="${2:-}"; shift 2 ;;
    --exam-set-id) EXAM_SET_ID="${2:-}"; shift 2 ;;
    --grading-file) GRADING_FILE="${2:-}"; shift 2 ;;
    --session-root) SESSION_ROOT="${2:-}"; shift 2 ;;
    --output-file) OUTPUT_FILE="${2:-}"; shift 2 ;;
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
require_value "--exam-type" "${EXAM_TYPE}"
require_value "--exam-set-id" "${EXAM_SET_ID}"
require_safe_session_id "${SESSION_ID}"
require_absolute_path "--session-root" "${SESSION_ROOT}"

SESSION_DIR="${SESSION_ROOT}/${SESSION_ID}"
KUBECONFIG_FILE="${SESSION_DIR}/kubeconfig/config"

if [[ -z "${OUTPUT_FILE}" ]]; then
  OUTPUT_FILE="${SESSION_DIR}/artifacts/grade-result.json"
fi

if [[ "${DRY_RUN}" == true ]]; then
  printf '{"sessionId":"%s","examType":"%s","examSetId":"%s","gradingFile":"%s","outputFile":"%s","dryRun":true}\n' \
    "${SESSION_ID}" "${EXAM_TYPE}" "${EXAM_SET_ID}" "${GRADING_FILE}" "${OUTPUT_FILE}"
  exit 0
fi

require_value "--grading-file" "${GRADING_FILE}"
require_absolute_path "--grading-file" "${GRADING_FILE}"
require_absolute_path "--output-file" "${OUTPUT_FILE}"

if [[ ! -f "${GRADING_FILE}" ]]; then
  echo "grading 파일이 없습니다: ${GRADING_FILE}" >&2
  exit 1
fi

if [[ ! -f "${KUBECONFIG_FILE}" ]]; then
  echo "세션 kubeconfig 파일이 없습니다: ${KUBECONFIG_FILE}" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 명령을 찾을 수 없습니다." >&2
  exit 1
fi

mkdir -p "$(dirname "${OUTPUT_FILE}")"

export CKA_SESSION_ID="${SESSION_ID}"
export CKA_EXAM_TYPE="${EXAM_TYPE}"
export CKA_EXAM_SET_ID="${EXAM_SET_ID}"
export CKA_GRADING_FILE="${GRADING_FILE}"
export CKA_KUBECONFIG_FILE="${KUBECONFIG_FILE}"
export CKA_OUTPUT_FILE="${OUTPUT_FILE}"
export CKA_VERBOSE="${VERBOSE}"

python3 <<'PY'
import json
import os
import shlex
import subprocess
import sys
from datetime import datetime, timezone

try:
    import yaml
except Exception as exc:
    print(f"PyYAML을 불러오지 못했습니다: {exc}", file=sys.stderr)
    sys.exit(1)


def now():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def load_grading(path):
    with open(path, "r", encoding="utf-8") as handle:
        data = yaml.safe_load(handle) or {}
    if "grading" in data and isinstance(data["grading"], dict):
        data = data["grading"]
    checks = data.get("checks", [])
    if not isinstance(checks, list):
        raise ValueError("grading.checks는 list여야 합니다.")
    return checks


def run_command(command, timeout=30):
    if isinstance(command, str):
        args = shlex.split(command)
    else:
        args = [str(item) for item in command]
    completed = subprocess.run(args, text=True, capture_output=True, timeout=timeout, check=False)
    return completed.returncode, completed.stdout, completed.stderr


def run_kubectl(check):
    resource = check.get("resource", {})
    context = check.get("context") or check.get("environment", {}).get("context") or "cka-kind"
    namespace = check.get("namespace") or check.get("environment", {}).get("namespace")
    kind = resource.get("kind") or check.get("kind")
    name = resource.get("name")
    output = check.get("output", "json")

    if not kind:
        raise ValueError("kubernetes check에는 resource.kind가 필요합니다.")

    args = [
        "kubectl",
        "--kubeconfig",
        os.environ["CKA_KUBECONFIG_FILE"],
        "--context",
        context,
    ]
    if namespace:
        args.extend(["-n", namespace])
    args.extend(["get", kind])
    if name:
        args.append(name)
    args.extend(["-o", output])

    return run_command(args, timeout=int(check.get("timeoutSeconds", 30)))


def evaluate_kubernetes(check):
    rc, stdout, stderr = run_kubectl(check)
    condition = check.get("condition", {})
    passed = rc == 0
    detail = stdout.strip() if stdout.strip() else stderr.strip()

    if condition.get("exists") is True:
        passed = rc == 0
    elif condition.get("exists") is False:
        passed = rc != 0
    elif "contains" in condition:
        passed = condition["contains"] in stdout
    elif "equals" in condition:
        passed = stdout.strip() == str(condition["equals"])

    return passed, rc, detail


def evaluate_command(check):
    command = check.get("command")
    if not command:
        raise ValueError("command check에는 command가 필요합니다.")

    rc, stdout, stderr = run_command(command, timeout=int(check.get("timeoutSeconds", 30)))
    expected_rc = int(check.get("expectedExitCode", 0))
    passed = rc == expected_rc

    if "contains" in check:
        passed = passed and str(check["contains"]) in stdout
    if "equals" in check:
        passed = passed and stdout.strip() == str(check["equals"])

    detail = stdout.strip() if stdout.strip() else stderr.strip()
    return passed, rc, detail


def main():
    checks = load_grading(os.environ["CKA_GRADING_FILE"])
    results = []
    earned = 0

    for index, check in enumerate(checks, start=1):
        name = check.get("name", f"check-{index}")
        check_type = check.get("type") or check.get("gradingType") or "kubernetes"
        score = int(check.get("score", 1))
        try:
            if check_type == "kubernetes":
                passed, rc, detail = evaluate_kubernetes(check)
            elif check_type == "command":
                passed, rc, detail = evaluate_command(check)
            else:
                raise ValueError(f"지원하지 않는 grading type입니다: {check_type}")
            if passed:
                earned += score
            results.append({
                "name": name,
                "type": check_type,
                "score": score,
                "earnedScore": score if passed else 0,
                "passed": passed,
                "exitCode": rc,
                "detail": detail[:1000],
            })
        except Exception as exc:
            results.append({
                "name": name,
                "type": check_type,
                "score": score,
                "earnedScore": 0,
                "passed": False,
                "exitCode": 1,
                "detail": str(exc),
            })

    total = sum(item["score"] for item in results)
    output = {
        "sessionId": os.environ["CKA_SESSION_ID"],
        "examType": os.environ["CKA_EXAM_TYPE"],
        "examSetId": os.environ["CKA_EXAM_SET_ID"],
        "status": "FINISHED",
        "gradedAt": now(),
        "totalScore": total,
        "earnedScore": earned,
        "passedChecks": sum(1 for item in results if item["passed"]),
        "totalChecks": len(results),
        "results": results,
    }

    with open(os.environ["CKA_OUTPUT_FILE"], "w", encoding="utf-8") as handle:
        json.dump(output, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    print(json.dumps(output, ensure_ascii=False))


main()
PY
