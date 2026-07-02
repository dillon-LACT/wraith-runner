import base64
import io

import pyautogui
from PIL import Image, ImageGrab

from config import RUNNER_SCREENSHOT_SCALE


def _find_window(title_fragment: str):
    import ctypes
    import ctypes.wintypes

    user32 = ctypes.windll.user32
    found = []

    def _cb(hwnd, _):
        if user32.IsWindowVisible(hwnd):
            length = user32.GetWindowTextLengthW(hwnd)
            buf = ctypes.create_unicode_buffer(length + 1)
            user32.GetWindowTextW(hwnd, buf, length + 1)
            if title_fragment.lower() in buf.value.lower():
                found.append(hwnd)
        return True

    WNDENUMPROC = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.wintypes.HWND, ctypes.wintypes.LPARAM)
    user32.EnumWindows(WNDENUMPROC(_cb), 0)
    return found[0] if found else None


def focus_primary(title_fragment: str, timeout: float = 12.0) -> bool:
    """Find a window by title (polling until it exists) and force it to the
    foreground on the primary monitor. Returns True if the window was found
    and focused, False on timeout.

    Uses AttachThreadInput because a plain SetForegroundWindow call from a
    background/automated process is silently ignored by Windows' foreground-
    lock restriction — the target window can stay unfocused indefinitely even
    though it renders on top, so clicks/keys can still be swallowed by
    whichever window last held real input focus (e.g. our own console).
    """
    import ctypes
    import ctypes.wintypes
    import time
    import logging
    _log = logging.getLogger(__name__)

    user32 = ctypes.windll.user32
    kernel32 = ctypes.windll.kernel32

    deadline = time.monotonic() + timeout
    hwnd = None
    while time.monotonic() < deadline:
        hwnd = _find_window(title_fragment)
        if hwnd:
            break
        time.sleep(0.3)

    if not hwnd:
        _log.warning(f"focus_primary: no window found matching '{title_fragment}' after {timeout}s")
        return False

    rect = ctypes.wintypes.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(rect))
    w = rect.right - rect.left
    h = rect.bottom - rect.top

    SWP_NOZORDER = 0x0004
    user32.SetWindowPos(hwnd, None, 0, 0, w, h, SWP_NOZORDER)

    fg_hwnd = user32.GetForegroundWindow()
    fg_thread = user32.GetWindowThreadProcessId(fg_hwnd, None)
    this_thread = kernel32.GetCurrentThreadId()
    attached = False
    if fg_thread and fg_thread != this_thread:
        attached = bool(user32.AttachThreadInput(this_thread, fg_thread, True))

    user32.BringWindowToTop(hwnd)
    user32.SetForegroundWindow(hwnd)

    if attached:
        user32.AttachThreadInput(this_thread, fg_thread, False)

    _log.info(f"focus_primary: moved '{title_fragment}' window to (0,0) size={w}x{h}")
    return True


def capture_screenshot() -> tuple[str, int, int]:
    """Returns (base64_png, width, height) at configured scale."""
    img = ImageGrab.grab()

    if RUNNER_SCREENSHOT_SCALE < 1.0:
        w = int(img.width * RUNNER_SCREENSHOT_SCALE)
        h = int(img.height * RUNNER_SCREENSHOT_SCALE)
        img = img.resize((w, h), Image.LANCZOS)

    buf = io.BytesIO()
    img.save(buf, format="PNG")
    b64 = base64.standard_b64encode(buf.getvalue()).decode()
    return b64, img.width, img.height


def capture_accessibility_tree() -> str | None:
    """Best-effort accessibility dump of the foreground window."""
    try:
        from pywinauto import Desktop
        win = Desktop(backend="uia").active()
        return win.dump_tree(depth=3)
    except Exception:
        return None
