"""Installed as /sdcard/main.py only after previous root is backed up.

PC creates .pc_start_once before its confirmed soft reboot. Consume it and
return to raw prompt, allowing PC to start exactly one runtime itself.
"""
BASE = '/sdcard/examguard_book_assist_20261030'


def run(max_frames=None):
    namespace = {'__name__':'examguard_live_runtime'}
    with open(BASE+'/main.py') as source:
        exec(source.read(), namespace)
    return namespace['run'](max_frames=max_frames)


def boot():
    import os
    import time
    def exists(path):
        try:
            os.stat(path)
            return True
        except OSError:
            return False
    marker = BASE+'/.pc_start_once'
    if exists(marker):
        os.remove(marker)
        print('EXAMGUARD_LIVE_PC_BOOT_SKIPPED')
        return
    if exists(BASE+'/recovery.off'):
        print('EXAMGUARD_LIVE_RECOVERY_DISABLED')
        return
    print('EXAMGUARD_LIVE_BOOT_WAIT 3')
    time.sleep(3)
    if not exists(BASE+'/recovery.off'):
        run()


if __name__ == '__main__':
    boot()
