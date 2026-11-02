"""Release preparation must reject stale, missing, or changed screenshots."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('screenshots', Path(__file__).parents[1] / 'screenshots.py')
screenshots = importlib.util.module_from_spec(spec)
spec.loader.exec_module(screenshots)


class ScreenshotGateTests(unittest.TestCase):
    def test_source_change_and_image_tampering_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            for name in screenshots.NAMES:
                (output / (name + '.png')).write_bytes(b'test-image')
            images = {p.name: screenshots.digest(p) for p in output.glob('*.png')}
            (output / 'screenshots.json').write_text(json.dumps({'sources': {'View.swift': 'current'}, 'images': images}))
            with patch.object(screenshots, 'sources', return_value={'View.swift': 'current'}):
                screenshots.verify(output)
                (output / 'mixer.png').write_bytes(b'changed')
                with self.assertRaises(SystemExit):
                    screenshots.verify(output)
                (output / 'mixer.png').unlink()
                with self.assertRaises(SystemExit):
                    screenshots.verify(output)
            with patch.object(screenshots, 'sources', return_value={'View.swift': 'changed'}):
                with self.assertRaises(SystemExit):
                    screenshots.verify(output)

    def test_missing_manifest_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(SystemExit):
                screenshots.verify(Path(directory))
