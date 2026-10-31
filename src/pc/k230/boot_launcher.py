"""Optional standalone entry candidate; keep verified recognition main unchanged.

Deploy ONLY later with physical startup validation. Put a root main.py wrapper
that imports this module and calls run(); create /sdcard/examguard/standalone.on
to opt in. Recovery marker disables startup so IDE/PC REPL remains available.
"""


def run(os_module=None, time_module=None, importer=None):
    if os_module is None:
        import os as os_module
    if time_module is None:
        import time as time_module
    if importer is None:
        def importer(_name):
            # Root boot main.py and recognition main.py have the same basename;
            # an import('main') could recursively load the root launcher.
            namespace={'__name__':'examguard_recognition'}
            with open('/sdcard/examguard/main.py','r') as source:
                code=source.read()
            exec(code,namespace)
            return namespace
    prefix='/sdcard/examguard/'
    def exists(path):
        try:os_module.stat(path);return True
        except OSError:return False
    if exists(prefix+'recovery.off') or not exists(prefix+'standalone.on'):
        print('EXAMGUARD_STANDALONE_DISABLED')
        return False
    print('EXAMGUARD_STANDALONE_WAIT 3')
    time_module.sleep(3)
    if exists(prefix+'recovery.off'):
        print('EXAMGUARD_STANDALONE_RECOVERY')
        return False
    try:
        import sys
        if prefix not in sys.path:sys.path.append(prefix)
        recognition=importer('main')
        print('EXAMGUARD_STANDALONE_START')
        if isinstance(recognition,dict):recognition['run']()
        else:recognition.run()
    except KeyboardInterrupt:
        print('EXAMGUARD_STANDALONE_INTERRUPTED')
        return False
    except Exception as exc:
        print('EXAMGUARD_STANDALONE_FAILED',repr(exc))
        # Explicit failure with no hidden endless reset/retry loop.
        return False
    print('EXAMGUARD_STANDALONE_STOPPED')
    return True
