import base64
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("updates", ROOT / "Scripts/updates.py")
updates = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updates)


class UpdateReleaseTests(unittest.TestCase):
    def test_source_build_is_offline_and_release_requires_a_valid_key(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "Info.plist"
            path.write_bytes(plistlib.dumps({"CFBundleVersion": "1.0.1"}))
            updates.configure(path, "", "shadowDragons/vsux")
            self.assertNotIn("SUFeedURL", plistlib.loads(path.read_bytes()))
            with self.assertRaises(ValueError):
                updates.configure(path, base64.b64encode(b"short").decode(), "shadowDragons/vsux")
            updates.configure(path, base64.b64encode(bytes(32)).decode(), "shadowDragons/vsux")
            info = plistlib.loads(path.read_bytes())
            self.assertTrue(info["SURequireSignedFeed"])
            self.assertTrue(info["SUVerifyUpdateBeforeExtraction"])
            self.assertFalse(info["SUEnableAutomaticChecks"])
            self.assertFalse(info["SUAllowsAutomaticUpdates"])
            self.assertEqual(info["SUFeedURL"], "https://github.com/shadowDragons/vsux/releases/latest/download/appcast.xml")

    def test_baseline_uses_numeric_versions_and_excludes_drafts_prereleases_and_newer_tags(self):
        releases = [dict(tagName=tag, isDraft=draft, isPrerelease=pre) for tag, draft, pre in [
            ("v1.9.0", False, False), ("v1.10.0", False, False), ("v1.11.0", True, False),
            ("v1.12.0", False, True), ("v2.0.0", False, False), ("nightly", False, False)]]
        self.assertEqual(updates.previous_release(releases, "1.13.0"), "v1.10.0")
        self.assertIsNone(updates.previous_release(releases, "1.0.1"))

    def test_feed_rejects_unsigned_missing_or_wrong_release_assets(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            name = "vsux-1.0.1-macos-arm64.zip"
            (directory / name).write_bytes(b"archive")
            prefix = "https://github.com/example/app/releases/download/v1.0.1/"
            rss = ET.Element("rss")
            item = ET.SubElement(ET.SubElement(rss, "channel"), "item")
            ET.SubElement(item, updates.SPARKLE + "version").text = "1.0.1"
            ET.SubElement(item, updates.SPARKLE + "shortVersionString").text = "1.0.1"
            enclosure = ET.SubElement(item, "enclosure", {"url": prefix + name, "length": "7",
                updates.SPARKLE + "edSignature": base64.b64encode(bytes(64)).decode()})
            feed = directory / "appcast.xml"
            def validate():
                ET.ElementTree(rss).write(feed)
                return updates.validate_feed(feed, directory, "1.0.1", "1.0.1", prefix)
            self.assertEqual(len(validate()), 1)
            for attribute, bad_value in [("length", "8"), ("url", "https://example.com/other.zip"),
                                          (updates.SPARKLE + "edSignature", "")]:
                original = enclosure.get(attribute)
                enclosure.set(attribute, bad_value)
                with self.assertRaises(ValueError):
                    validate()
                enclosure.set(attribute, original)
            item.remove(enclosure)
            with self.assertRaises(ValueError):
                validate()

    @unittest.skipUnless(os.environ.get("VSUX_UPDATE_TEST_APP"), "Set VSUX_UPDATE_TEST_APP to a built app for signed delta integration")
    def test_real_signed_delta_round_trip_and_tamper_rejection(self):
        # Throwaway signing material never enters Keychain, repository files or logs.
        keys = subprocess.check_output(["swift", "-e", """
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
print(key.rawRepresentation.base64EncodedString())
print(key.publicKey.rawRepresentation.base64EncodedString())
"""], text=True).splitlines()
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {"SPARKLE_PRIVATE_KEY": keys[0]}):
            root = Path(temporary)
            app = root / "dist/vsux.app"
            app.parent.mkdir()
            subprocess.run(["ditto", os.environ["VSUX_UPDATE_TEST_APP"], str(app)], check=True)
            plist = app / "Contents/Info.plist"
            updates.configure(plist, keys[1], "example/app")
            with patch.object(updates, "ROOT", root):
                for version in ["9100.0.1", "9100.0.2"]:
                    info = plistlib.loads(plist.read_bytes())
                    info["CFBundleVersion"] = info["CFBundleShortVersionString"] = version
                    plist.write_bytes(plistlib.dumps(info))
                    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], check=True)
                    updates.package(version, root / "dist/updates-9100.0.1" if version.endswith("2") else None, "example/app")
            output = root / "dist/updates-9100.0.2"
            deltas = list(output.glob("*.delta"))
            self.assertEqual(len(deltas), 1, "Expected a real delta from the previous signed ZIP")
            # Apply the actual delta and compare the resulting bundle's signature.
            original = root / "original"
            subprocess.run(["ditto", "-x", "-k", str(root / "dist/updates-9100.0.1/vsux-9100.0.1-macos-arm64.zip"), str(original)], check=True)
            patched = root / "patched.app"
            subprocess.run([str(updates.TOOLS / "BinaryDelta"), "apply", str(original / "vsux.app"), str(patched), str(deltas[0])], check=True)
            subprocess.run(["codesign", "--verify", "--deep", "--strict", str(patched)], check=True)
            self.assertEqual((patched / "Contents/Info.plist").read_bytes(), plist.read_bytes())
            full = ET.parse(output / "appcast.xml").find("./channel/item/enclosure")
            archive = output / "vsux-9100.0.2-macos-arm64.zip"
            with archive.open("ab") as stream:
                stream.write(b"tampered")
            result = subprocess.run([str(updates.TOOLS / "sign_update"), "--ed-key-file", "-", "--verify",
                                     str(archive), full.get(updates.SPARKLE + "edSignature")],
                                    input=keys[0], text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            # A mismatched release secret must never leave uploadable output.
            info = plistlib.loads(plist.read_bytes())
            info["CFBundleVersion"] = info["CFBundleShortVersionString"] = "9100.0.3"
            plist.write_bytes(plistlib.dumps(info))
            subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], check=True)
            with patch.object(updates, "ROOT", root), patch.dict(os.environ, {
                "SPARKLE_PRIVATE_KEY": base64.b64encode(bytes([7]) * 32).decode()
            }):
                with self.assertRaises((ValueError, subprocess.CalledProcessError)):
                    updates.package("9100.0.3", None, "example/app")
            self.assertFalse((root / "dist/updates-9100.0.3").exists())


if __name__ == "__main__":
    unittest.main()
