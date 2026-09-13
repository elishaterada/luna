import importlib.util
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location('release', Path(__file__).resolve().parents[2] / 'Scripts/release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

class ReleaseTests(unittest.TestCase):
    def test_exact_version_notes_and_xml_escaping(self):
        changelog = '## 1.2.30 — today\nWrong\n## 1.2.3 — today\nGood & <safe>\n## 1.2.2 — yesterday\nOld\n'
        notes = release.release_notes('1.2.3', changelog)
        self.assertEqual(notes, 'Good & <safe>')
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / 'Luna.zip'
            archive.write_bytes(b'example')
            feed = ET.fromstring(release.make_feed('1.2.3', '99', archive, 'signature=', notes))
            self.assertEqual(feed.findtext('channel/item/description'), notes)
            self.assertEqual(feed.find('channel/item/enclosure').attrib['length'], '7')
    def test_missing_or_empty_notes_block_release(self):
        for text in ['## 1.2.30\nWrong', '## 1.2.3\n\n## 1.2.2\nOld']:
            with self.assertRaises(ValueError): release.release_notes('1.2.3', text)
    def test_untrusted_version_cannot_become_shell_input(self):
        for version in ['1.2.3;echo bad', '1.2', '1.2.3-dev', '01.2.3', '1.2.3\n']:
            with self.assertRaises(ValueError): release.validate_version(version)

    def test_release_cannot_downgrade_stable_clients(self):
        published = [{'tagName': 'v1.2.3', 'isDraft': False, 'isPrerelease': False}]
        for version in ['1.2.2', '1.2.3']:
            with self.assertRaises(ValueError): release.validate_release_order(version, published)
        release.validate_release_order('1.2.4', published)
