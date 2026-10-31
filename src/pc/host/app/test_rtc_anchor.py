import struct
import unittest
import zlib

from .protocol import ProtocolError
from .rtc_anchor import decode_rtc_anchor


def line(error=0, **changes):
    data = bytearray(b'RA\x01\x01\x00\x40' + bytes((int(error==0),error)) +
                     struct.pack('!IIIQQ', 1, 7, 1, 0x100000010, 0x100000019) +
                     bytes.fromhex('000035201820021026') + bytes(15))
    for offset,value in changes.items():
        data[int(offset)]=value
    data += zlib.crc32(data).to_bytes(4, 'big')
    return b'RA,'+data.hex().upper().encode()+b'\n'


class RTCAnchorTests(unittest.TestCase):
    def test_calendar_is_unzoned_and_64bit_bracket_preserved(self):
        a=decode_rtc_anchor(line())
        self.assertEqual((a.device,a.boot,a.sequence),(1,7,1))
        self.assertEqual((a.lower_ms,a.upper_ms),(0x100000010,0x100000019))
        self.assertEqual(a.calendar['local_datetime_unzoned'],'2026-10-20T18:20:35')
        self.assertIn('不替换事件源时间',a.text())

    def test_failed_read_can_retain_raw_without_claiming_calendar_trust(self):
        for err in range(1,5):
            self.assertFalse(decode_rtc_anchor(line(err)).trusted)
            self.assertIn('无可信日期',decode_rtc_anchor(line(err)).text())

    def test_corrupt_reserved_and_false_trust_rejected(self):
        damaged=bytearray(line());damaged[20]=ord('F')
        for bad in (bytes(damaged),line()[:-3],line(**{'45':1}),line(**{'38':0xb5}),line(**{'7':7})):
            with self.assertRaises(ProtocolError):
                decode_rtc_anchor(bad)


if __name__=='__main__':
    unittest.main()
