"""Release feeds must name the exact verified archive and monotonic build."""
import base64
from pathlib import Path
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).parents[1]))
import update_artifacts as updates


class UpdateArtifactTests(unittest.TestCase):
    def test_feed_rejects_wrong_url_size_build_and_missing_signature(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / 'QEQ-0.1.0-rc.7-macOS.zip'
            archive.write_bytes(b'archive fixture')
            config = {'version': '0.1.0-rc.7', 'build': 7}
            feed = root / 'appcast.xml'
            tree = ET.Element('rss')
            channel = ET.SubElement(tree, 'channel')
            item = ET.SubElement(channel, 'item')
            build = ET.SubElement(item, f'{{{updates.SPARKLE_NS}}}version')
            build.text = '7'
            hardware = ET.SubElement(item, f'{{{updates.SPARKLE_NS}}}hardwareRequirements')
            hardware.text = 'arm64'
            attributes = {'url': f'https://github.com/gh123man/QEQ/releases/download/v0.1.0-rc.7/{archive.name}',
                          'length': str(archive.stat().st_size),
                          f'{{{updates.SPARKLE_NS}}}edSignature': base64.b64encode(bytes(64)).decode()}
            enclosure = ET.SubElement(item, 'enclosure', attributes)
            ET.ElementTree(tree).write(feed)
            self.assertEqual(updates.validate_appcast(feed, archive, config), attributes[f'{{{updates.SPARKLE_NS}}}edSignature'])
            for requirement in [None, 'x86_64', 'arm64,x86_64']:
                hardware.text = requirement
                ET.ElementTree(tree).write(feed)
                with self.assertRaises(SystemExit):
                    updates.validate_appcast(feed, archive, config)
            hardware.text = 'arm64'
            for key, value in [('url', 'https://example.com/untrusted.zip'), ('length', '1'),
                               (f'{{{updates.SPARKLE_NS}}}edSignature', '')]:
                enclosure.set(key, value)
                ET.ElementTree(tree).write(feed)
                with self.assertRaises(SystemExit):
                    updates.validate_appcast(feed, archive, config)
                enclosure.set(key, attributes[key])
            build.text = '6'
            ET.ElementTree(tree).write(feed)
            with self.assertRaises(SystemExit):
                updates.validate_appcast(feed, archive, config)

    def test_signing_requires_all_sparkle_helpers_and_orders_app_last(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'QEQ.app'
            with self.assertRaises(SystemExit):
                updates.signing_targets(app)
            framework = app / 'Contents/Frameworks/Sparkle.framework'
            base = framework / 'Versions/B'
            for relative in ['XPCServices/Downloader.xpc', 'XPCServices/Installer.xpc', 'Updater.app']:
                (base / relative).mkdir(parents=True)
            (base / 'Autoupdate').touch()
            targets = updates.signing_targets(app)
            self.assertEqual(targets[-2:], [framework, app])
            self.assertEqual(len(targets), 6)
