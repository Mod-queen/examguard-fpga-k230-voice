"""Parser checks for the packet-capture evidence boundary, not an FPGA model."""
from pathlib import Path
import struct
import tempfile
import unittest

from audit_history_packet_capture import checksum, packets, udp_payload


def block(kind, body, endian='<'):
    body += bytes((-len(body)) % 4)
    size = len(body)+12
    return struct.pack(endian+'II', kind, size)+body+struct.pack(endian+'I', size)


def ethernet(payload=b'hello', *, vlan=False, udp_crc=True):
    addresses = bytes((192,168,0,2,192,168,0,3))
    length = 8+len(payload)
    udp = struct.pack('!HHHH', 5000, 6102, length, 0)+payload
    if udp_crc:
        crc = checksum(addresses+bytes((0,17))+length.to_bytes(2, 'big')+udp) or 65535
        udp = udp[:6]+crc.to_bytes(2, 'big')+udp[8:]
    ip = struct.pack('!BBHHHBBH8s', 0x45,0,20+length,0,0,64,17,0,addresses)
    ip = ip[:10]+checksum(ip).to_bytes(2, 'big')+ip[12:]
    return bytes(12)+(b'\x81\x00\x00\x05\x08\x00' if vlan else b'\x08\x00')+ip+udp


class PacketCaptureAuditTests(unittest.TestCase):
    def test_section_endian_and_timestamp_resolution(self):
        frame = ethernet()
        for endian in ('<', '>'):
            with self.subTest(endian=endian), tempfile.TemporaryDirectory() as tmp:
                section = block(0x0a0d0d0a, struct.pack(endian+'IHHq',0x1a2b3c4d,1,0,-1),endian)
                interface = block(1, struct.pack(endian+'HHIHH',1,0,65535,9,1)+b'\x09\0\0\0'+
                                  struct.pack(endian+'HH',0,0),endian)
                packet = block(6, struct.pack(endian+'IIIII',0,0,123456789,len(frame),len(frame))+frame,endian)
                path = Path(tmp)/'capture.pcapng'
                path.write_bytes(section+interface+packet)
                rows = list(packets(path))
                self.assertEqual(len(rows),1)
                self.assertEqual(rows[0][0:2],(1,0))
                self.assertAlmostEqual(rows[0][2],.123456789)
                self.assertEqual(rows[0][4],frame)
                path.write_bytes(section+interface+packet[:-1])
                with self.assertRaisesRegex(ValueError, 'truncated'):
                    list(packets(path))

    def test_ipv4_vlan_and_udp_checksum(self):
        for vlan in (False,True):
            for enabled in (False,True):
                with self.subTest(vlan=vlan,enabled=enabled):
                    data, meta = udp_payload(ethernet(vlan=vlan,udp_crc=enabled))
                    self.assertEqual(data,b'hello')
                    self.assertEqual(meta['destination_port'],6102)
                    self.assertTrue(meta['ipv4_checksum_ok'])
                    self.assertTrue(meta['udp_checksum_ok'])
                    self.assertEqual(meta['udp_checksum_disabled'],not enabled)
        damaged = bytearray(ethernet())
        damaged[-1] ^= 1
        self.assertFalse(udp_payload(bytes(damaged))[1]['udp_checksum_ok'])

    def test_truncation_fragmentation_and_non_ip(self):
        with self.assertRaisesRegex(ValueError,'length'):
            udp_payload(ethernet()[:-2])
        frame = bytearray(ethernet())
        frame[20:22] = b'\x20\0'  # IPv4 more-fragments bit
        with self.assertRaisesRegex(ValueError,'fragmented'):
            udp_payload(bytes(frame))
        self.assertIsNone(udp_payload(bytes(12)+b'\x08\x06'+bytes(28)))


if __name__ == '__main__':
    unittest.main()
