"""PB1 result plus independently reread PS1 inventory; not main-top identity."""
from __future__ import annotations

import hashlib
import struct
import zlib

from .persistence_inventory import decode_report as decode_inventory

HEADER = b'PB\x01\x01\x00\x40'
RESULT_LENGTH = 64
LENGTH = RESULT_LENGTH + 284


def decode_report(raw: bytes, previous: bytes | None = None) -> dict:
    if len(raw) != LENGTH or raw[:6] != HEADER:
        raise ValueError('wrong/incomplete PB1+PS1 framing (expected 348 bytes)')
    result = raw[:RESULT_LENGTH]
    if zlib.crc32(result[:60]) != int.from_bytes(result[60:], 'big'):
        raise ValueError('PB1 CRC mismatch')
    scan_error, action, error, flags = result[6:10]
    if scan_error > 15 or error > 15 or action not in (0, 1, 3) or flags & ~7:
        raise ValueError('PB1 invalid error/action/flags')
    if result[10:12] != bytes(2) or result[56:60] != bytes(4):
        raise ValueError('PB1 reserved bytes nonzero')
    device, generation, boot = struct.unpack_from('<III', result, 12)
    config = result[24:56].hex()
    admitted, loaded, slot = bool(flags & 1), bool(flags & 2), (flags >> 2) & 1
    inventory = decode_inventory(raw[RESULT_LENGTH:])
    reasons = []
    if error:
        reasons.append(f'allocation_error_{error}')
    if not admitted or not loaded:
        reasons.append('admission_closed_or_unloaded')
    if (action, scan_error) not in ((3, 2), (1, 0)):
        reasons.append('scan_action_mismatch')
    if not inventory['all_devices_responded']:
        reasons.append('independent_inventory_i2c_error')
    if inventory['ambiguous_slots'] or inventory['selected_slot'] is None:
        reasons.append('independent_inventory_no_unique_record')
    else:
        selected = inventory['slots'][inventory['selected_slot']]
        if (slot, device, generation, boot, config) != (
                selected['index'], selected['device'], selected['generation'],
                selected['boot'], selected['config_hex']):
            reasons.append('independent_inventory_result_mismatch')
    if device != 1 or not generation or not boot or config != bytes(32).hex():
        reasons.append('probe_identity_or_config_mismatch')
    media = bytes.fromhex(inventory['eeprom_hex'])
    if media[96:128] != b'\xff' * 32 or media[224:256] != b'\xff' * 32:
        reasons.append('unused_slot_tail_changed')
    if action == 3 and (slot, generation, boot) != (0, 1, 1):
        reasons.append('format_identity_mismatch')
    if action == 3 and media[128:] != b'\xff' * 128:
        reasons.append('format_changed_other_slot')
    if previous is not None:
        prior = decode_report(previous)
        if not prior['verified']:
            raise ValueError('previous boot report must be independently verified')
        if action != 1 or generation != prior['generation'] + 1 or boot != prior['boot'] + 1:
            reasons.append('not_exactly_next_boot_and_generation')
        if slot == prior['active_slot']:
            reasons.append('next_boot_did_not_alternate_slot')
        old_media = bytes.fromhex(prior['inventory']['eeprom_hex'])
        old_slot = prior['active_slot'] * 128
        if media[old_slot:old_slot + 128] != old_media[old_slot:old_slot + 128]:
            reasons.append('previous_active_slot_changed')
    return {'schema': 'examguard-persistent-boot-probe-v1',
            'raw_sha256': hashlib.sha256(raw).hexdigest(), 'verified': not reasons,
            'reasons': reasons, 'scan_error': scan_error, 'action': action,
            'allocation_error': error, 'admission': admitted, 'loaded': loaded,
            'active_slot': slot, 'device': device, 'generation': generation,
            'boot': boot, 'config_hex': config, 'compared_previous': previous is not None,
            'inventory': inventory,
            'interpretation': 'Independent maintenance probe only; no main-top persistent event identity or physical power-cut qualification.'}
