"""Headless server entry for the native Mac app: the SwiftUI app spawns this binary
(built with SpeechPracticeServer.spec) and talks to it over HTTP on PORT."""
from __future__ import annotations

import multiprocessing
import os
import sys
import time


def main() -> None:
    multiprocessing.freeze_support()
    if "-c" in sys.argv[1:] or "--multiprocessing-fork" in sys.argv[1:]:
        return
    import paths
    paths.ensure_dirs()
    if paths.FROZEN:
        log = open(paths.LOG_DIR / "server.log", "a", buffering=1, encoding="utf-8")
        sys.stdout = sys.stderr = log
        print(f"\n=== server launch {time.strftime('%Y-%m-%d %H:%M:%S')} pid {os.getpid()} ===")
    parent = os.environ.get("PARENT_PID")
    if parent:  # die with the app that launched us, even if it crashed
        import threading

        def watch() -> None:
            while True:
                time.sleep(2)
                if os.getppid() != int(parent):
                    os._exit(0)
        threading.Thread(target=watch, daemon=True).start()
    import uvicorn
    import server
    uvicorn.run(server.app, host="127.0.0.1", port=int(os.environ.get("PORT", "8765")), log_level="info")


if __name__ == "__main__":
    main()
