import time
from typing import Any

import pyautogui
import pyperclip

from config import RUNNER_SCREENSHOT_SCALE

pyautogui.FAILSAFE = True
pyautogui.PAUSE = 0.05


def _scale(coord: list[int]) -> tuple[int, int]:
    x, y = coord
    s = RUNNER_SCREENSHOT_SCALE
    return int(x / s), int(y / s)

# Map xdotool/X11 key names Anthropic uses → pyautogui equivalents
_KEY_MAP: dict[str, str] = {
    "Return": "enter",
    "Escape": "esc",
    "BackSpace": "backspace",
    "Delete": "delete",
    "Tab": "tab",
    "space": "space",
    "Page_Up": "pageup",
    "Page_Down": "pagedown",
    "End": "end",
    "Home": "home",
    "Left": "left",
    "Up": "up",
    "Right": "right",
    "Down": "down",
    "super": "winleft",
    "F1": "f1", "F2": "f2", "F3": "f3", "F4": "f4",
    "F5": "f5", "F6": "f6", "F7": "f7", "F8": "f8",
    "F9": "f9", "F10": "f10", "F11": "f11", "F12": "f12",
}


def _map_key(key: str) -> str:
    return _KEY_MAP.get(key, key.lower())


def execute_action(action: dict[str, Any]) -> str:
    kind = action.get("action")

    if kind == "screenshot":
        return "screenshot_requested"

    elif kind == "left_click":
        x, y = _scale(action["coordinate"])
        pyautogui.click(x, y)

    elif kind == "right_click":
        x, y = _scale(action["coordinate"])
        pyautogui.rightClick(x, y)

    elif kind == "middle_click":
        x, y = _scale(action["coordinate"])
        pyautogui.middleClick(x, y)

    elif kind == "double_click":
        x, y = _scale(action["coordinate"])
        pyautogui.doubleClick(x, y)

    elif kind == "mouse_move":
        x, y = _scale(action["coordinate"])
        pyautogui.moveTo(x, y, duration=0.1)

    elif kind == "left_click_drag":
        sx, sy = _scale(action["start_coordinate"])
        ex, ey = _scale(action["coordinate"])
        pyautogui.moveTo(sx, sy)
        pyautogui.dragTo(ex, ey, duration=0.4, button="left")

    elif kind == "key":
        keys = [_map_key(k) for k in action["text"].split("+")]
        pyautogui.hotkey(*keys)

    elif kind == "type":
        text = action["text"]
        # Use clipboard for reliable Unicode/special-char input
        pyperclip.copy(text)
        pyautogui.hotkey("ctrl", "v")

    elif kind == "scroll":
        x, y = _scale(action["coordinate"])
        direction = action.get("direction", "down")
        amount = int(action.get("amount", 3))
        pyautogui.moveTo(x, y)
        clicks = amount if direction in ("up", "right") else -amount
        pyautogui.scroll(clicks)

    elif kind == "cursor_position":
        pos = pyautogui.position()
        return f"{pos.x},{pos.y}"

    elif kind == "wait":
        duration = float(action.get("duration", 1))
        time.sleep(min(duration, 10))
        return "ok"

    time.sleep(0.3)
    return "ok"
