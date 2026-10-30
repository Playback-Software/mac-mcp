"""Policy transaction regressions. All CLI and keychain calls are mocked; no eval or GUI suite runs here."""
import base64
import hashlib
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import tasks


class PolicyTransactionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        root = Path(self.directory.name)
        self.policy = root / "policy.json"
        self.approved_copy = root / "approved.json"
        self.state = root / "state"
        self.original = b'{"script":{"allowed_apps":[]},"clipboard_read":false}'
        self.record = self.make_record(self.original)
        self.saved_record = self.record
        self.events = []
        self.pending = False
        self.fail_approval = False
        self.fail_restore = False   # the approval that restores the saved policy fails
        self.approvals = 0
        self.before_approve = None   # an edit made between the harness's write and its approval
        self.after_approve = None
        self.patches = [patch.object(tasks, "POLICY", self.policy), patch.object(tasks, "APPROVED_POLICY", self.approved_copy),
                        patch.object(tasks, "STATE", self.state), patch.object(tasks.subprocess, "run", self.run_command),
                        patch.object(tasks, "keychain_records", self.keychain)]
        for item in self.patches:
            item.start()
        self.addCleanup(self.directory.cleanup)
        self.addCleanup(lambda: [item.stop() for item in reversed(self.patches)])

    def make_record(self, policy):
        return json.dumps({"format": 1, "policy": base64.b64encode(policy).decode(),
                           "approved_at": "2026-10-01T00:00:00Z", "by": "test"}).encode()

    def keychain(self):
        self.assertGreater(tasks._policy_depth, 0)
        # An older record that can't be read is ignored; the newest is the one in force.
        return [("approved-policy", b"garbage", 1.0), (f"approval.{self.approvals + 1}.test", self.record, 2.0)]

    def run_command(self, command, **kwargs):
        if command[0] == "osascript":
            return subprocess.CompletedProcess(command, 1, "", "not authorized")
        action = command[2]
        if action == "approve" and self.before_approve:
            edit, self.before_approve = self.before_approve, None
            edit()
        self.events.append((action, self.policy.read_bytes() if self.policy.exists() else None))
        if action == "status":
            return subprocess.CompletedProcess(command, 3 if self.pending else 0, "waiting" if self.pending else "in force: user", "")
        if self.fail_approval:
            self.fail_approval = False
            return subprocess.CompletedProcess(command, 1, "", "mock approval failure")
        self.approvals += 1
        if self.fail_restore and self.approvals == 2:
            return subprocess.CompletedProcess(command, 1, "", "mock restore failure")
        # As `mac-mcp policy approve --expect-sha256` does: only the bytes the caller named.
        if command[3:4] == ["--expect-sha256"] and hashlib.sha256(self.policy.read_bytes()).hexdigest() != command[4]:
            return subprocess.CompletedProcess(command, 1, "", "Nothing was approved: policy.json has SHA-256 …")
        self.record = self.make_record(self.policy.read_bytes())
        if self.after_approve:
            edit, self.after_approve = self.after_approve, None
            edit()
        return subprocess.CompletedProcess(command, 0, "approved", "")

    @staticmethod
    def allow_notes(policy):
        policy.setdefault("script", {})["allowed_apps"] = ["com.apple.Notes"]
        return policy

    def test_notes_fallback_without_user_file_restores_approval(self):
        with patch.object(tasks, "mac_mcp", return_value="note body"):
            self.assertEqual(tasks.notes_script("get body"), "note body")
        self.assertFalse(self.policy.exists())
        self.assertEqual(self.record, self.saved_record)
        self.assertEqual(self.approved_copy.read_bytes(), self.original)
        self.assertEqual(list(self.state.glob("policy-backup-*")), [])

    def test_pending_changes_are_never_approved(self):
        self.pending = True
        self.policy.write_bytes(b'{"deny_apps":[]}')
        with self.assertRaisesRegex(RuntimeError, "unapproved changes"):
            with tasks.temporary_policy(self.allow_notes):
                self.fail("pending changes ran")
        self.assertEqual([event[0] for event in self.events], ["status"])
        self.assertEqual(self.record, self.saved_record)
        self.assertEqual(self.policy.read_bytes(), b'{"deny_apps":[]}')

    def test_failed_approval_prevents_the_call_and_restores(self):
        self.policy.write_bytes(self.original)
        self.fail_approval = True
        with self.assertRaisesRegex(RuntimeError, "approval failure"):
            with tasks.temporary_policy(self.allow_notes):
                self.fail("failed approval ran")
        self.assertEqual(self.record, self.saved_record)
        self.assertEqual(self.policy.read_bytes(), self.original)

    def test_restore_failure_keeps_both_backups_and_staged_safe_policy(self):
        self.policy.write_bytes(self.original)
        self.fail_restore = True
        with self.assertRaisesRegex(RuntimeError, "backups kept"):
            with tasks.temporary_policy(self.allow_notes):
                pass
        backup, = self.state.glob("policy-backup-*")
        self.assertEqual((backup / "policy.json").read_bytes(), self.original)
        self.assertEqual((backup / "approval.json").read_bytes(), self.saved_record)
        self.assertEqual(self.policy.read_bytes(), self.original)

    def test_original_file_returns_after_the_approved_record(self):
        # Different bytes from approval, but equivalent settings: preserve both records exactly.
        saved = json.dumps(json.loads(self.original), indent=2).encode()
        self.policy.write_bytes(saved)
        with tasks.temporary_policy(self.allow_notes):
            self.assertTrue(list(self.state.glob("policy-backup-*")))
        self.assertEqual(self.events[-1], ("approve", self.original))
        self.assertEqual(self.policy.read_bytes(), saved)
        self.assertEqual(self.record, self.saved_record)

    def test_an_edit_before_approval_is_never_approved(self):
        self.policy.write_bytes(self.original)
        broader = b'{"deny_apps":[],"script":{"allowed_apps":["com.apple.Terminal"]}}'
        self.before_approve = lambda: self.policy.write_bytes(broader)
        with self.assertRaisesRegex(RuntimeError, "Nothing was approved"):
            with tasks.temporary_policy(self.allow_notes):
                self.fail("an unexpected file was approved")
        self.assertEqual(self.record, self.saved_record)
        self.assertEqual(self.policy.read_bytes(), self.original)

    def test_an_edit_right_after_approval_stops_the_run(self):
        self.policy.write_bytes(self.original)
        self.after_approve = lambda: self.policy.write_bytes(b'{"deny_apps":[]}')
        with self.assertRaisesRegex(RuntimeError, "changed while the harness approved it"):
            with tasks.temporary_policy(self.allow_notes):
                self.fail("ran after policy.json changed")
        self.assertEqual(self.record, self.saved_record)
        self.assertEqual(self.policy.read_bytes(), self.original)

    def test_an_edit_during_restoration_keeps_the_backups(self):
        self.policy.write_bytes(self.original)
        with self.assertRaisesRegex(RuntimeError, "backups kept"):
            with tasks.temporary_policy(self.allow_notes):
                self.before_approve = lambda: self.policy.write_bytes(b'{"deny_apps":[]}')
        self.assertTrue(list(self.state.glob("policy-backup-*")))
        self.assertNotEqual(self.record, self.make_record(b'{"deny_apps":[]}'))

    def test_a_damaged_newest_record_stops_before_any_change(self):
        self.policy.write_bytes(self.original)
        with patch.object(tasks, "keychain_records", lambda: [("approval.1.test", self.record, None),
                                                              ("approval.2.damaged", b"garbage", None)]):
            with self.assertRaisesRegex(RuntimeError, "newest keychain approval record is damaged"):
                with tasks.temporary_policy(self.allow_notes):
                    self.fail("ran without knowing the approved policy")
        self.assertEqual([event[0] for event in self.events], ["status"])
        self.assertEqual(self.policy.read_bytes(), self.original)

    def test_equal_modification_time_is_ambiguous(self):
        for account in ["approved-policy", "unrecognized"]:
            with self.subTest(account=account), patch.object(tasks, "keychain_records", return_value=[
                    ("approval.4.valid", self.record, 2.0), (account, b"garbage", 2.0)]):
                with self.assertRaisesRegex(RuntimeError, "newest keychain approval record is damaged"):
                    tasks.keychain_approval()

    def test_ties_prefer_a_person_then_contents_not_random_accounts(self):
        def record(by, person, milliseconds):
            return json.dumps(dict(json.loads(self.record), sequence=4, by=by, by_person=person,
                                   approved_at_ms=milliseconds)).encode()
        agent, person = record("agent", False, 3000), record("person", True, 1000)
        with patch.object(tasks, "keychain_records", return_value=[("approval.4.zzzz", agent, 2.0),
                                                                  ("approval.4.aaaa", person, 2.0)]):
            self.assertEqual(tasks.keychain_approval()[0], person)
        a, b = record("a", False, 1000), record("b", False, 1000)
        winners = []
        for accounts in [("approval.4.zzzz", "approval.4.aaaa"), ("approval.4.aaaa", "approval.4.zzzz")]:
            with patch.object(tasks, "keychain_records", return_value=[(accounts[0], a, 2.0), (accounts[1], b, 2.0)]):
                winners.append(tasks.keychain_approval()[0])
        self.assertEqual(winners[0], winners[1])

    def test_another_harness_lock_refuses_before_any_policy_command(self):
        with patch.object(tasks.fcntl, "flock", side_effect=BlockingIOError):
            with self.assertRaisesRegex(RuntimeError, "another eval harness"):
                with tasks.temporary_policy(self.allow_notes):
                    self.fail("locked policy ran")
        self.assertEqual(self.events, [])
        self.assertEqual(tasks._policy_depth, 0)

    def test_notes_can_nest_inside_a_suite_override(self):
        self.policy.write_bytes(self.original)
        def suite_policy(policy):
            policy["web"] = {"allow_private_hosts": True}
            return policy
        with tasks.temporary_policy(suite_policy):
            suite_record = self.record
            with patch.object(tasks, "mac_mcp", return_value="ok"):
                self.assertEqual(tasks.notes_script("get body"), "ok")
            self.assertEqual(self.record, suite_record)
        self.assertEqual(self.record, self.saved_record)
        self.assertEqual(self.policy.read_bytes(), self.original)


if __name__ == "__main__":
    unittest.main()
