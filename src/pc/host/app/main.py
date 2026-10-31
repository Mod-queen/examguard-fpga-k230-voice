"""Host application entry point."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path

from .monitor import MonitorModel

from .receiver import receive_packets


@dataclass
class AppConfig:
    host_ip: str = "0.0.0.0"
    host_port: int = 5005
    config_path: str = "regions.json"


def main() -> None:
    parser = argparse.ArgumentParser(description="Receive FPGA status packets")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=5005)
    parser.add_argument("--session-root", default=str(Path(__file__).resolve().parents[1] / "sessions"),
                        help="directory for a new durable host capture-session SQLite file")
    parser.add_argument(
        "--ui",
        action="store_true",
        help="launch the Tk dashboard instead of the console receiver",
    )
    parser.add_argument(
        "--config",
        default="regions.json",
        help="JSON region layout used by the dashboard",
    )
    parser.add_argument(
        "--downlink-host",
        default="127.0.0.1",
        help="UDP host that the dashboard sends configuration to",
    )
    parser.add_argument(
        "--downlink-port",
        type=int,
        default=5006,
        help="UDP port the dashboard sends configuration to",
    )
    args = parser.parse_args()

    config = AppConfig(
        host_ip=args.host,
        host_port=args.port,
        config_path=args.config,
    )
    if args.ui:
        from .dashboard import run_dashboard

        run_dashboard(
            host=config.host_ip,
            port=config.host_port,
            config_path=config.config_path,
            downlink_host=args.downlink_host,
            downlink_port=args.downlink_port,
            session_root=args.session_root,
        )
        return

    print("ExamGuard host")
    print(f"listening on {config.host_ip}:{config.host_port}")
    model = MonitorModel(session_root=args.session_root,
                         session_metadata={"status_endpoint": f"{config.host_ip}:{config.host_port}",
                                           "board_protocol": "ST/AL v1", "application": "ExamGuard console"})
    snapshot = model.snapshot()
    print("capture session:", snapshot.session_path or snapshot.persistence_error)
    last_error = snapshot.persistence_error
    try:
        for packet in receive_packets(config.host_ip, config.host_port):
            model.apply(packet)
            print(packet)
            error = model.snapshot().persistence_error
            if error and error != last_error:
                print("PERSISTENCE ERROR:", error)
                last_error = error
    except KeyboardInterrupt:
        pass
    finally:
        model.close()


if __name__ == "__main__":
    main()
