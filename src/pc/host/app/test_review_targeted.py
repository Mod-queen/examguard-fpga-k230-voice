"""Fast event lookup must retain full raw/HR validation and ambiguity rules."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from .evidence_v2 import decode_window_packet
from .evidence_v2_receiver import EvidenceV2Receiver
from .evidence_v2_store import read_revision
from .protocol import EventPacket, EventIdentityPacket
from .review import load_evidence_review, transaction_windows, legacy_transaction_candidates
from .test_evidence_v2 import wire
from .test_evidence_v2_receiver import result_wire
from .test_history_review import save_hr
from .transaction_protocol import TransactionEventPacket


class TargetedReviewTests(unittest.TestCase):
    def test_alarm_index_filters_only_candidates_then_verifies_raw_and_keeps_ambiguity(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);receiver=EvidenceV2Receiver(root)
            for uid,frame,stamp in ((1,17,100),(2,18,150),(3,999,10000)):
                receiver.ingest(wire(uid=uid,frame_id=frame,frame_time=stamp))
                receiver.ingest(result_wire(uid=uid))
            alarm=EventPacket(17,100,3,0,3,0x50)
            identity=EventIdentityPacket(1,2,3,999)
            save_hr(root,transaction=decode_window_packet(wire(uid=3)).transaction)
            with patch('app.review.read_revision',wraps=read_revision) as read:
                windows,errors=load_evidence_review(root,event=alarm,identity=identity)
                self.assertEqual(read.call_count,2)
            self.assertFalse(errors)
            self.assertEqual(len(windows),2)
            self.assertEqual(len(legacy_transaction_candidates(alarm,identity,windows)),2)
            # Changing a candidate PPM cannot pass just because the lightweight
            # manifest index supplied a plausible frame/time span.
            frame=windows[0]['path']/windows[0]['frames'][0]['file']
            frame.write_bytes(b'changed')
            windows,errors=load_evidence_review(root,event=alarm,identity=identity)
            self.assertEqual(len(errors),1)
            self.assertEqual(len(windows),1)

    def test_exact_lookup_conflicting_same_identity_hr_refuses_binding(self):
        with tempfile.TemporaryDirectory() as directory:
            receiver=EvidenceV2Receiver(directory)
            receiver.ingest(wire());receiver.ingest(result_wire())
            event=TransactionEventPacket(decode_window_packet(wire()).transaction)
            save_hr(directory)
            conflict=decode_window_packet(wire(source_time=1)).transaction
            save_hr(directory,transaction=conflict,token=2)
            windows,errors=load_evidence_review(directory,event=event)
            self.assertFalse(errors)
            self.assertEqual(len(windows),2)
            matches,message=transaction_windows(event,windows)
            self.assertFalse(matches)
            self.assertIn('冲突',message)

    def test_targeted_bad_latest_never_falls_back_to_previous_complete(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);receiver=EvidenceV2Receiver(root)
            receiver.ingest(wire());receiver.ingest(result_wire());save_hr(root)
            event=TransactionEventPacket(decode_window_packet(wire()).transaction)
            original=next(root.glob('egv2_*/revision_*/manifest.json'))
            newer=original.parent.parent/'revision_99999999999999999999_invalid'
            newer.mkdir();(newer/'manifest.json').write_bytes(original.read_bytes())
            windows,errors=load_evidence_review(root,event=event)
            self.assertEqual(len(errors),1)
            self.assertEqual(len(windows),1)
            self.assertFalse(windows[0]['frames'])
            self.assertEqual(windows[0]['history_verdict'],'invalid')


if __name__=='__main__':unittest.main()
