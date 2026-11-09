#!/usr/bin/env python3
"""Focused regression tests for image mirror refresh and reconciliation."""

import importlib.util
import json
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT_DIR = Path(__file__).resolve().parent


def load_script(filename):
    spec = importlib.util.spec_from_file_location(filename, SCRIPT_DIR / f"{filename}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


deploy = load_script("deploy-images-page")
reconcile_script = load_script("reconcile-image-mirror")


class FakeMirror:
    def __init__(self, slots, trees):
        self.current = slots
        self.trees = trees
        self.validations = []
        self.writes = []

    def slots(self):
        return json.loads(json.dumps(self.current))

    def dirs(self, path):
        assert path == "trees"
        return list(self.trees)

    def validate_tree(self, tag):
        if tag not in self.trees:
            raise reconcile_script.ReconcileError(f"missing tree: {tag}")

    def validate(self, slots):
        self.validations.append(slots)
        for tag in reconcile_script.references(slots):
            self.validate_tree(tag)

    def write_slots(self, expected, desired):
        assert self.current == expected
        self.current = json.loads(json.dumps(desired))
        self.writes.append(desired)

    def gc(self, expected):
        assert self.current == expected


class FakeReleases:
    def __init__(self, slots):
        self.release_list = [
            {
                "tagName": tag,
                "isPrerelease": tag == slots["pre-release"],
                "isDraft": False,
                "isStable": tag != slots["pre-release"],
            }
            for tag in reconcile_script.references(slots)
        ]
        self.history_reconciliations = []

    def list(self):
        return self.release_list

    def validate_promotion(self, tag, releases):
        assert any(release["tagName"] == tag for release in releases)

    def publish_stable(self, tag):
        pass

    def mark_latest(self, tag):
        pass

    def reconcile_history(self, slots, releases):
        self.history_reconciliations.append(slots)


class RefreshTest(unittest.TestCase):
    def setUp(self):
        self.slots = {
            "stable": "stable",
            "pre-release": None,
            "history": ["expired", "old"],
        }

    def read(self, trees):
        def fake_cat(path):
            if path.endswith("/slots.json"):
                return json.dumps(self.slots)
            tag = path.split("/")[-2]
            if tag not in trees:
                raise deploy.DeployError(f"rclone cat failed for {path}: not found")
            return json.dumps({
                "tag": tag,
                "files": {f"{tag}.img.xz": "https://example.invalid/image"},
            })

        with patch.object(deploy, "rcat", side_effect=fake_cat), \
                patch.object(deploy, "tree_dirs", return_value=trees):
            return deploy.read_mirror("mirror")

    def test_absent_history_is_omitted(self):
        core = self.read({"stable", "old"})
        self.assertEqual(core["slots"], {"stable": "stable", "history": ["old"]})
        self.assertEqual(set(core["manifests"]), {"stable", "old"})

    def test_all_absent_history_still_serves_stable(self):
        self.slots["history"] = ["expired"]
        core = self.read({"stable"})
        self.assertEqual(core["slots"], {"stable": "stable"})
        self.assertEqual(set(core["manifests"]), {"stable"})

    def test_missing_primary_slot_remains_fatal(self):
        with self.assertRaisesRegex(deploy.DeployError, "rclone cat failed.*stable"):
            self.read({"old"})

    def test_present_history_read_error_is_omitted(self):
        def fail(path):
            if path.endswith("/slots.json"):
                return json.dumps(self.slots)
            if path.endswith("/old/manifest.json"):
                raise deploy.DeployError("OneDrive unavailable")
            return json.dumps({"tag": "stable", "files": {"image": "url"}})

        with patch.object(deploy, "rcat", side_effect=fail), \
                patch.object(deploy, "tree_dirs", return_value={"stable", "old"}):
            core = deploy.read_mirror("mirror")
        self.assertEqual(core["slots"], {"stable": "stable"})
        self.assertEqual(set(core["manifests"]), {"stable"})

    def test_present_invalid_history_remains_fatal(self):
        def invalid(path):
            if path.endswith("/slots.json"):
                return json.dumps(self.slots)
            return json.dumps({"tag": "wrong", "files": {"image": "url"}})

        with patch.object(deploy, "rcat", side_effect=invalid), \
                patch.object(deploy, "tree_dirs", return_value={"stable", "old"}):
            with self.assertRaisesRegex(deploy.DeployError, "mismatch"):
                deploy.read_mirror("mirror")

    def test_duplicate_history_remains_fatal_without_absent_entry(self):
        self.slots["history"] = ["expired", "expired"]
        with self.assertRaisesRegex(deploy.DeployError, "duplicate"):
            self.read({"stable"})

    def test_listing_failure_never_drops_history(self):
        with patch.object(deploy.subprocess, "run") as run:
            run.return_value.returncode = 1
            run.return_value.stderr = "network unavailable"
            with patch.object(deploy.time, "sleep"):
                with self.assertRaisesRegex(deploy.DeployError, "network unavailable"):
                    deploy.tree_dirs("mirror")
        self.assertEqual(run.call_count, 2)


class ReconcileTest(unittest.TestCase):
    def test_missing_history_pointer_is_cleared(self):
        slots = {"stable": "stable", "pre-release": None, "history": ["expired"]}
        mirror = FakeMirror(slots, ["stable"])
        releases = FakeReleases(slots)
        with patch.object(releases, "publish_stable") as publish, \
                patch.object(releases, "mark_latest") as latest:
            result = reconcile_script.reconcile(mirror, releases)
        self.assertEqual(mirror.current["history"], [])
        self.assertEqual(result, {"tag": "stable", "mode": "reconcile"})
        publish.assert_called_once_with("stable")
        latest.assert_called_once_with("stable")

    def test_promotion_does_not_resurrect_missing_history(self):
        slots = {"stable": "stable", "pre-release": "new", "history": ["expired"]}
        mirror = FakeMirror(slots, ["stable", "new"])
        releases = FakeReleases(slots)
        with patch.object(releases, "validate_promotion") as validate, \
                patch.object(releases, "publish_stable"), \
                patch.object(releases, "mark_latest"):
            result = reconcile_script.reconcile(mirror, releases)
        validate.assert_called_once_with("new", releases.release_list)
        self.assertEqual(mirror.current, {
            "stable": "new", "pre-release": None, "history": ["stable"],
        })
        self.assertEqual(result, {"tag": "new", "mode": "promote"})


if __name__ == "__main__":
    unittest.main()
