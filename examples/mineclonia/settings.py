"""Expose the prototype's bounded physics controls through GameNight settings."""
import json
import time
from concurrent.futures import ThreadPoolExecutor
from prototype import command


class Settings:
    def __init__(self, root):
        self.root = root
        self.worker = ThreadPoolExecutor(max_workers=1)
        self.pending = {}
        self.future = None
        self.inflight = {}
        self.retry_at = 0
        self.failures = 0

    def specs(self):
        # Match the already-running world's values, including phone edits.
        state = json.loads((self.root / 'world/gamenight/status.json').read_text())
        values = state.get('values', {})
        return [{'key': key, 'label': label, 'kind': 'number',
                 'default': max(25, min(200, round(values.get(key, 1) * 100))),
                 'min': 25, 'max': 200}
                for key, label in [('gravity', 'Gravity % (live)'), ('jump', 'Jump strength % (live)')]]

    def change(self, key, value):
        if key not in ('gravity', 'jump') or type(value) is not int or not 25 <= value <= 200:
            return False
        self.pending[key] = value / 100
        return True

    def tick(self, blocked=False):
        if self.future is not None:
            if not self.future.done():
                return
            try:
                result = self.future.result()
                if not result.get('ok'):
                    raise RuntimeError(result.get('error', 'World rejected settings'))
                self.failures = 0
            except (OSError, RuntimeError, TimeoutError) as error:
                # A phone edit or mod operation can own the mailbox briefly.
                # Retry with a fresh revision, keeping newer slider values.
                self.pending = dict(self.inflight, **self.pending)
                self.failures += 1
                if self.failures >= 3:
                    raise RuntimeError('Could not apply Mineclonia settings') from error
                self.retry_at = time.monotonic() + 1
            finally:
                self.future = None
        if self.pending and not blocked and time.monotonic() >= self.retry_at:
            self.inflight, self.pending = self.pending, {}
            self.future = self.worker.submit(command, self.root, 'set', self.inflight)

    def settle(self):
        """Release the world mailbox before disconnecting/replacing clients."""
        if self.future is not None:
            try:
                self.future.result(timeout=12)
            except (OSError, RuntimeError, TimeoutError):
                pass  # tick handles failed updates; disposal still closes clients

    def close(self):
        self.worker.shutdown(wait=True, cancel_futures=True)
