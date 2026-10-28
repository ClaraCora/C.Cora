"""Exercise the publication contract with a fake gh; never contacts GitHub."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
FILES = ["Cora-unsigned.ipa"]
BASH = (r"C:\Program Files\Git\bin\bash.exe" if os.name == "nt" else shutil.which("bash"))


class PublicationTests(unittest.TestCase):
    def setUp(self):
        build = ROOT / "build"
        build.mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="ipa-release-tests-", dir=build)
        self.work = Path(self.temporary.name).resolve()
        # Only this task-created workspace directory is ever recursively cleaned.
        assert self.work.is_relative_to(build.resolve())
        self.addCleanup(self.temporary.cleanup)
        tools = self.work / "bin"
        tools.mkdir()
        runner = self.work / "runner"
        runner.mkdir()
        fake_gh = tools / "gh"
        fake_gh.write_text('''#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$TEST_GH_LOG"
if [[ "$2" == "upload" ]]; then
  if [[ "${TEST_FAIL_UPLOAD:-0}" == "1" ]]; then exit 7; fi
  for arg in "$@"; do
    case "$arg" in
      *.ipa) test -s "$arg" ;;
      */SHA256SUMS.txt) cp -- "$arg" "$TEST_CAPTURE_HASHES" ;;
    esac
  done
fi
''', encoding="utf-8", newline="\n")
        fake_gh.chmod(0o755)
        for name in FILES:
            (self.work / name).write_bytes(("test IPA: " + name).encode())
        self.environment = dict(os.environ)
        search_path = [str(tools)]
        if os.name == "nt":
            search_path += [r"C:\Program Files\Git\usr\bin\core_perl", r"C:\Program Files\Git\usr\bin"]
        search_path.append(os.environ.get("PATH", ""))
        self.environment.update({
            "PATH": os.pathsep.join(search_path),
            "GH_TOKEN": "fake-offline-token",
            "GITHUB_REPOSITORY": "example/Cora",
            "GITHUB_SHA": "a" * 40,
            "GITHUB_RUN_ID": "12345",
            "GITHUB_RUN_NUMBER": "42",
            "GITHUB_RUN_ATTEMPT": "2",
            "APP_VERSION": "1.0.7",
            "RUNNER_TEMP": runner.as_posix(),
            "GITHUB_SERVER_URL": "https://github.com",
            "GITHUB_STEP_SUMMARY": (self.work / "summary.md").as_posix(),
            "TEST_GH_LOG": (self.work / "gh-calls.log").as_posix(),
            "TEST_CAPTURE_HASHES": (self.work / "captured-hashes.txt").as_posix(),
            "TEST_FAIL_UPLOAD": "0",
        })

    def run_publication(self):
        return subprocess.run([BASH, (ROOT / "scripts/publish-ipa-release.sh").as_posix()],
                              cwd=self.work, env=self.environment, capture_output=True,
                              encoding="utf-8", errors="replace", timeout=30)

    def commands(self):
        path = self.work / "gh-calls.log"
        return path.read_text(encoding="utf-8").splitlines() if path.exists() else []

    def test_publishes_complete_build_with_commit_and_checksums(self):
        result = self.run_publication()
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = self.commands()
        self.assertEqual(len(commands), 3)
        self.assertTrue(commands[0].startswith("release create build-12345-2 "))
        self.assertIn("--target " + "a" * 40, commands[0])
        self.assertIn("--draft --prerelease", commands[0])
        self.assertTrue(commands[1].startswith("release upload build-12345-2 "))
        for name in FILES:
            self.assertIn(name, commands[1])
        self.assertIn("SHA256SUMS.txt", commands[1])
        self.assertNotIn("--clobber", commands[1])
        self.assertIn("--draft=false --prerelease --latest=false", commands[2])
        checksums = (self.work / "captured-hashes.txt").read_text(encoding="utf-8")
        expected = "".join(hashlib.sha256((self.work / name).read_bytes()).hexdigest() + " *" + name + "\n"
                           for name in FILES)
        self.assertEqual(checksums, expected)
        self.assertIn("/releases/tag/build-12345-2", (self.work / "summary.md").read_text(encoding="utf-8"))
        self.assertFalse(list((self.work / "runner").iterdir()))

    def test_missing_ipa_fails_before_creating_release(self):
        (self.work / FILES[-1]).unlink()
        result = self.run_publication()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.commands(), [])

    def test_failed_upload_never_publishes_incomplete_draft(self):
        self.environment["TEST_FAIL_UPLOAD"] = "1"
        result = self.run_publication()
        self.assertNotEqual(result.returncode, 0)
        commands = self.commands()
        self.assertEqual(len(commands), 2)
        self.assertFalse(any(command.startswith("release edit") for command in commands))
        self.assertFalse((self.work / "summary.md").exists())
        self.assertFalse(list((self.work / "runner").iterdir()))


if __name__ == "__main__":
    unittest.main()
