import base64
import io

import pyautogui
from PIL import Image, ImageGrab

from config import RUNNER_SCREENSHOT_SCALE


def focus_primary(title_fragment: str) -> None:
    """Find a window by title and move it to the primary monitor using Win32 API."""
    import ctypes
    import ctypes.wintypes
    import logging
    _log = logging.getLogger(__name__)

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

    if not found:
        _log.warning(f"focus_primary: no window found matching '{title_fragment}'")
        return

    hwnd = found[0]
    rect = ctypes.wintypes.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(rect))
    w = rect.right - rect.left
    h = rect.bottom - rect.top

    SWP_NOZORDER = 0x0004
    user32.SetWindowPos(hwnd, None, 0, 0, w, h, SWP_NOZORDER)
    user32.SetForegroundWindow(hwnd)
    _log.info(f"focus_primary: moved '{title_fragment}' window to (0,0) size={w}x{h}")


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
