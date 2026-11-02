"""Ensure a failed or incomplete Apple assessment cannot become a release."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('build_release', Path(__file__).parents[1] / 'build_release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseGateTests(unittest.TestCase):
    def test_notarization_requires_explicit_acceptance(self):
        credentials = {'NOTARY_KEY_PATH': '/temporary/key.p8', 'APPLE_NOTARY_KEY_ID': 'test',
                       'APPLE_NOTARY_ISSUER_ID': 'test'}
        for status in ('Invalid', 'In Progress', None):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as directory:
                with patch.dict(release.os.environ, credentials), patch.object(release, 'run') as run:
                    run.return_value = json.dumps({'id': 'submission', 'status': status})
                    with self.assertRaises(SystemExit):
                        release.notarize(Path('app.zip'), 'app', Path(directory))
                    self.assertTrue((Path(directory) / 'notary-app.json').is_file())
                    self.assertEqual(run.call_args.args[:3], ('xcrun', 'notarytool', 'log'))

    def test_accepted_notarization_preserves_submission_id(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.dict(release.os.environ, {'NOTARY_KEY_PATH': 'key', 'APPLE_NOTARY_KEY_ID': 'test',
                                                'APPLE_NOTARY_ISSUER_ID': 'test'}):
                with patch.object(release, 'run', return_value='{"id":"accepted-id","status":"Accepted"}'):
                    self.assertEqual(release.notarize(Path('app.zip'), 'app', Path(directory)), 'accepted-id')

    def test_development_signature_is_not_a_distribution_signature(self):
        signature = 'Authority=Apple Development: Example\nTeamIdentifier=TEAM\nTimestamp=today\nruntime'
        with patch.object(release, 'run'), patch.object(release.subprocess, 'run') as command:
            command.return_value.stderr = signature
            with self.assertRaises(SystemExit):
                release.verify_signature(Path('app'), 'TEAM', runtime=True)

    def test_developer_id_requires_expected_team_timestamp_and_runtime(self):
        valid = 'Authority=Developer ID Application: Example\nTeamIdentifier=TEAM\nTimestamp=today\nruntime'
        for signature in (valid.replace('TEAM', 'OTHER'), valid.replace('Timestamp=', 'NoTime='),
                          valid.replace('runtime', '')):
            with self.subTest(signature=signature), patch.object(release, 'run'):
                with patch.object(release.subprocess, 'run') as command:
                    command.return_value.stderr = signature
                    with self.assertRaises(SystemExit):
                        release.verify_signature(Path('app'), 'TEAM', runtime=True)
