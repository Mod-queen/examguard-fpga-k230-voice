"""One command: dashboard + owned FPGA UART/UDP and K230 source receivers."""
from pathlib import Path
import sys
import tkinter as tk
from tkinter import messagebox

HOST = Path(__file__).resolve().parent/'host'
sys.path.insert(0, str(HOST))

from app.services import InstanceLock, Services, check_udp_free, load_config, save_config


def main():
    lock = services = app = None
    try:
        lock = InstanceLock()
        config_path = HOST/'launch_config.json'
        config = load_config(config_path)
        # Existing hand-started apps must be closed explicitly by the operator.
        # Do not take over a running COM12 capture (it may be writing evidence).
        for key in ('status_port', 'downlink_port', 'image_port'):
            check_udp_free(config[key])
        if not config_path.exists():
            save_config(config_path, config)
        from app.dashboard import Dashboard
        services = Services(config)
        app = Dashboard(host='0.0.0.0', port=config['status_port'], config_path=HOST/'regions.json',
            downlink_port=config['downlink_port'], session_root=HOST/'sessions',
            services=services, launch_config_path=config_path)

        def launch():
            try:
                services.start()
            except (OSError, ValueError, RuntimeError) as exc:
                messagebox.showerror('采集启动失败', str(exc), parent=app)
        app.after(200, launch)
        app.mainloop()
        return 0
    except (OSError, ValueError, ImportError) as exc:
        root = tk.Tk()
        root.withdraw()
        messagebox.showerror('ExamGuard启动失败',
            f'{exc}\n\n请先关闭旧监考台/串口采集/UDP接收窗口及CanMV IDE，再启动。\n'
            '如端口变动，可修改host/launch_config.json；不会自动关闭其他进程。', parent=root)
        root.destroy()
        return 1
    finally:
        if services is not None and not services.closing:
            services.stop()
        if lock is not None:
            lock.close()


if __name__ == '__main__':
    raise SystemExit(main())
