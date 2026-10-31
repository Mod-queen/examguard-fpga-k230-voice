from pathlib import Path
import tempfile
import unittest

from .evidence_capacity import scan_evidence_capacity


class CapacityTests(unittest.TestCase):
    def test_latest_older_pending_HR_and_other_file_bytes_without_cleanup(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)
            files={'egv2_x/revision_1/manifest.json':b'{}',
                   'egv2_x/revision_1/packets.bin':b'old',
                   'egv2_x/revision_2/manifest.json':b'{}',
                   'egv2_x/revision_2/packets.bin':b'latest',
                   'egv2_x/.pending_3/packets.bin':b'pending',
                   'history_results/x/raw.hr':bytes(128),
                   'event_1/frame.pgm':b'PG',
                   'udp_ingress_diagnostics.json':b'{}','notes.txt':b'note'}
            for name,data in files.items():
                path=root/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data)
            result=scan_evidence_capacity(root)
            self.assertEqual(result['total_file_bytes'],sum(map(len,files.values())))
            self.assertEqual(result['published_revisions'],2)
            self.assertEqual(result['EG_identities'],1)
            self.assertEqual(result['pending_directories'],1)
            self.assertEqual(result['bytes_by_kind']['latest_published_EG'],8)
            self.assertEqual(result['bytes_by_kind']['older_or_unpublished_revision'],5)
            self.assertEqual(result['bytes_by_kind']['HR_results'],128)
            self.assertEqual({p.relative_to(root).as_posix():p.read_bytes() for p in root.rglob('*') if p.is_file()},files)


if __name__=='__main__': unittest.main()
