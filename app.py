"""Mac app entry point: runs the FastAPI server in a thread and shows the page
in a native WebKit window (pywebview). Packaged with PyInstaller, see build_app.sh.
"""
from __future__ import annotations

import fcntl
import multiprocessing
import os
import socket
import sys
import threading
import time
import urllib.request

import paths

WINDOW_TITLE = "口述练习记录"
_lock_file = None  # kept open for the life of the process


def single_instance() -> bool:
    """Take an exclusive lock; a second launch (or a stray child process) sees False."""
    global _lock_file
    paths.ensure_dirs()
    _lock_file = open(paths.DATA_DIR / "app.lock", "w")
    try:
        fcntl.flock(_lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except OSError:
        return False


def setup_logging() -> None:
    """A windowed app has no terminal; send stdout/stderr to a log file."""
    paths.ensure_dirs()
    if not paths.FROZEN:
        return
    log = open(paths.LOG_DIR / "app.log", "a", buffering=1, encoding="utf-8")
    sys.stdout = sys.stderr = log
    print(f"\n=== launch {time.strftime('%Y-%m-%d %H:%M:%S')} ===")


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def run_server(port: int) -> None:
    import uvicorn
    import server
    uvicorn.run(server.app, host="127.0.0.1", port=port, log_level="info")


def wait_ready(url: str, timeout: float = 60) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            urllib.request.urlopen(url + "/api/config", timeout=1)
            return True
        except Exception:
            time.sleep(0.2)
    return False


def allow_microphone() -> None:
    """WKWebView denies getUserMedia unless the UI delegate grants it. pywebview's
    delegate does not implement that callback, so subclass it and grant.
    macOS still shows its own one-time microphone permission prompt."""
    import objc
    import WebKit
    from webview.platforms import cocoa

    Base = cocoa.BrowserView.BrowserDelegate

    class MediaDelegate(Base):
        @objc.typedSelector(b"v@:@@@q@?")
        def webView_requestMediaCapturePermissionForOrigin_initiatedByFrame_type_decisionHandler_(
            self, webview, origin, frame, media_type, handler
        ):
            print("media capture request:", origin.host(), "type", media_type, "-> grant")
            handler(WebKit.WKPermissionDecisionGrant)

    cocoa.BrowserView.BrowserDelegate = MediaDelegate


def main() -> None:
    # Must be first: in the frozen app, multiprocessing helper children re-execute this
    # binary. freeze_support() (patched by PyInstaller) runs the helper and exits instead.
    multiprocessing.freeze_support()
    if "-c" in sys.argv[1:] or "--multiprocessing-fork" in sys.argv[1:]:
        return  # a child launch that freeze_support did not recognise; never open a window
    setup_logging()
    if not single_instance():
        print("another instance is running; exiting")
        return
    port = int(os.environ.get("SPEECH_PORT") or free_port())
    url = f"http://127.0.0.1:{port}"
    threading.Thread(target=run_server, args=(port,), daemon=True).start()
    if not wait_ready(url):
        print("server did not start; see log", file=sys.stderr)
        sys.exit(1)

    import webview
    allow_microphone()
    webview.create_window(WINDOW_TITLE, url, width=1120, height=940, min_size=(820, 600))
    webview.start()
    os._exit(0)  # closing the window ends the app; the server thread dies with it


if __name__ == "__main__":
    main()
