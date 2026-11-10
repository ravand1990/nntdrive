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
        self.assertIn("attempt the allowed merge", text)
        self.assertIn("nice to have", text)
        self.assertIn("must not block a feature", text)
        self.assertIn("focused tests", text)
        self.assertIn("blocked-loop", text)
        self.assertNotIn("and the user approves", text)
        self.assertNotIn("use the **same github pat**", text)

    def test_worker_status_authority(self):
        text = self.read("AGENTS.md").lower()
        self.assertIn("workers may move issues between any statuses", text)
        self.assertIn("status changes never substitute", text)
        self.assertIn("end-of-run backlog sweep", text)
        other = self.read("docs/GITHUB-TASK-ISSUES.md").lower()
        self.assertIn("not permission gates", other)
        self.assertIn("requires the completion rules", " ".join(other.split()))

    def test_release_after_merge(self):
        text = self.read("AGENTS.md").lower()
        self.assertIn("release after every merge", text)
        self.assertIn("never retag", text)
        other = self.read("docs/GITHUB-TASK-ISSUES.md").lower()
        self.assertIn("post-merge release", other)
        self.assertIn("one release per merge", other)

    def test_agent_comment_format(self):
        text = self.read("AGENTS.md")
        for required in (
            "## #<issue> · <state> · <worker_id>",
            "**Done:**", "**Left:**", "**Working:**", "**Not working:**",
            "**Blockers & next:**", "**Tech:**",
            "No eligible work", "Claimed", "Ready for review",
        ):
            with self.subTest(required=required):
                self.assertIn(required, text)
        other = self.read("docs/GITHUB-TASK-ISSUES.md")
        self.assertIn("## Agent comment format", other)
        self.assertIn("**Blockers & next:**", other)

    def test_worker_retries_and_continues(self):
        text = self.read("AGENTS.md").lower()
        self.assertIn("retry at least", text)
        self.assertIn("continue with the next eligible issue", text)
        self.assertIn("no eligible work remains", text)
        other = self.read("docs/GITHUB-TASK-ISSUES.md").lower()
        self.assertIn("retry at least once", other)
        self.assertIn("next eligible task", other)

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
