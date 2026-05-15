#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
from dataclasses import dataclass
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

SAFE_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")


@dataclass(frozen=True)
class AgentConfig:
    runtime_root: Path
    host: str
    port: int
    timeout_seconds: int

    @property
    def grade_script(self) -> Path:
        return self.runtime_root / "runtime" / "scripts" / "grade-session.sh"


class GradingAgentError(RuntimeError):
    def __init__(self, status: HTTPStatus, error_code: str, message: str, *, retryable: bool) -> None:
        super().__init__(message)
        self.status = status
        self.error_code = error_code
        self.retryable = retryable


def require_safe_id(value: str, field_name: str) -> None:
    if not SAFE_ID_PATTERN.fullmatch(value):
        raise GradingAgentError(
            HTTPStatus.BAD_REQUEST,
            "INVALID_REQUEST",
            f"{field_name} 값이 안전하지 않습니다.",
            retryable=False,
        )


def load_json_body(handler: BaseHTTPRequestHandler) -> dict[str, Any]:
    content_length = int(handler.headers.get("Content-Length", "0"))
    if content_length <= 0:
        raise GradingAgentError(HTTPStatus.BAD_REQUEST, "INVALID_REQUEST", "요청 본문이 비어 있습니다.", retryable=False)
    raw = handler.rfile.read(content_length)
    try:
        data = json.loads(raw.decode("utf-8"))
    except json.JSONDecodeError as exc:
        raise GradingAgentError(HTTPStatus.BAD_REQUEST, "INVALID_JSON", "요청 JSON을 해석하지 못했습니다.", retryable=False) from exc
    if not isinstance(data, dict):
        raise GradingAgentError(HTTPStatus.BAD_REQUEST, "INVALID_REQUEST", "요청 본문은 object여야 합니다.", retryable=False)
    return data


def run_grade(config: AgentConfig, payload: dict[str, Any]) -> dict[str, Any]:
    session_id = str(payload.get("sessionId") or "")
    exam_type = str(payload.get("examType") or "CKA")
    exam_set_id = str(payload.get("examSetId") or "")

    require_safe_id(session_id, "sessionId")
    require_safe_id(exam_type, "examType")
    require_safe_id(exam_set_id, "examSetId")

    if not config.grade_script.exists():
        raise GradingAgentError(
            HTTPStatus.INTERNAL_SERVER_ERROR,
            "GRADE_SCRIPT_NOT_FOUND",
            f"grade script가 없습니다: {config.grade_script}",
            retryable=True,
        )

    command = [
        str(config.grade_script),
        "--session-id",
        session_id,
        "--exam-type",
        exam_type,
        "--exam-set-id",
        exam_set_id,
    ]
    completed = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        timeout=config.timeout_seconds,
    )
    if completed.returncode != 0:
        return {
            "status": "GRADING_FAILED",
            "errorCode": "GRADE_SCRIPT_FAILED",
            "message": (completed.stderr or completed.stdout or "grade script failed")[:1000],
            "retryable": True,
        }
    try:
        result = json.loads(completed.stdout)
    except json.JSONDecodeError:
        return {
            "status": "GRADING_FAILED",
            "errorCode": "AGENT_INVALID_RESPONSE",
            "message": "grade script가 JSON이 아닌 출력을 반환했습니다.",
            "retryable": True,
        }
    return result if isinstance(result, dict) else {
        "status": "GRADING_FAILED",
        "errorCode": "AGENT_INVALID_RESPONSE",
        "message": "grade script 결과는 object여야 합니다.",
        "retryable": True,
    }


def make_handler(config: AgentConfig) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        server_version = "CertRuntimeGradingAgent/0.1"

        def do_GET(self) -> None:
            if self.path != "/healthz":
                self.send_json(HTTPStatus.NOT_FOUND, {"status": "NOT_FOUND"})
                return
            self.send_json(HTTPStatus.OK, {"status": "OK"})

        def do_POST(self) -> None:
            if self.path != "/grade":
                self.send_json(HTTPStatus.NOT_FOUND, {"status": "NOT_FOUND"})
                return
            try:
                payload = load_json_body(self)
                result = run_grade(config, payload)
                self.send_json(HTTPStatus.OK, result)
            except subprocess.TimeoutExpired:
                self.send_json(
                    HTTPStatus.GATEWAY_TIMEOUT,
                    {
                        "status": "GRADING_FAILED",
                        "errorCode": "AGENT_TIMEOUT",
                        "message": "채점 시간이 초과되었습니다.",
                        "retryable": True,
                    },
                )
            except GradingAgentError as exc:
                self.send_json(
                    exc.status,
                    {
                        "status": "GRADING_FAILED",
                        "errorCode": exc.error_code,
                        "message": str(exc),
                        "retryable": exc.retryable,
                    },
                )

        def log_message(self, fmt: str, *args: Any) -> None:
            print(f"{self.address_string()} - {fmt % args}")

        def send_json(self, status_code: HTTPStatus, body: dict[str, Any]) -> None:
            raw = json.dumps(body, ensure_ascii=False).encode("utf-8")
            self.send_response(status_code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

    return Handler


def parse_args() -> AgentConfig:
    parser = argparse.ArgumentParser(description="Runtime-local grading agent")
    parser.add_argument("--runtime-root", default=os.getenv("CKA_RUNTIME_ROOT", "/var/lib/cka"))
    parser.add_argument("--host", default=os.getenv("CKA_GRADING_AGENT_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=int(os.getenv("CKA_GRADING_AGENT_PORT", "18080")))
    parser.add_argument("--timeout-seconds", type=int, default=int(os.getenv("CKA_GRADING_AGENT_TIMEOUT", "180")))
    args = parser.parse_args()
    return AgentConfig(Path(args.runtime_root), args.host, args.port, args.timeout_seconds)


def main() -> None:
    config = parse_args()
    server = ThreadingHTTPServer((config.host, config.port), make_handler(config))
    print(f"grading agent listening on {config.host}:{config.port}")
    server.serve_forever()


if __name__ == "__main__":
    main()
