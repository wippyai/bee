"""Prove that a shared Lua cache leaves the first desktop frame unchanged."""
import os
from pathlib import Path
import resource
import tempfile
import time
from unittest.mock import patch

from tui_smoke import Desktop


with tempfile.TemporaryDirectory(prefix="bee-compile-cache-") as temporary:
    root = Path(temporary)
    cache = root / "cache"
    frames = []
    for phase in ("cold", "warm"):
        home = root / (phase + "-home")
        home.mkdir()
        state = root / (phase + "-state")
        state.mkdir()
        before = resource.getrusage(resource.RUSAGE_CHILDREN)
        started = time.monotonic()
        with patch.dict(os.environ, {"HOME": str(home), "WIPPY_CACHE_DIR": str(cache)}):
            ui = Desktop(str(state))
        try:
            ui.wait("No applications open", timeout=20)
            assert ui.first_frame is not None and "Starting…" in "\n".join(ui.first_frame)
            frames.append(ui.first_frame)
            ui.quit()
        finally:
            ui.close()
        after = resource.getrusage(resource.RUSAGE_CHILDREN)
        cpu = after.ru_utime + after.ru_stime - before.ru_utime - before.ru_stime
        print(f"{phase} boot: {time.monotonic() - started:.3f}s wall, {cpu:.3f}s CPU", flush=True)

    assert frames[0] == frames[1], "Cold and warm boots drew different first frames"
    print("Cold and warm first frames are identical; HOME and state directories differ")
