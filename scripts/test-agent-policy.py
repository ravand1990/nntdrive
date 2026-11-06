#!/usr/bin/env python3
"""Static guardrails for the shared NNTDrive agent-governance contract.

Run from any directory. Standard library only; no GitHub credentials needed.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class AgentPolicyTests(unittest.TestCase):
    def read(self, path: str) -> str:
        return (ROOT / path).read_text(encoding="utf-8")

    def test_shared_entrypoint(self):
        text = self.read("AGENTS.md")
        for required in (
            "Codex", "OpenCode", "Hermes", "docs/GITHUB-TASK-ISSUES.md",
            "docs/CI.md", "docs/SECURITY.md", "worker_id", "Blocked",
            "Ready For Review", "account_id", "manual", "exact-head",
        ):
            with self.subTest(required=required):
                self.assertIn(required.lower(), text.lower())

    def test_no_unconditional_claim_or_merge(self):
        text = self.read("AGENTS.md").lower()
        self.assertRegex(text, r"not\s+atomic locks")
        self.assertIn("separate", text)
        self.assertIn("all applicable", text)
        self.assertIn("attempt the allowed merge", text)
        self.assertIn("blocked-loop", text)
        self.assertNotIn("and the user approves", text)
        self.assertNotIn("use the **same github pat**", text)

    def test_new_issue_templates_default_to_backlog(self):
        for file in ("task.yml", "bug.yml"):
            with self.subTest(file=file):
                text = self.read(".github/ISSUE_TEMPLATE/" + file)
                self.assertIn("Backlog", text)
                self.assertNotIn("Scheduling readiness", text)
                self.assertNotIn('"status:ready"', text)
                self.assertNotIn("        - Ready", text)

    def test_other_docs_do_not_copy_worker_prompt(self):
        text = self.read("docs/CONTAINER-DEVELOPMENT.md")
        self.assertIn("AGENTS.md", text)
        self.assertNotIn("never close the issue until acceptance", text.lower())

    def test_client_never_uses_agent_write_credentials(self):
        text = self.read("docs/CLIENTS.md").lower()
        self.assertNotIn("same github pat", text)
        self.assertIn("read-only", text)

    def test_ci_runs_policy_contract(self):
        text = self.read(".github/workflows/ci.yml")
        self.assertIn("python3 scripts/test-agent-policy.py", text)


if __name__ == "__main__":
    unittest.main()
