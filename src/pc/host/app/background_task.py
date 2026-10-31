"""One bounded background file task; callers poll results on their UI thread."""
from queue import Queue, Empty
from threading import Thread


def _run(action, results):
    try:
        result = action()
    except Exception as exc:
        # Keep only text, not tracebacks/closures that may retain a Tk widget.
        results.put((False, f'{type(exc).__name__}: {exc}'))
    else:
        results.put((True, result))


class BackgroundTask:
    def __init__(self):
        self._results = Queue(maxsize=1)
        self._active = False

    @property
    def active(self):
        return self._active

    def start(self, action):
        if self._active:
            return False
        self._active = True
        try:
            # Non-daemon: normal GUI close must not silently kill an in-progress
            # archive write/verification. The worker holds no Tk objects.
            Thread(target=_run, args=(action, self._results),
                   name='examguard-file-task', daemon=False).start()
        except Exception:
            self._active = False
            raise
        return True

    def poll(self):
        try:
            result = self._results.get_nowait()
        except Empty:
            return None
        self._active = False
        return result
