"""Read-only ST/ET identity checks, optionally requiring periodic RTC anchors."""
from .protocol import ProtocolError, StatusPacket, EventIdentityPacket, decode_packet
from .transaction_protocol import TransactionEventPacket
from .rtc_anchor import RTCAnchor
from .board_monitor import BoardMonitor


class MainPersistentValidation:
    def __init__(self, previous_boot=None, *, min_rtc_anchors=0, min_board_records=0):
        if min_rtc_anchors < 0:
            raise ValueError('minimum RTC anchor count must be nonnegative')
        if min_board_records < 0:
            raise ValueError('minimum board monitor count must be nonnegative')
        self.min_board_records = min_board_records
        self.board_records = []
        self.ignored_before_board = 0
        self.previous_boot = previous_boot
        self.boot = None
        self.status_count = self.transaction_count = self.identity_count = 0
        self.invalid_count = 0
        self.reasons = []
        self.last_uid = 0
        self.observed_identities = set()
        self.min_rtc_anchors = min_rtc_anchors
        self.anchors = []
        self.ignored_before_rtc = 0

    def accept(self, line):
        # Serial framing partitions a bytearray; protocol decoding intentionally
        # accepts only immutable bytes or text. Normalize at this boundary.
        if isinstance(line, bytearray):
            line = bytes(line)
        try:
            packet = decode_packet(line)
        except (ProtocolError, UnicodeError, ValueError):
            if self.min_board_records and not self.board_records:
                self.ignored_before_board += 1
                return
            if self.min_rtc_anchors and not self.anchors:
                self.ignored_before_rtc += 1
                return
            self.invalid_count += 1
            return
        # MONITOR1 adds BM. Old RTC1 already emits RA, so RA alone cannot
        # delimit a reprogramming capture when that older image is running.
        if self.min_board_records and not self.board_records and not isinstance(packet, BoardMonitor):
            self.ignored_before_board += 1
            return
        if isinstance(packet, BoardMonitor) and self.min_board_records:
            who = (packet.device, packet.boot)
            self.observed_identities.add(who)
            if packet.device != 1 or (self.boot is not None and who != (1, self.boot)):
                self.reasons.append('BM_not_matching_status_identity')
            if not packet.valid or not packet.straps_valid:
                self.reasons.append('BM_ADC_or_straps_not_valid')
            if self.board_records:
                old = self.board_records[-1]
                if who != (old.device, old.boot):
                    self.reasons.append('BM_boot_changed_without_new_capture')
                if packet.sequence != old.sequence+1 or packet.adc_sequence <= old.adc_sequence or packet.monotonic_ms <= old.monotonic_ms:
                    self.reasons.append('BM_sequence_or_ADC_or_time_not_advancing')
                if packet.switches != old.switches or packet.seat != old.seat:
                    self.reasons.append('BM_startup_configuration_changed')
            self.board_records.append(packet)
            return
        # Before programming RTC1 the old configuration may still emit ST/ET.
        # RA is the explicit boundary for this RTC-specific capture. Keep all
        # bytes raw but do not bind old-board traffic to the new RTC epoch.
        if self.min_rtc_anchors and not self.anchors and not isinstance(packet, RTCAnchor):
            self.ignored_before_rtc += 1
            return
        if isinstance(packet, RTCAnchor):
            if self.min_rtc_anchors:
                who = (packet.device, packet.boot)
                self.observed_identities.add(who)
                if packet.device != 1 or (self.boot is not None and who != (1, self.boot)):
                    self.reasons.append('RA_not_matching_status_identity')
                if not packet.trusted:
                    self.reasons.append(f'RTC_read_failed_{packet.error}')
                if self.anchors:
                    previous = self.anchors[-1]
                    if who != (previous.device, previous.boot):
                        self.reasons.append('RA_boot_changed_without_new_capture')
                    if packet.sequence != previous.sequence + 1:
                        self.reasons.append('RA_sequence_not_consecutive')
                    if packet.lower_ms <= previous.upper_ms:
                        self.reasons.append('RA_monotonic_brackets_not_advancing')
                self.anchors.append(packet)
            return
        if isinstance(packet, StatusPacket):
            self.status_count += 1
            if packet.health_flags & 0x20:
                self.reasons.append('persistent_identity_failed')
            h = packet.evidence_health
            if h is None or packet.health_flags & 0x30:
                return
            device, boot, _session = h.identity
            if device != 1 or not boot:
                self.reasons.append('invalid_persistent_status_identity')
                return
            if self.boot is not None and boot != self.boot:
                self.reasons.append('boot_changed_without_new_capture')
            self.boot = boot
            if self.previous_boot is not None and boot != self.previous_boot + 1:
                self.reasons.append('not_exactly_next_system_boot')
            if any(identity != (1, boot) for identity in self.observed_identities):
                self.reasons.append('event_not_matching_verified_status_boot')
        elif isinstance(packet, TransactionEventPacket):
            device, boot, _session, uid = packet.identity
            self.observed_identities.add((device, boot))
            if self.boot is not None and (device, boot) != (1, self.boot):
                self.reasons.append('ET_not_matching_verified_status_boot')
            if uid <= self.last_uid:
                self.reasons.append('ET_UID_not_strictly_increasing')
            self.last_uid = uid
            self.transaction_count += 1
        elif isinstance(packet, EventIdentityPacket):
            self.identity_count += 1
            self.observed_identities.add((packet.device_id, packet.boot_id))
            if self.boot is not None and (packet.device_id, packet.boot_id) != (1, self.boot):
                self.reasons.append('EI_not_matching_verified_status_boot')

    def summary(self):
        reasons = sorted(set(self.reasons))
        if self.invalid_count:
            reasons.append('invalid_UART_lines')
        if self.boot is None:
            reasons.append('no_admitted_ST')
        if not self.transaction_count:
            reasons.append('no_ET_transaction')
        if self.min_rtc_anchors:
            if len(self.anchors) < self.min_rtc_anchors:
                reasons.append('insufficient_RTC_anchors')
            if not self.identity_count:
                reasons.append('no_EI_identity')
        if len(self.board_records) < self.min_board_records:
            reasons.append('insufficient_BM_records')
        return dict(verified=not reasons, reasons=reasons, boot=self.boot,
                    previous_boot=self.previous_boot, status_count=self.status_count,
                    transaction_count=self.transaction_count, identity_count=self.identity_count,
                    invalid_count=self.invalid_count, last_uid=self.last_uid,
                    interpretation='UART ST/ET identity only; HDMI, UDP pixels, EEPROM raw and physical reset type separately verified.')

    def rtc_summary(self):
        return dict(required_anchors=self.min_rtc_anchors, anchor_count=len(self.anchors),
                    ignored_lines_before_first_RA=self.ignored_before_rtc,
                    anchors=[dict(device=a.device, boot=a.boot, sequence=a.sequence,
                                  error=a.error, lower_ms=a.lower_ms, upper_ms=a.upper_ms,
                                  calendar=a.calendar, raw_hex=a.raw.hex()) for a in self.anchors],
                     interpretation='First RA arms this RTC capture; earlier bytes retained but excluded. Calendar has no timezone; no calibration or cross-power retention claim.')

    def board_summary(self):
        return dict(required_records=self.min_board_records, records=len(self.board_records),
                    ignored_before_first_BM=self.ignored_before_board,
                    samples=[dict(device=p.device,boot=p.boot,sequence=p.sequence,seat=p.seat,
                                  switches=p.switches,monotonic_ms=p.monotonic_ms,adc=list(p.adc),
                                  adc_sequence=p.adc_sequence,age_cycles=p.age_cycles,
                                  valid=p.valid,straps_valid=p.straps_valid,text=p.text(),raw_hex=p.raw.hex())
                             for p in self.board_records],
                    interpretation='First BM then first RA delimit this monitor capture; not a firmware hash attestation, switch polarity/HDMI/temperature accuracy validation or proof of complete EG/HR.')
