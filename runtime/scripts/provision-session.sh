#!/usr/bin/env bash
set -euo pipefail

show_help() {
  cat <<'USAGE'
Usage: provision-session.sh --session-id <id> --exam-type <type> --exam-set-id <id> [--dry-run] [--verbose]

Creates the per-session runtime environment. This skeleton only validates CLI parsing.
USAGE
}

SESSION_ID=""
EXAM_TYPE=""
EXAM_SET_ID=""
DRY_RUN=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-id) SESSION_ID="${2:-}"; shift 2 ;;
    --exam-type) EXAM_TYPE="${2:-}"; shift 2 ;;
    --exam-set-id) EXAM_SET_ID="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --verbose) VERBOSE=true; shift ;;
    --help|-h) show_help; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; show_help >&2; exit 2 ;;
  esac
done

if [[ "$DRY_RUN" == true || "$VERBOSE" == true ]]; then
  printf '{"sessionId":"%s","examType":"%s","examSetId":"%s","dryRun":%s,"status":"ok"}\n' \
    "$SESSION_ID" "$EXAM_TYPE" "$EXAM_SET_ID" "$DRY_RUN"
fi
