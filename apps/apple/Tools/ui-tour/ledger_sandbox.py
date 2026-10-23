"""Preserve the real service registry while a UI-tour batch uses fresh synthetic state."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time


def classify_services(table, app):
    app = Path(app)
    expected = app / "Contents/XPCServices/ai.xdict.app.DictionaryService.xpc/Contents/MacOS/XDictService"
    owned, foreign = [], []
    for line in table.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2:
            continue
        pid, executable = parts
        if Path(executable).name == "XDictService":
            (owned if Path(executable) == expected else foreign).append(int(pid))
    return owned, foreign


def stop_owned_service(app):
    """Quiesce only this staged test bundle; a reader's app or service prevents a swap."""
    app = Path(app)
    executable = app / "Contents/MacOS/XDict"

    def scan():
        result = subprocess.run(["/bin/ps", "-axww", "-o", "pid=,comm="], capture_output=True, text=True, check=True)
        owned, foreign = classify_services(result.stdout, app)
        for line in result.stdout.splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) == 2 and Path(parts[1]).name == "XDict":
                (owned if Path(parts[1]) == executable else foreign).append(int(parts[0]))
        if foreign:
            raise RuntimeError("A reader's XDict app or service is active; its registry was not touched.")
        return owned

    def send(pids, sig):
        for pid in pids:
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                pass

    send(scan(), signal.SIGTERM)
    for _ in range(50):
        if not scan():
            return
        time.sleep(0.1)
    send(scan(), signal.SIGKILL)
    for _ in range(20):
        if not scan():
            return
        time.sleep(0.1)
    raise RuntimeError("The staged test bundle is still active; the original registry backup is kept.")


class RegistrySandbox:
    def __init__(self, registry, state, stop):
        self.registry, self.state, self.stop = Path(registry), Path(state), stop
        self.original = self.state / "registry"
        self.receipt = self.state / "receipt.json"
        self.active = False
        self.had_original = False

    def __enter__(self):
        if self.state.exists():
            raise RuntimeError("A UI-tour registry backup already exists; restore it before another tour: " + str(self.state))
        if self.registry.is_symlink() or (self.registry.exists() and not self.registry.is_dir()):
            raise RuntimeError("The service registry is not an ordinary directory; nothing was changed.")
        self.stop()
        self.had_original = self.registry.exists()
        self.state.mkdir(mode=0o700, parents=True)
        self.receipt.write_text(json.dumps({"registry": str(self.registry), "had_original": self.had_original}))
        self.receipt.chmod(0o600)
        if self.had_original:
            self.registry.rename(self.original)
        try:
            self.registry.mkdir(mode=0o700, parents=True)
        except BaseException:
            if self.had_original and not self.registry.exists():
                self.original.rename(self.registry)
                self.receipt.unlink()
                self.state.rmdir()
            raise
        self.active = True
        return self

    def reset(self):
        if not self.active or not self.receipt.is_file() or self.registry.is_symlink():
            raise RuntimeError("No owned synthetic registry is active; nothing was removed.")
        self.stop()
        shutil.rmtree(self.registry)
        self.registry.mkdir(mode=0o700)

    def __exit__(self, kind, value, traceback):
        # If quiescing fails, preserve the original backup and receipt for explicit recovery.
        self.stop()
        if not self.active or self.registry.is_symlink():
            raise RuntimeError("The synthetic registry changed ownership; the original backup is kept.")
        shutil.rmtree(self.registry)
        if self.had_original:
            self.original.rename(self.registry)
        self.receipt.unlink()
        self.state.rmdir()
        self.active = False
        print("tour: service registry restored" if self.had_original else "tour: service registry removed (none existed before)", flush=True)
        return False
