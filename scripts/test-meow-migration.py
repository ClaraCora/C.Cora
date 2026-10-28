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

    def test_ffi_ci_lifecycle_test_is_isolated_and_bounded(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        marker = "- name: Test FFI lifecycle, packets and traffic"
        self.assertIn(marker, workflow)
        ffi_step = workflow.split(marker, 1)[1].split("- name:", 1)[0]
        self.assertIn("timeout-minutes: 10", ffi_step)
        self.assertIn("--nocapture --test-threads=1", ffi_step)

        source = (ROOT / "MobileCoreRust/meow-ios-ffi/src/cora.rs").read_text(encoding="utf-8")
        self.assertIn('const CHILD: &str = "CORA_LIFECYCLE_TEST_CHILD";', source)
        self.assertIn("Duration::from_secs(120)", source)
        for stage in [
            "engine start begin",
            "SOCKS handshake complete",
            "tun2socks start begin",
            "health probe begin",
            "stopping tun2socks",
            "stopping engine",
        ]:
            self.assertIn(f"lifecycle-test: {stage}", source)

        stun = (ROOT / "MobileCoreRust/meow-ios-ffi/src/probe/stun.rs").read_text(encoding="utf-8")
        test_server = stun.split("async fn stun_server", 1)[1].split("fn address_attr", 1)[0]
        self.assertIn("0..MAX_BIND_ATTEMPTS", test_server)
        self.assertIn("could not reserve matching loopback ports", test_server)
        self.assertIn("STUN test server setup: mode={mode:?}", test_server)
        self.assertNotIn("loop {", test_server)

    def test_app_rejects_unsupported_configs_before_geo_download(self):
        source = (ROOT / "Cora/App/CoreStateManager.swift").read_text(encoding="utf-8")
        start = source.split("private func startCurrentConfiguration", 1)[1].split(
            "/// 在运行中的 VPN 上应用", 1
        )[0]
        self.assertLess(start.index("validateConfiguration"), start.index("prepareForConnection"))
        self.assertIn("CoraNativeCore.failure(validationError)", start)

        bridge = (ROOT / "Cora/Core/CoraCoreBridge.swift").read_text(encoding="utf-8")
        self.assertIn('settings["systemDNS"] = ["192.0.2.1"]', bridge)
        connect = (ROOT / "Cora/Features/Connect/ConnectView.swift").read_text(encoding="utf-8")
        hero = connect.split("private struct ConnectionHero", 1)[1].split(
            "private func releaseMemory", 1
        )[0]
        self.assertIn("@EnvironmentObject private var geoDatabase: GeoDatabaseManager", hero)
        self.assertIn("geoDatabase.isUpdating", hero)

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
