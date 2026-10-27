"""Offline migration gates. Does not invoke Xcode, a VPN, or GitHub."""
from pathlib import Path
import re
import subprocess
import tomllib
import unittest

ROOT = Path(__file__).resolve().parents[1]
PIN = "fa7a7d6dc94e886ae0bc43eeb0227082ae5bf2e6"


class MigrationTests(unittest.TestCase):
    def test_standard_project_boundary(self):
        text = (ROOT / "project.yml").read_text(encoding="utf-8")
        self.assertEqual(re.findall(r"^  (\w+):\n    type:", text, re.M), ["Cora", "CoraTunnel", "CoraControl"])
        self.assertIn('iOS: "18.0"', text)
        self.assertNotIn("Mihomo.xcframework", text)
        self.assertEqual(text.count("framework: Vendor/MeowCore.xcframework"), 2)
        self.assertIn("-lsqlite3", text)
        for framework in ["Security", "SystemConfiguration", "CoreFoundation"]:
            self.assertIn("-framework " + framework, text)
        self.assertTrue((ROOT / "MobileCore").is_dir())
        # The former Legacy targets shared Cora/ and CoraTunnel/ sources.
        self.assertTrue((ROOT / "MobileCore/SwiftReference/PacketTunnelProvider.swift").is_file())

    def test_no_old_core_symbols_in_active_sources(self):
        header = (ROOT / "MobileCoreRust/include/meow_core.h").read_text(encoding="utf-8")
        for folder in ["Cora", "CoraTunnel", "Shared"]:
            for path in (ROOT / folder).rglob("*.swift"):
                source = path.read_text(encoding="utf-8-sig")
                self.assertNotRegex(source, r"\bimport\s+Mihomo\b|\bMihomo[A-Z]\w*\s*\(", str(path))
                for name in re.findall(r"\b(meow_\w+|cora_core_request)\s*\(", source):
                    self.assertIn(name + "(", header, str(path))
        tunnel = (ROOT / "CoraTunnel/PacketTunnelProvider.swift").read_text(encoding="utf-8")
        self.assertNotRegex(tunnel, r"utunFD|MihomoStart|SetDefaultInterface|ForceGC")
        self.assertIn("meow_tun_stop_blocking()", tunnel)

    def test_all_engine_dependencies_and_locks_pinned(self):
        crate = ROOT / "MobileCoreRust/meow-ios-ffi"
        manifest = tomllib.loads((crate / "Cargo.toml").read_text(encoding="utf-8"))
        found = set()
        for name, dep in manifest["dependencies"].items():
            if isinstance(dep, dict) and dep.get("git") == "https://github.com/meow-rs/meow-rs":
                self.assertEqual(dep["rev"], PIN, name)
                found.add(name)
        self.assertTrue({"meow-config", "meow-dns", "meow-tunnel", "meow-api", "meow-proxy", "meow-common", "lwip"} <= found)
        lock = tomllib.loads((crate / "Cargo.lock").read_text(encoding="utf-8"))
        for package in lock["package"]:
            if "git+https://github.com/meow-rs/meow-rs" in package.get("source", ""):
                self.assertEqual(package["source"].split("#")[-1], PIN)
        self.assertTrue((ROOT / "MobileCoreRust/cora-config/Cargo.lock").is_file())

    def test_ci_is_one_standard_artifact(self):
        source = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        self.assertIn("branches: [main, meow-rs]", source)
        self.assertIn("workflow_dispatch:", source)
        self.assertIn("RUSTUP_TOOLCHAIN: '1.95.0'", source)
        self.assertEqual(set(re.findall(r"Cora[\w-]*\.ipa", source)), {"Cora-unsigned.ipa"})
        self.assertNotRegex(source, r"(?i)gomobile|setup-go|CoraLegacy|TrollStore|build-mihomo")
        build = (ROOT / "MobileCoreRust/scripts/build-ios-xcframework.sh").read_text(encoding="utf-8")
        self.assertIn("aarch64-apple-ios aarch64-apple-ios-sim", build)
        self.assertNotIn("x86_64-apple", build)
        for script in ["test-core-compatibility.sh", "verify-meow-app.sh"]:
            self.assertTrue((ROOT / "scripts" / script).is_file())

    def test_windows_tool_stays_untracked(self):
        files = subprocess.check_output(["git", "ls-files", "--", "WindowsConfigTool/"], cwd=ROOT)
        self.assertEqual(files.strip(), b"", "WindowsConfigTool must not enter this migration")

    def test_abi_headers_and_acceptance_docs_exist(self):
        core = ROOT / "MobileCoreRust"
        self.assertEqual((core / "include/meow_core.h").read_bytes(),
                         (core / "meow-ios-ffi/include/meow_core.h").read_bytes())
        self.assertTrue((ROOT / "docs/meow-rs-migration.md").is_file())
        script = (ROOT / "scripts/test-core-compatibility.sh").read_text(encoding="utf-8")
        for name in ["CorePersistenceTests.swift", "CoreCompatibilityTests.swift", "MemoryDiagnosticAnalyzerTests.swift"]:
            self.assertIn(name, script)


if __name__ == "__main__":
    unittest.main()
