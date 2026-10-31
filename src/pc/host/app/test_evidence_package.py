"""ZIP bytes -> strict evidence reconstruction; originals remain unchanged."""
from contextlib import closing
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

from .evidence_package import export_evidence_package, verify_evidence_package
from .monitor import MonitorModel
from .protocol import decode_packet
from .test_history_review import save_pixels, save_hr
from .test_rtc_anchor import line


def rewrite_zip(source, target, update):
    with zipfile.ZipFile(source) as incoming, zipfile.ZipFile(target, 'x', zipfile.ZIP_DEFLATED) as outgoing:
        for item in incoming.infolist():
            outgoing.writestr(item.filename, update(item.filename, incoming.read(item.filename)))


class EvidencePackageTests(unittest.TestCase):
    def test_latest_partial_and_clean_HR_preserved_with_live_SQLite_snapshot(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)/'evidence';save_pixels(root,False);save_hr(root)
            model=MonitorModel(session_root=Path(d)/'sessions')
            try:
                model.apply(decode_packet(line()))
                source=next(root.glob('egv2_*/revision_*/packets.bin'))
                digest=hashlib.sha256(source.read_bytes()).hexdigest()
                package=Path(d)/'case.zip'
                result=export_evidence_package(root,package,session_path=model.snapshot().session_path)
                self.assertEqual(result['evidence']['counts'],{'partial':1})
                self.assertTrue(result['session'])
                self.assertTrue(verify_evidence_package(package)['verified'])
                self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(),digest)
                # Exporting the SQLite backup does not close or change live store.
                model.apply(decode_packet(line(1)))
                self.assertEqual(model.snapshot().persisted_anchors,2)
                with zipfile.ZipFile(package) as archive:
                    self.assertIn('RTC时间锚',archive.read('report.md').decode())
                    self.assertEqual(len([n for n in archive.namelist() if n.endswith('packets.bin')]),1)
                with self.assertRaises(FileExistsError):
                    export_evidence_package(root,package)
            finally:
                model.close()

    def test_result_only_failure_is_exported_without_fabricated_frames(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)/'evidence';save_hr(root,code=4,flags=0)
            result=export_evidence_package(root,Path(d)/'case.zip')
            self.assertEqual(result['evidence']['counts'],{'failed':1})
            self.assertEqual(result['evidence']['windows'][0]['received_frames'],0)

    def test_corrupt_latest_rejected_before_output_and_does_not_fall_back(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)/'evidence';save_pixels(root);save_hr(root)
            raw=next(root.glob('egv2_*/revision_*/packets.bin'))
            raw.write_bytes(b'broken')
            target=Path(d)/'case.zip'
            with self.assertRaises(ValueError):
                export_evidence_package(root,target)
            self.assertFalse(target.exists())
            self.assertEqual(raw.read_bytes(),b'broken')

    def test_edited_payload_hash_and_edited_hash_with_invalid_CRC_both_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)/'evidence';save_pixels(root);save_hr(root)
            source=Path(d)/'case.zip';export_evidence_package(root,source)
            with zipfile.ZipFile(source) as archive:
                raw_name=next(n for n in archive.namelist() if n.endswith('packets.bin'))
            bad=b'broken'
            rewrite_zip(source,Path(d)/'tampered.zip',lambda name,data: bad if name==raw_name else data)
            with self.assertRaises(ValueError):
                verify_evidence_package(Path(d)/'tampered.zip')
            def forged(name,data):
                if name==raw_name: return bad
                if name=='package_manifest.json':
                    m=json.loads(data)
                    for row in m['files']:
                        if row['path']==raw_name:
                            m['total_bytes']+=len(bad)-row['bytes']
                            row['bytes']=len(bad);row['sha256']=hashlib.sha256(bad).hexdigest()
                    return json.dumps(m).encode()
                return data
            rewrite_zip(source,Path(d)/'forged.zip',forged)
            with self.assertRaises(ValueError):
                verify_evidence_package(Path(d)/'forged.zip')

    def test_unsafe_member_and_unlisted_extra_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)/'evidence';save_pixels(root);save_hr(root)
            original=Path(d)/'case.zip';export_evidence_package(root,original)
            for i,name in enumerate(('../escape.txt','C:/escape.txt','evidence/extra.txt')):
                target=Path(d)/f'bad{i}.zip'
                rewrite_zip(original,target,lambda _,data:data)
                with zipfile.ZipFile(target,'a') as archive:
                    archive.writestr(name,b'bad')
                with self.assertRaises(ValueError):
                    verify_evidence_package(target)
            self.assertFalse((Path(d)/'escape.txt').exists())

    def test_uart_counts_and_partial_tail_preserved_without_fake_receipt_UTC(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)/'evidence';root.mkdir()
            raw=Path(d)/'capture.raw';raw.write_bytes(line()+b'ST,partial')
            package=Path(d)/'case.zip'
            result=export_evidence_package(root,package,uart_path=raw)
            self.assertEqual(result['uart']['complete_lines'],{'RA':1})
            self.assertEqual(result['uart']['trailing_partial_bytes'],10)
            with zipfile.ZipFile(package) as archive:
                self.assertEqual(archive.read('capture.raw'),raw.read_bytes())
                self.assertIn('已保存RA记录：0',archive.read('report.md').decode())


if __name__=='__main__':
    unittest.main()
