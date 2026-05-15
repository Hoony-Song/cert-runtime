from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from http import HTTPStatus
from pathlib import Path
from unittest.mock import patch

from runtime.agent.grading_agent import AgentConfig, GradingAgentError, require_safe_id, run_grade


class GradingAgentTest(unittest.TestCase):
    def test_rejects_unsafe_session_id(self) -> None:
        with self.assertRaises(GradingAgentError) as caught:
            require_safe_id("../secret", "sessionId")

        self.assertEqual(caught.exception.status, HTTPStatus.BAD_REQUEST)
        self.assertFalse(caught.exception.retryable)

    def test_run_grade_returns_script_json(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            script = root / "runtime" / "scripts" / "grade-session.sh"
            script.parent.mkdir(parents=True)
            script.write_text("#!/usr/bin/env bash\n", encoding="utf-8")

            config = AgentConfig(root, "127.0.0.1", 18080, 30)
            completed = subprocess.CompletedProcess(
                args=[],
                returncode=0,
                stdout=json.dumps({"status": "FINISHED", "totalScore": 10, "maxScore": 10}),
                stderr="",
            )

            with patch("runtime.agent.grading_agent.subprocess.run", return_value=completed) as mocked:
                result = run_grade(
                    config,
                    {
                        "sessionId": "sess_001",
                        "examType": "CKA",
                        "examSetId": "cka-mock-001",
                    },
                )

        self.assertEqual(result["status"], "FINISHED")
        mocked.assert_called_once()

    def test_run_grade_maps_nonzero_to_failure_contract(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            script = root / "runtime" / "scripts" / "grade-session.sh"
            script.parent.mkdir(parents=True)
            script.write_text("#!/usr/bin/env bash\n", encoding="utf-8")

            config = AgentConfig(root, "127.0.0.1", 18080, 30)
            completed = subprocess.CompletedProcess(args=[], returncode=1, stdout="", stderr="missing kubeconfig")

            with patch("runtime.agent.grading_agent.subprocess.run", return_value=completed):
                result = run_grade(
                    config,
                    {
                        "sessionId": "sess_001",
                        "examType": "CKA",
                        "examSetId": "cka-mock-001",
                    },
                )

        self.assertEqual(result["status"], "GRADING_FAILED")
        self.assertEqual(result["errorCode"], "GRADE_SCRIPT_FAILED")
        self.assertTrue(result["retryable"])


if __name__ == "__main__":
    unittest.main()
