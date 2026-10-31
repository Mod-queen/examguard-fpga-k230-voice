"""UDP receiver for FPGA status and alarm packets."""

from __future__ import annotations

import socket
from collections.abc import Iterator
from threading import Event

from .protocol import Packet, ProtocolError, decode_packet


def receive_packets(
    host: str = "0.0.0.0",
    port: int = 5005,
    *,
    timeout: float | None = None,
    stop_event: Event | None = None,
) -> Iterator[Packet]:
    """Yield decoded packets from a newline-oriented UDP endpoint.

    One datagram normally contains one packet. Splitting by newline also
    allows a sender to batch several status updates in one datagram.
    Malformed lines are ignored so one bad datagram cannot stop monitoring.
    """
    receive_timeout = timeout
    if receive_timeout is None and stop_event is not None:
        receive_timeout = 0.5

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        if hasattr(socket, 'SO_EXCLUSIVEADDRUSE'):
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        sock.settimeout(receive_timeout)
        sock.bind((host, port))
        while stop_event is None or not stop_event.is_set():
            try:
                data, _address = sock.recvfrom(2048)
            except socket.timeout:
                continue
            for line in data.splitlines():
                try:
                    yield decode_packet(line)
                except ProtocolError:
                    continue
