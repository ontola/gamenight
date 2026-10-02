"""Expose the prototype's bounded physics controls through GameNight settings."""
import json
import time
from concurrent.futures import ThreadPoolExecutor
from prototype import command, read_json
from capabilities import SPECS, valid


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
        state = read_json(self.root / 'world/gamenight/status.json')
        values = state.get('values', {})
        return [{'key': key, 'label': s['label'] + (' tenths' if s['unit'] == 'strength' else ' %' if s['unit'] == 'multiplier' else ' (' + s['unit'] + ')') + ' (live)',
                 'kind': 'number', 'default': round(values.get(key, s['default']) * self.scale(s)),
                 'min': round(s['min'] * self.scale(s)), 'max': round(s['max'] * self.scale(s))}
                for key, s in SPECS.items() if key in values]

    @staticmethod
    def scale(spec):
        return 100 if spec['unit'] == 'multiplier' else 10 if spec['unit'] == 'strength' else 1

    def change(self, key, value):
        spec = SPECS.get(key)
        if not spec or type(value) is not int or not valid(key, value / self.scale(spec)):
            return False
        self.pending[key] = value / self.scale(spec)
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
