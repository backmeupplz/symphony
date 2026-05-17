#!/usr/bin/env python3
"""Unit tests for openclaw_kimi_cron_sentinel.py."""

from __future__ import annotations

import unittest

import openclaw_kimi_cron_sentinel as sentinel


def check(conclusion: str = "SUCCESS", status: str = "COMPLETED") -> dict[str, str]:
    return {"conclusion": conclusion, "status": status}


class OpenClawKimiCronSentinelTest(unittest.TestCase):
    def test_parse_github_repo_accepts_repo_and_pr_urls(self) -> None:
        self.assertEqual(
            sentinel.parse_github_repo("https://github.com/backmeupplz/veydrift.git"),
            "backmeupplz/veydrift",
        )
        self.assertEqual(
            sentinel.parse_github_repo("git@github.com:backmeupplz/symphony.git"),
            "backmeupplz/symphony",
        )
        self.assertEqual(
            sentinel.parse_github_repo("https://github.com/backmeupplz/voicy/pull/179"),
            "backmeupplz/voicy",
        )
        self.assertIsNone(sentinel.parse_github_repo("/tmp/local-repo"))

    def test_dynamic_project_repos_are_inferred_from_task_text(self) -> None:
        project = {
            "tasks": [
                {
                    "title": "Ship feature",
                    "description": "Repo: https://github.com/backmeupplz/veydrift\nPR: https://github.com/backmeupplz/veydrift/pull/17",
                },
                {
                    "title": "Another",
                    "description": "Repo: git@github.com:backmeupplz/voicy.git",
                },
            ]
        }

        self.assertEqual(
            sentinel.project_repos_from_tasks(project),
            [
                {
                    "key": "backmeupplz-veydrift",
                    "name": "backmeupplz/veydrift",
                    "repo_url": "https://github.com/backmeupplz/veydrift.git",
                },
                {
                    "key": "backmeupplz-voicy",
                    "name": "backmeupplz/voicy",
                    "repo_url": "https://github.com/backmeupplz/voicy.git",
                },
            ],
        )

    def test_workflow_routes_override_dynamic_repo_inference(self) -> None:
        dynamic = [{"id": "p1", "slug": "VEY", "repos": [{"repo_url": "https://github.com/wrong/repo.git"}]}]
        configured = [{"id": "p1", "slug": "VEY", "repos": [{"repo_url": "git@github.com:backmeupplz/veydrift.git"}]}]

        merged = sentinel.merge_project_sources(dynamic, configured)

        self.assertEqual(merged[0]["repos"], configured[0]["repos"])

    def test_classifies_clean_merge_candidate(self) -> None:
        result = sentinel.classify_pr(
            {
                "mergeable": "MERGEABLE",
                "mergeStateStatus": "CLEAN",
                "statusCheckRollup": [check()],
                "reviewDecision": "APPROVED",
            },
            linked_task_status="in-review",
        )

        self.assertEqual(result["mergeability"], "clean")
        self.assertEqual(result["checks"], "passing")
        self.assertEqual(result["recommendedAction"], "merge candidate")

    def test_classifies_behind_human_review_pr_as_approval_gated(self) -> None:
        result = sentinel.classify_pr(
            {
                "title": "assets: add first Veydrift review batch",
                "mergeable": "MERGEABLE",
                "mergeStateStatus": "BEHIND",
                "statusCheckRollup": [check()],
                "reviewDecision": "APPROVED",
            },
            linked_task_status="in-review",
        )

        self.assertEqual(result["mergeability"], "behind-but-mergeable")
        self.assertIn("human-approval-gated", result["flags"])
        self.assertEqual(result["recommendedAction"], "awaiting human approval")

    def test_classifies_conflicted_done_task_pr_as_close_or_rework(self) -> None:
        result = sentinel.classify_pr(
            {
                "title": "Build OGame-inspired universe exploration UI",
                "mergeable": "CONFLICTING",
                "mergeStateStatus": "DIRTY",
                "statusCheckRollup": [check()],
                "reviewDecision": "",
            },
            linked_task_status="done",
        )

        self.assertEqual(result["mergeability"], "conflicted")
        self.assertIn("task-done-pr-open", result["flags"])
        self.assertEqual(result["recommendedAction"], "close as superseded or rework conflicts")

    def test_classifies_draft_failing_pending_and_done_task_cases(self) -> None:
        draft = sentinel.classify_pr({"isDraft": True}, linked_task_status="in-progress")
        failing = sentinel.classify_pr(
            {"mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "statusCheckRollup": [check("FAILURE")]},
            linked_task_status="in-review",
        )
        pending = sentinel.classify_pr(
            {"mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "statusCheckRollup": [check(None, "IN_PROGRESS")]},
            linked_task_status="in-review",
        )
        done_open = sentinel.classify_pr(
            {"mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "statusCheckRollup": [check()]},
            linked_task_status="done",
        )

        self.assertEqual(draft["recommendedAction"], "await draft readiness")
        self.assertEqual(failing["recommendedAction"], "fix failing checks")
        self.assertEqual(pending["recommendedAction"], "wait for checks")
        self.assertIn("task-done-pr-open", done_open["flags"])

    def test_collect_github_prs_links_task_refs_from_title_body_and_branch(self) -> None:
        original_fetch = sentinel.fetch_prs_for_repo
        try:
            sentinel.fetch_prs_for_repo = lambda owner, repo, limit=20, gh_home=None: (
                [
                    {
                        "number": 17,
                        "title": "Build UI",
                        "body": "Refs VEY-KANEO-17",
                        "headRefName": "feature/anything",
                        "mergeable": "CONFLICTING",
                        "mergeStateStatus": "DIRTY",
                        "statusCheckRollup": [check()],
                    }
                ],
                None,
            )
            prs, errors = sentinel.collect_github_prs(
                [{"slug": "VEY", "repo_url": "https://github.com/backmeupplz/veydrift.git"}],
                {
                    "VEY-KANEO-17": {
                        "identifier": "VEY-KANEO-17",
                        "status": "done",
                        "title": "Build OGame-inspired universe exploration UI",
                    }
                },
            )
        finally:
            sentinel.fetch_prs_for_repo = original_fetch

        self.assertEqual(errors, [])
        self.assertEqual(prs[0]["linkedTaskIdentifier"], "VEY-KANEO-17")
        self.assertTrue(prs[0]["taskDonePrOpen"])
        self.assertEqual(prs[0]["recommendedAction"], "close as superseded or rework conflicts")


if __name__ == "__main__":
    unittest.main()
