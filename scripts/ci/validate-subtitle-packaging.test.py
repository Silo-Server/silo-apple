#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("packaging", Path(__file__).with_name("validate-subtitle-packaging.py"))
packaging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packaging)


class SubtitlePackagingTests(unittest.TestCase):
    def test_all_rejected_wrappers_fail_in_exported_ipa(self):
        with tempfile.TemporaryDirectory() as scratch:
            ipa = Path(scratch) / "SiloTV.ipa"
            for name in ["Libass", "Libfreetype", "Libfribidi", "Libharfbuzz", "Libunibreak"]:
                with self.subTest(framework=name):
                    with zipfile.ZipFile(ipa, "w") as archive:
                        archive.writestr(f"Payload/SiloTV.app/Frameworks/{name}.framework/Info.plist", "")
                    with self.assertRaisesRegex(ValueError, name):
                        packaging.validate(ipa)

    def test_app_keeps_dynamic_media_frameworks_and_subtitle_resource_bundles(self):
        with tempfile.TemporaryDirectory() as scratch:
            app = Path(scratch) / "SiloTV.app"
            (app / "Frameworks/AetherLibavcodec.framework").mkdir(parents=True)
            (app / "swift-libass_SwiftLibass.bundle").mkdir()
            packaging.validate(app)
            (app / "Frameworks/libass.framework").mkdir()
            with self.assertRaises(ValueError):
                packaging.validate(app)

    def test_missing_product_fails(self):
        with tempfile.TemporaryDirectory() as scratch:
            with self.assertRaises(ValueError):
                packaging.validate(Path(scratch) / "missing.ipa")


if __name__ == "__main__":
    unittest.main()
