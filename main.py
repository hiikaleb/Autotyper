import base64
import ctypes
import io
import json
import os
import random
import re
import shutil
import string
import subprocess
import threading
import time
from datetime import datetime
from pathlib import Path
import sys

import pyautogui
import pyperclip
import keyboard
import webview

from PIL import Image, ImageDraw
import tkinter as tk

try:
    import pystray
except ImportError:
    pystray = None

try:
    import psutil
except ImportError:
    psutil = None


def data_dir():
    """Writable location: beside the .exe (or beside main.py when running
    from source). config.json and the screenshots folder live here."""
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent


def resource_dir():
    """Read-only bundled resources (index.html, style.css, script.js,
    AutoTyper.ico). PyInstaller 6+ --onedir builds unpack these into a
    _internal subfolder (sys._MEIPASS), not beside the .exe."""
    if getattr(sys, "frozen", False):
        return Path(getattr(sys, "_MEIPASS", Path(sys.executable).resolve().parent))
    return Path(__file__).resolve().parent


BASE = data_dir()
RES = resource_dir()
CONFIG_FILE = BASE / "config.json"
ICON_FILE = RES / "AutoTyper.ico"

DEFAULT_CONFIG = {
    "start_hotkey": "ctrl+alt+print screen",
    "screenshot_hotkey": "f8",
    "screenshot_region_hotkey": "shift+f8",
    "error_percent": 2.5,
    "min_delay_ms": 30,
    "max_delay_ms": 90,
    "remove_error": True,
    "add_error": True,
    "swap_error": True,
    "screenshot_folder": "screenshots",
    "minimize_to_tray": True,
    "start_hidden": False,
    "start_with_windows": False,
    "theme": "glass",
    "typing_sound": True,
    "auto_reduce_memory": False,
    "auto_reduce_interval_min": 30,
    "auto_reduce_threshold_percent": 85,
    "projects_root": "",
    "active_project": ""
}

typing_active = False
stop_event = threading.Event()
window = None
tray_icon = None
hotkey_handles = []
_selection_lock = threading.Lock()


def load_config():
    if not CONFIG_FILE.exists():
        save_config(DEFAULT_CONFIG.copy())
        return DEFAULT_CONFIG.copy()

    try:
        data = json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
        cfg = DEFAULT_CONFIG.copy()
        cfg.update(data)
        return cfg
    except Exception:
        return DEFAULT_CONFIG.copy()


def _autostart_path():
    if getattr(sys, "frozen", False):
        return f'"{Path(sys.executable).resolve()}"'
    return f'"{sys.executable}" "{Path(__file__).resolve()}"'


def _show_request_flag():
    return data_dir() / "show_request.flag"


def _acquire_single_instance():
    """Returns True if this is the only running instance. If AutoTyper
    is already running (e.g. the user clicked the shortcut/taskbar
    icon again while it was minimized to tray), this drops a flag file
    for the existing instance to pick up and returns False, so the
    caller can exit immediately instead of spawning a second tray icon
    and a second window."""
    global _instance_mutex_handle
    if sys.platform != "win32":
        return True
    try:
        kernel32 = ctypes.windll.kernel32
        handle = kernel32.CreateMutexW(None, False, "AutoTyper_SingleInstanceMutex_8f2c1a")
        ERROR_ALREADY_EXISTS = 183
        if kernel32.GetLastError() == ERROR_ALREADY_EXISTS:
            try:
                _show_request_flag().write_text("1", encoding="utf-8")
            except Exception:
                pass
            return False
        _instance_mutex_handle = handle  # keep alive for the process lifetime
        return True
    except Exception:
        return True


def _show_request_watcher():
    """Runs in the already-open instance. Picks up the flag dropped by
    a second launch attempt and brings the existing window forward
    instead of leaving a duplicate process/tray icon behind."""
    flag = _show_request_flag()
    while True:
        try:
            if flag.exists():
                flag.unlink()
                if window:
                    window.show()
                    window.restore()
        except Exception:
            pass
        time.sleep(0.5)


_instance_mutex_handle = None


def set_start_with_windows(enabled):
    """Adds/removes AutoTyper from HKCU...\\Run so it can launch on login,
    same idea as most tray utilities (ReduceMemory included)."""
    if sys.platform != "win32":
        return
    try:
        import winreg
        key = winreg.OpenKey(
            winreg.HKEY_CURRENT_USER,
            r"Software\Microsoft\Windows\CurrentVersion\Run",
            0, winreg.KEY_SET_VALUE
        )
        if enabled:
            winreg.SetValueEx(key, "AutoTyper", 0, winreg.REG_SZ, _autostart_path())
        else:
            try:
                winreg.DeleteValue(key, "AutoTyper")
            except FileNotFoundError:
                pass
        winreg.CloseKey(key)
    except Exception as e:
        status(f"Não foi possível atualizar a inicialização com o Windows: {e}")


def save_config(data):
    global config
    cfg = DEFAULT_CONFIG.copy()
    cfg.update(data)

    cfg["error_percent"] = max(0, min(100, float(cfg["error_percent"])))
    cfg["min_delay_ms"] = max(1, int(cfg["min_delay_ms"]))
    cfg["max_delay_ms"] = max(cfg["min_delay_ms"], int(cfg["max_delay_ms"]))
    cfg["auto_reduce_interval_min"] = max(1, int(cfg.get("auto_reduce_interval_min", 30)))
    cfg["auto_reduce_threshold_percent"] = max(1, min(100, int(cfg.get("auto_reduce_threshold_percent", 85))))
    if cfg.get("theme") not in ("glass", "opaque", "midnight"):
        cfg["theme"] = "glass"

    set_start_with_windows(cfg.get("start_with_windows", False))

    CONFIG_FILE.write_text(
        json.dumps(cfg, indent=2, ensure_ascii=False),
        encoding="utf-8"
    )
    config = cfg
    return cfg


config = load_config()


def status(text):
    if window:
        try:
            window.evaluate_js(
                f"window.setStatus({json.dumps(text, ensure_ascii=False)})"
            )
        except Exception:
            pass


def random_letter_like(char):
    result = random.choice(string.ascii_lowercase)
    return result.upper() if char.isupper() else result


def create_error(char):
    types = []
    if config["remove_error"]:
        types.append("remove")
    if config["add_error"]:
        types.append("add")
    if config["swap_error"]:
        types.append("swap")

    if not types or not char.isalpha():
        return char

    error_type = random.choice(types)

    if error_type == "remove":
        return ""
    if error_type == "add":
        return char + random_letter_like(char)
    return random_letter_like(char)


def type_worker(text):
    global typing_active

    # 1 second for positioning the cursor
    for _ in range(10):
        if stop_event.is_set():
            typing_active = False
            status("Parado")
            return
        time.sleep(0.1)

    min_delay = config["min_delay_ms"] / 1000
    max_delay = config["max_delay_ms"] / 1000
    error_percent = config["error_percent"]
    play_sound = config.get("typing_sound", True)

    for char in text:
        if stop_event.is_set():
            break

        if char.isalpha() and random.uniform(0, 100) < error_percent:
            output = create_error(char)
        else:
            output = char

        if output:
            pyautogui.write(output, interval=0)
            if play_sound and window:
                try:
                    window.evaluate_js("window.playKeySound && window.playKeySound()")
                except Exception:
                    pass

        delay = random.uniform(min_delay, max_delay)
        if char == " ":
            delay += random.uniform(0.01, 0.05)
        elif char in ".,!?;:":
            delay += random.uniform(0.03, 0.12)

        elapsed = 0
        while elapsed < delay and not stop_event.is_set():
            step = min(0.02, delay - elapsed)
            time.sleep(step)
            elapsed += step

    typing_active = False
    stop_event.clear()
    status("Concluído")


def start_typing(text):
    global typing_active

    if typing_active:
        return {"ok": False, "message": "Já está digitando."}
    if not text.strip():
        return {"ok": False, "message": "Digite um texto primeiro."}

    stop_event.clear()
    typing_active = True
    status("Preparando...")

    threading.Thread(target=type_worker, args=(text,), daemon=True).start()
    return {"ok": True}


def stop_typing():
    global typing_active
    stop_event.set()
    typing_active = False
    status("Parado")
    return {"ok": True}


def _screenshots_folder():
    folder = Path(config["screenshot_folder"])
    if not folder.is_absolute():
        folder = BASE / folder
    folder.mkdir(parents=True, exist_ok=True)
    return folder


def _thumbnail_b64(image, max_size=(300, 190)):
    """Small base64-encoded PNG preview so the UI can show it instantly
    without re-reading the file from disk."""
    try:
        thumb = image.copy()
        thumb.thumbnail(max_size)
        buf = io.BytesIO()
        thumb.save(buf, format="PNG")
        return base64.b64encode(buf.getvalue()).decode("ascii")
    except Exception:
        return None


def screenshot():
    folder = _screenshots_folder()
    filename = datetime.now().strftime("screenshot_%Y-%m-%d_%H-%M-%S.png")
    path = folder / filename

    img = pyautogui.screenshot()
    img.save(path)
    status(f"Screenshot salvo: {filename}")
    return {"ok": True, "file": str(path), "thumbnail": _thumbnail_b64(img)}


class _RegionSelector:
    """Fullscreen overlay that lets the user drag-select a rectangular
    region. It grabs a real screenshot FIRST and shows that frozen image
    behind the overlay (instead of the live desktop), so the selection
    can't be thrown off by things moving/changing underneath, and grabs
    input focus so ESC and the mouse actually stay on the overlay instead
    of leaking through to windows behind it."""

    def __init__(self, frozen_image):
        self.frozen_image = frozen_image
        self.result = None
        self.start_x = None
        self.start_y = None
        self.rect_id = None

    def run(self):
        from PIL import ImageTk

        root = tk.Tk()
        root.attributes("-fullscreen", True)
        root.attributes("-topmost", True)
        root.config(cursor="cross")

        photo = ImageTk.PhotoImage(self.frozen_image)

        canvas = tk.Canvas(root, highlightthickness=0, cursor="cross")
        canvas.pack(fill="both", expand=True)
        canvas.create_image(0, 0, image=photo, anchor="nw")
        canvas.image = photo  # keep a reference so it isn't garbage-collected

        sw, sh = root.winfo_screenwidth(), root.winfo_screenheight()
        canvas.create_rectangle(0, 0, sw, sh, fill="#05060d", stipple="gray50", outline="")

        hint_bg = canvas.create_rectangle(0, 0, 0, 0, fill="#12141f", outline="")
        hint = canvas.create_text(
            sw // 2, 34,
            text="Arraste para selecionar a área  •  ESC para cancelar",
            fill="#f3f4fb", font=("Segoe UI", 13, "bold")
        )
        bbox = canvas.bbox(hint)
        if bbox:
            canvas.coords(hint_bg, bbox[0] - 16, bbox[1] - 10, bbox[2] + 16, bbox[3] + 10)
        canvas.tag_raise(hint)

        size_label = canvas.create_text(
            0, 0, text="", fill="#b98cff", font=("Segoe UI", 11, "bold"), anchor="nw"
        )

        def on_press(event):
            self.start_x, self.start_y = event.x, event.y
            self.rect_id = canvas.create_rectangle(
                event.x, event.y, event.x, event.y,
                outline="#8b7bff", width=2, fill="#8b7bff", stipple="gray25"
            )

        def on_drag(event):
            if self.rect_id is not None:
                canvas.coords(self.rect_id, self.start_x, self.start_y, event.x, event.y)
                w = abs(event.x - self.start_x)
                h = abs(event.y - self.start_y)
                canvas.itemconfig(size_label, text=f"{w} × {h} px")
                canvas.coords(size_label, min(self.start_x, event.x) + 6, min(self.start_y, event.y) - 22)

        def on_release(event):
            x1, y1 = self.start_x, self.start_y
            x2, y2 = event.x, event.y
            left, top = min(x1, x2), min(y1, y2)
            width, height = abs(x2 - x1), abs(y2 - y1)
            if width > 3 and height > 3:
                self.result = (left, top, width, height)
            root.destroy()

        def on_escape(event=None):
            self.result = None
            root.destroy()

        canvas.bind("<ButtonPress-1>", on_press)
        canvas.bind("<B1-Motion>", on_drag)
        canvas.bind("<ButtonRelease-1>", on_release)
        root.bind("<Escape>", on_escape)
        canvas.bind("<Escape>", on_escape)

        # Force the overlay to actually own keyboard/mouse input so clicks
        # and ESC don't fall through to whatever window was behind it.
        root.lift()
        root.focus_force()
        canvas.focus_set()
        root.after(50, lambda: (root.focus_force(), root.grab_set_global()))

        root.mainloop()
        try:
            root.grab_release()
        except Exception:
            pass
        return self.result


def screenshot_region():
    """Lets the user drag-select a screen area and saves only that area."""
    if not _selection_lock.acquire(blocking=False):
        return {"ok": False, "message": "Seleção já em andamento."}

    try:
        status("Selecione a área na tela...")
        # Grab the real screenshot BEFORE showing the overlay, so the
        # image being cropped is the frozen moment before selection
        # started (not whatever changed on screen while dragging).
        time.sleep(0.15)
        frozen = pyautogui.screenshot()

        selector = _RegionSelector(frozen)
        region = selector.run()

        if not region:
            status("Seleção cancelada.")
            return {"ok": False, "message": "Seleção cancelada."}

        folder = _screenshots_folder()
        filename = datetime.now().strftime("screenshot_area_%Y-%m-%d_%H-%M-%S.png")
        path = folder / filename

        left, top, width, height = region
        img = frozen.crop((left, top, left + width, top + height))
        img.save(path)
        status(f"Screenshot da área salvo: {filename}")
        return {"ok": True, "file": str(path), "thumbnail": _thumbnail_b64(img)}
    finally:
        _selection_lock.release()


def open_screenshots_folder():
    folder = _screenshots_folder()
    try:
        if sys.platform == "win32":
            os.startfile(str(folder))  # noqa: S606
        elif sys.platform == "darwin":
            os.system(f'open "{folder}"')
        else:
            os.system(f'xdg-open "{folder}"')
        return {"ok": True}
    except Exception as e:
        return {"ok": False, "message": str(e)}


# ---------------------------------------------------------------------------
# Screen recording (gdigrab via the bundled ffmpeg.exe — no extra install)
# ---------------------------------------------------------------------------

_recording_state = {"proc": None, "path": None, "started_at": None,
                    "loopback_proc": None, "loopback_wav": None, "loopback_stopflag": None}
_recording_lock = threading.Lock()

# Sentinel value the front-end sends for the special "system audio"
# option, which doesn't map to a real dshow device name — it triggers
# the WASAPI loopback helper instead (see loopback_capture.ps1).
SYSTEM_LOOPBACK_SENTINEL = "__system_loopback__"


def _recording_ffmpeg_path():
    """The screen-recorder reuses the same ffmpeg.exe already bundled for
    the downloader, in engine/, instead of shipping a second copy."""
    return ENGINE_DIR / "ffmpeg.exe"


def list_audio_devices():
    """Asks ffmpeg's dshow input to list every audio device Windows
    exposes (mics, 'Stereo Mix' for system audio if the user has it
    enabled, virtual cables, etc.) so the UI can offer a picker instead
    of guessing a device name that only works on one PC.

    ffmpeg's device-listing output format varies a bit between builds,
    so this parses defensively instead of relying on one exact layout:
    it accepts both the classic "DirectShow audio devices" section
    header style and the inline "(audio)" tag style some builds use,
    and always skips "Alternative name" follow-up lines."""
    if sys.platform != "win32":
        return {"ok": False, "message": "Disponível apenas no Windows."}

    ffmpeg = _recording_ffmpeg_path()
    if not ffmpeg.exists():
        return {"ok": False, "message": f"ffmpeg.exe não encontrado em {ENGINE_DIR}."}

    try:
        import subprocess
        result = subprocess.run(
            [str(ffmpeg), "-hide_banner", "-list_devices", "true", "-f", "dshow", "-i", "dummy"],
            capture_output=True, text=True, encoding="utf-8", errors="replace",
            creationflags=subprocess.CREATE_NO_WINDOW, timeout=15
        )
        # ffmpeg always "fails" here (there's no real -i dummy device) and
        # writes the device list to stderr — that's expected, not an error.
        output = (result.stderr or "") + "\n" + (result.stdout or "")
    except Exception as e:
        return {"ok": False, "message": str(e)}

    devices = []
    in_audio_section = False
    for raw_line in output.splitlines():
        line = raw_line.strip()
        if not line or '"' not in line:
            continue
        if "alternative name" in line.lower():
            continue

        if "directshow audio devices" in line.lower():
            in_audio_section = True
            continue
        if "directshow video devices" in line.lower():
            in_audio_section = False
            continue

        match = re.search(r'"([^"]+)"', line)
        if not match:
            continue
        name = match.group(1)

        # Some ffmpeg builds tag each device inline instead of using
        # section headers, e.g.: "Microphone (Realtek)" (audio)
        if "(audio)" in line.lower():
            if name not in devices:
                devices.append(name)
        elif "(video)" in line.lower():
            continue
        elif in_audio_section and name not in devices:
            devices.append(name)

    # Devices whose name matches one of these are actually a loopback of
    # the system's own audio output (not a microphone): "Stereo Mix" is
    # the classic Windows one, "What U Hear" is Creative/SoundBlaster's
    # equivalent, and "CABLE Output"/"VB-Audio" is what shows up once
    # someone installs VB-Audio Virtual Cable (a free virtual loopback
    # driver — the actual fix on PCs where Windows hides Stereo Mix,
    # which is most modern laptops/Realtek drivers).
    _LOOPBACK_HINTS = ("stereo mix", "what u hear", "cable output", "vb-audio", "loopback")
    device_list = [
        {"name": d, "is_loopback": any(h in d.lower() for h in _LOOPBACK_HINTS)}
        for d in devices
    ]
    has_loopback = any(d["is_loopback"] for d in device_list)

    if not devices:
        return {
            "ok": True,
            "devices": [SYSTEM_LOOPBACK_SENTINEL],
            "device_list": [{"name": SYSTEM_LOOPBACK_SENTINEL, "is_loopback": True,
                              "label": "Áudio do sistema (automático, via WASAPI)"}],
            "has_loopback": True,
            "message": ("Nenhum microfone encontrado, mas 'Áudio do sistema' funciona sem "
                        "precisar de microfone nem de Estéreo Mix.")
        }

    return {
        "ok": True,
        "devices": [SYSTEM_LOOPBACK_SENTINEL] + devices,
        "device_list": [{"name": SYSTEM_LOOPBACK_SENTINEL, "is_loopback": True,
                          "label": "Áudio do sistema (automático, via WASAPI)"}] + device_list,
        "has_loopback": True,  # the WASAPI option above always works, no device required
        "message": None
    }


def get_recording_status():
    with _recording_lock:
        if not _recording_state["proc"]:
            return {"recording": False}
        elapsed = time.time() - _recording_state["started_at"]
        return {"recording": True, "seconds": round(elapsed), "file": str(_recording_state["path"])}


RECORDING_QUALITY_PRESETS = {
    "light": {"framerate": 24, "crf": "28", "preset": "veryfast", "scale_height": 720,
              "label": "Leve (720p, arquivo pequeno)"},
    "standard": {"framerate": 30, "crf": "23", "preset": "veryfast", "scale_height": None,
                 "label": "Padrão (nativo, 30fps)"},
    "high": {"framerate": 30, "crf": "18", "preset": "fast", "scale_height": None,
             "label": "Alta (nativo, qualidade maior)"},
    "smooth60": {"framerate": 60, "crf": "20", "preset": "veryfast", "scale_height": None,
                 "label": "Fluida (nativo, 60fps)"},
}


def get_recording_quality_presets():
    return {"ok": True, "presets": [
        {"id": key, "label": val["label"]} for key, val in RECORDING_QUALITY_PRESETS.items()
    ]}


def start_screen_recording(mode="full", audio_device=None, quality="standard"):
    """Starts recording the screen (or a selected region) to an MP4 file
    using the bundled ffmpeg.exe's gdigrab input. Windows only. When
    audio_device is given (a name returned by list_audio_devices), audio
    from that device is captured and muxed into the same MP4. `quality`
    picks one of RECORDING_QUALITY_PRESETS (framerate + encode settings,
    with an optional downscale for the lighter preset)."""
    if sys.platform != "win32":
        return {"ok": False, "message": "Gravação de tela disponível apenas no Windows."}

    with _recording_lock:
        if _recording_state["proc"]:
            return {"ok": False, "message": "Já tem uma gravação em andamento."}

    ffmpeg = _recording_ffmpeg_path()
    if not ffmpeg.exists():
        return {"ok": False, "message": f"ffmpeg.exe não encontrado em {ENGINE_DIR}."}

    preset = RECORDING_QUALITY_PRESETS.get(quality, RECORDING_QUALITY_PRESETS["standard"])

    region = None
    if mode == "region":
        if not _selection_lock.acquire(blocking=False):
            return {"ok": False, "message": "Seleção já em andamento."}
        try:
            status("Selecione a área para gravar...")
            time.sleep(0.15)
            frozen = pyautogui.screenshot()
            selector = _RegionSelector(frozen)
            region = selector.run()
            if not region:
                status("Seleção cancelada.")
                return {"ok": False, "message": "Seleção cancelada."}
        finally:
            _selection_lock.release()

    folder = _screenshots_folder()
    filename = datetime.now().strftime("gravacao_%Y-%m-%d_%H-%M-%S.mp4")
    path = folder / filename

    cmd = [str(ffmpeg), "-y", "-thread_queue_size", "1024",
           "-f", "gdigrab", "-framerate", str(preset["framerate"])]
    if region:
        left, top, width, height = region
        # gdigrab needs even dimensions for yuv420p encoding.
        width -= width % 2
        height -= height % 2
        cmd += ["-offset_x", str(left), "-offset_y", str(top), "-video_size", f"{width}x{height}"]
    cmd += ["-i", "desktop"]

    using_system_loopback = (audio_device == SYSTEM_LOOPBACK_SENTINEL)
    real_audio_device = None if using_system_loopback else audio_device

    if real_audio_device:
        # -thread_queue_size here is the actual fix for audio silently not
        # showing up: without it, ffmpeg's dshow audio input can get starved
        # while gdigrab's slower screen-capture thread is running, and audio
        # frames get dropped instead of buffered.
        cmd += ["-thread_queue_size", "1024", "-f", "dshow",
                "-audio_buffer_size", "50", "-i", f"audio={real_audio_device}"]

    cmd += ["-c:v", "libx264", "-preset", preset["preset"], "-crf", preset["crf"], "-pix_fmt", "yuv420p"]
    if preset["scale_height"]:
        # -2 keeps width even and preserves aspect ratio.
        cmd += ["-vf", f"scale=-2:{preset['scale_height']}"]
    if real_audio_device:
        cmd += ["-c:a", "aac", "-b:a", "192k", "-ar", "44100", "-async", "1"]
    cmd += [str(path)]

    # "System audio" doesn't go through ffmpeg's dshow input at all — there's
    # no driver for it to open. Instead a separate WASAPI loopback helper
    # (loopback_capture.ps1) records the system's audio output to its own
    # WAV file in parallel, and stop_screen_recording() muxes the two
    # together once both have finished.
    loopback_proc = None
    loopback_wav = None
    loopback_stopflag = None
    if using_system_loopback:
        ps1 = ENGINE_DIR / "loopback_capture.ps1"
        if not ps1.exists():
            return {"ok": False, "message": f"loopback_capture.ps1 não encontrado em {ENGINE_DIR}."}
        loopback_wav = path.with_suffix(".loopback.wav")
        loopback_stopflag = path.with_suffix(".loopback.stop")
        loopback_readyflag = path.with_suffix(".loopback.ready")
        try:
            if loopback_stopflag.exists():
                loopback_stopflag.unlink()
            if loopback_readyflag.exists():
                loopback_readyflag.unlink()
            loopback_proc = subprocess.Popen(
                ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
                 "-File", str(ps1), str(loopback_wav), str(loopback_stopflag), str(loopback_readyflag)],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                creationflags=subprocess.CREATE_NO_WINDOW
            )
        except Exception as e:
            return {"ok": False, "message": f"Não foi possível iniciar a captura de áudio do sistema: {e}"}

        # Wait for the loopback helper to confirm WASAPI is ACTUALLY
        # capturing (not just that the process launched — the embedded C#
        # needs to JIT-compile + set up COM first, which is slow on a cold
        # first run). Starting the video recorder before this happens is
        # exactly what caused audio to lag behind video. 5s timeout is a
        # generous ceiling for even a cold Add-Type compile; if it's somehow
        # still not ready by then we proceed anyway rather than fail the
        # whole recording — a little drift beats no recording at all.
        wait_started = time.time()
        while not loopback_readyflag.exists():
            if time.time() - wait_started > 5:
                break
            if loopback_proc.poll() is not None:
                # The helper process died before ever getting ready —
                # no point waiting further, but still let video-only
                # recording proceed.
                break
            time.sleep(0.02)
        try:
            if loopback_readyflag.exists():
                loopback_readyflag.unlink()
        except Exception:
            pass

    try:
        proc = subprocess.Popen(
            cmd, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            creationflags=subprocess.CREATE_NO_WINDOW
        )
    except FileNotFoundError:
        if loopback_proc:
            try:
                loopback_stopflag.touch()
                loopback_proc.wait(timeout=5)
            except Exception:
                pass
        return {"ok": False, "message": "Não foi possível executar o ffmpeg.exe (pode ter sido bloqueado pelo antivírus)."}
    except Exception as e:
        if loopback_proc:
            try:
                loopback_stopflag.touch()
                loopback_proc.wait(timeout=5)
            except Exception:
                pass
        return {"ok": False, "message": str(e)}

    with _recording_lock:
        _recording_state["proc"] = proc
        _recording_state["path"] = path
        _recording_state["started_at"] = time.time()
        _recording_state["loopback_proc"] = loopback_proc
        _recording_state["loopback_wav"] = loopback_wav
        _recording_state["loopback_stopflag"] = loopback_stopflag

    status(f"Gravando tela: {filename}")
    return {"ok": True, "file": str(path)}


def stop_screen_recording():
    with _recording_lock:
        proc = _recording_state["proc"]
        path = _recording_state["path"]
        loopback_proc = _recording_state["loopback_proc"]
        loopback_wav = _recording_state["loopback_wav"]
        loopback_stopflag = _recording_state["loopback_stopflag"]

    if not proc:
        return {"ok": False, "message": "Nenhuma gravação em andamento."}

    try:
        # 'q' on stdin tells ffmpeg to finalize the MP4 container cleanly
        # instead of leaving a corrupted file behind.
        if proc.stdin:
            proc.stdin.write(b"q")
            proc.stdin.flush()
        proc.wait(timeout=10)
    except Exception:
        try:
            proc.terminate()
        except Exception:
            pass

    final_path = path
    if loopback_proc:
        try:
            loopback_stopflag.touch()
            loopback_proc.wait(timeout=8)
        except Exception:
            try:
                loopback_proc.terminate()
            except Exception:
                pass
        final_path = _mux_loopback_audio(path, loopback_wav) or path
        for f in (loopback_wav, loopback_stopflag):
            try:
                if f and Path(f).exists():
                    Path(f).unlink()
            except Exception:
                pass

    with _recording_lock:
        _recording_state["proc"] = None
        _recording_state["started_at"] = None
        _recording_state["loopback_proc"] = None
        _recording_state["loopback_wav"] = None
        _recording_state["loopback_stopflag"] = None
        _recording_state["path"] = final_path

    status(f"Gravação salva: {final_path.name}")

    thumbnail = None
    try:
        thumbnail = _video_thumbnail_b64(final_path)
    except Exception:
        pass

    return {"ok": True, "file": str(final_path), "thumbnail": thumbnail}


def _mux_loopback_audio(video_path, wav_path):
    """Combines the video-only MP4 (from ffmpeg/gdigrab) with the WAV
    captured in parallel by the WASAPI loopback helper, into a single
    final MP4. Runs after both recorders have already stopped, so there's
    no live-mixing complexity — just a straightforward mux + re-encode of
    the audio track. Returns the new Path on success, or None on failure
    (in which case the caller falls back to keeping the video-only file)."""
    try:
        wav_path = Path(wav_path)
        if not wav_path.exists() or wav_path.stat().st_size < 1024:
            return None  # nothing usable was captured (e.g. total silence + no header)

        ffmpeg = _recording_ffmpeg_path()
        merged_path = video_path.with_name(video_path.stem + "_final.mp4")
        cmd = [
            str(ffmpeg), "-y",
            "-i", str(video_path),
            "-i", str(wav_path),
            "-c:v", "copy",
            "-c:a", "aac", "-b:a", "192k",
            "-map", "0:v:0", "-map", "1:a:0",
            "-shortest",
            str(merged_path),
        ]
        result = subprocess.run(
            cmd, capture_output=True, timeout=120,
            creationflags=subprocess.CREATE_NO_WINDOW
        )
        if result.returncode != 0 or not merged_path.exists():
            return None

        video_path.unlink(missing_ok=True)
        merged_path.rename(video_path)
        return video_path
    except Exception:
        return None


def cancel_screen_recording():
    """Stops the current recording like stop_screen_recording, but deletes
    the resulting file instead of keeping it — for 'that take was bad,
    scrap it' without having to go find and delete the file manually."""
    with _recording_lock:
        proc = _recording_state["proc"]
        path = _recording_state["path"]
        loopback_proc = _recording_state["loopback_proc"]
        loopback_wav = _recording_state["loopback_wav"]
        loopback_stopflag = _recording_state["loopback_stopflag"]

    if not proc:
        return {"ok": False, "message": "Nenhuma gravação em andamento."}

    try:
        if proc.stdin:
            proc.stdin.write(b"q")
            proc.stdin.flush()
        proc.wait(timeout=10)
    except Exception:
        try:
            proc.terminate()
        except Exception:
            pass

    if loopback_proc:
        try:
            loopback_stopflag.touch()
            loopback_proc.wait(timeout=8)
        except Exception:
            try:
                loopback_proc.terminate()
            except Exception:
                pass
        for f in (loopback_wav, loopback_stopflag):
            try:
                if f and Path(f).exists():
                    Path(f).unlink()
            except Exception:
                pass

    with _recording_lock:
        _recording_state["proc"] = None
        _recording_state["started_at"] = None
        _recording_state["loopback_proc"] = None
        _recording_state["loopback_wav"] = None
        _recording_state["loopback_stopflag"] = None

    try:
        if path and Path(path).exists():
            Path(path).unlink()
    except Exception:
        pass

    status("Gravação descartada.")
    return {"ok": True}


def _video_thumbnail_b64(video_path):
    """Grabs a single frame near the start of the recording via ffmpeg,
    so the UI can show a thumbnail like it does for screenshots."""
    ffmpeg = _recording_ffmpeg_path()
    if not ffmpeg.exists():
        return None
    import subprocess
    tmp_frame = video_path.with_suffix(".thumb.jpg")
    cmd = [str(ffmpeg), "-y", "-ss", "0.5", "-i", str(video_path),
           "-frames:v", "1", "-q:v", "4", str(tmp_frame)]
    subprocess.run(
        cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        creationflags=subprocess.CREATE_NO_WINDOW, timeout=15
    )
    if not tmp_frame.exists():
        return None
    try:
        img = Image.open(tmp_frame)
        b64 = _thumbnail_b64(img)
        img.close()
        return b64
    finally:
        try:
            tmp_frame.unlink()
        except Exception:
            pass


# ---------------------------------------------------------------------------
# Memory optimization (ReduceMemory-style RAM trim)
# ---------------------------------------------------------------------------

def get_memory_stats():
    if psutil is None:
        return {"ok": False, "message": "psutil não instalado."}
    try:
        vm = psutil.virtual_memory()
        return {
            "ok": True,
            "total_gb": round(vm.total / (1024 ** 3), 1),
            "available_gb": round(vm.available / (1024 ** 3), 1),
            "used_percent": vm.percent,
        }
    except Exception as e:
        return {"ok": False, "message": str(e)}


def reduce_memory():
    """Trims the working set of every process it has permission to touch,
    the same approach classic RAM-cleaner tools like ReduceMemory use
    (EmptyWorkingSet via the Windows API), then reports how much RAM
    became available."""
    if sys.platform != "win32":
        return {"ok": False, "message": "Otimização de RAM disponível apenas no Windows."}
    if psutil is None:
        return {"ok": False, "message": "psutil não instalado. Rode: pip install psutil"}

    before = psutil.virtual_memory().available

    PROCESS_QUERY_INFORMATION = 0x0400
    PROCESS_SET_QUOTA = 0x0100
    kernel32 = ctypes.windll.kernel32
    psapi = ctypes.windll.psapi

    freed_count = 0
    for proc in psutil.process_iter(["pid"]):
        pid = proc.info["pid"]
        handle = kernel32.OpenProcess(
            PROCESS_QUERY_INFORMATION | PROCESS_SET_QUOTA, False, pid
        )
        if not handle:
            continue
        try:
            if psapi.EmptyWorkingSet(handle):
                freed_count += 1
        except Exception:
            pass
        finally:
            kernel32.CloseHandle(handle)

    # Let the OS settle before measuring the result.
    time.sleep(0.4)
    after = psutil.virtual_memory().available
    freed_mb = round(max(0, after - before) / (1024 ** 2), 1)

    status(f"Memória otimizada: {freed_mb} MB liberados em {freed_count} processos.")
    return {"ok": True, "freed_mb": freed_mb, "processes": freed_count}


def clear_temp_files():
    """Deletes what it can from %TEMP%, same idea as the 'extra cleanup'
    button in ReduceMemory. Skips locked files silently."""
    if sys.platform != "win32":
        return {"ok": False, "message": "Disponível apenas no Windows."}
    import shutil
    import tempfile

    temp_dir = Path(tempfile.gettempdir())
    freed_bytes = 0
    removed = 0
    for item in temp_dir.glob("*"):
        try:
            size = item.stat().st_size if item.is_file() else sum(
                f.stat().st_size for f in item.rglob("*") if f.is_file()
            )
            if item.is_dir():
                shutil.rmtree(item, ignore_errors=True)
            else:
                item.unlink()
            freed_bytes += size
            removed += 1
        except Exception:
            continue

    freed_mb = round(freed_bytes / (1024 ** 2), 1)
    status(f"Temporários limpos: {freed_mb} MB em {removed} itens.")
    return {"ok": True, "freed_mb": freed_mb, "removed": removed}


def empty_recycle_bin():
    if sys.platform != "win32":
        return {"ok": False, "message": "Disponível apenas no Windows."}
    try:
        SHERB_NOCONFIRMATION = 0x00000001
        SHERB_NOPROGRESSUI = 0x00000002
        SHERB_NOSOUND = 0x00000004
        ctypes.windll.shell32.SHEmptyRecycleBinW(
            None, None,
            SHERB_NOCONFIRMATION | SHERB_NOPROGRESSUI | SHERB_NOSOUND
        )
        status("Lixeira esvaziada.")
        return {"ok": True}
    except Exception as e:
        return {"ok": False, "message": str(e)}


def clear_clipboard():
    try:
        pyperclip.copy("")
        status("Área de transferência limpa.")
        return {"ok": True}
    except Exception as e:
        return {"ok": False, "message": str(e)}


def _auto_memory_loop():
    """Background scheduler: every 30s, checks whether it's time to run
    an automatic memory cleanup (based on elapsed interval or the RAM
    usage threshold configured in Settings)."""
    last_run = time.time()
    while True:
        time.sleep(30)
        if not config.get("auto_reduce_memory", False):
            continue
        if psutil is None:
            continue
        try:
            usage = psutil.virtual_memory().percent
        except Exception:
            continue

        interval_s = config.get("auto_reduce_interval_min", 30) * 60
        threshold = config.get("auto_reduce_threshold_percent", 85)
        due_by_time = (time.time() - last_run) >= interval_s
        due_by_usage = usage >= threshold

        if due_by_time or due_by_usage:
            reduce_memory()
            last_run = time.time()


def unregister_hotkeys():
    global hotkey_handles
    for handle in hotkey_handles:
        try:
            keyboard.remove_hotkey(handle)
        except Exception:
            pass
    hotkey_handles = []


def register_hotkeys():
    global hotkey_handles
    unregister_hotkeys()

    hotkey_handles.append(
        keyboard.add_hotkey(config["start_hotkey"], toggle_hotkey, suppress=False)
    )
    hotkey_handles.append(
        keyboard.add_hotkey(config["screenshot_hotkey"], screenshot, suppress=False)
    )
    if config.get("screenshot_region_hotkey"):
        hotkey_handles.append(
            keyboard.add_hotkey(
                config["screenshot_region_hotkey"],
                lambda: threading.Thread(target=screenshot_region, daemon=True).start(),
                suppress=False
            )
        )


def hotkey_listener():
    register_hotkeys()
    keyboard.wait()


def toggle_hotkey():
    if typing_active:
        stop_typing()
    elif window:
        try:
            window.evaluate_js("window.requestTextForHotkey()")
        except Exception:
            pass


class Api:
    def get_config(self):
        return config

    def save_config(self, data):
        try:
            cfg = save_config(data)
            register_hotkeys()
            status("Configurações salvas.")
            return {"ok": True, "config": cfg}
        except Exception as e:
            return {"ok": False, "message": str(e)}

    def start(self, text):
        return start_typing(text)

    def stop(self):
        return stop_typing()

    def take_screenshot(self):
        return screenshot()

    def take_screenshot_region(self):
        # Tk needs its own thread with a mainloop; run it off the
        # pywebview/JS call thread so the UI doesn't block.
        result_holder = {}
        done = threading.Event()

        def worker():
            result_holder["result"] = screenshot_region()
            done.set()

        threading.Thread(target=worker, daemon=True).start()
        done.wait(timeout=120)
        return result_holder.get("result", {"ok": False, "message": "Tempo esgotado."})

    def copy_to_clipboard(self, text):
        pyperclip.copy(text)
        return {"ok": True}

    def get_clipboard_url(self):
        return get_clipboard_url()

    def choose_folder(self):
        try:
            result = window.create_file_dialog(webview.FOLDER_DIALOG)
            if result:
                return {"ok": True, "folder": result[0]}
            return {"ok": False}
        except Exception as e:
            return {"ok": False, "message": str(e)}

    def open_screenshots_folder(self):
        return open_screenshots_folder()

    def start_screen_recording(self, mode="full", audio_device=None, quality="standard"):
        return start_screen_recording(mode, audio_device, quality)

    def get_recording_quality_presets(self):
        return get_recording_quality_presets()

    def stop_screen_recording(self):
        return stop_screen_recording()

    def cancel_screen_recording(self):
        return cancel_screen_recording()

    def get_recording_status(self):
        return get_recording_status()

    def list_audio_devices(self):
        return list_audio_devices()

    def get_memory_stats(self):
        return get_memory_stats()

    def reduce_memory(self):
        return reduce_memory()

    def clear_temp_files(self):
        return clear_temp_files()

    def empty_recycle_bin(self):
        return empty_recycle_bin()

    def clear_clipboard(self):
        return clear_clipboard()

    def launch_ytdlp_tool(self):
        return open_engine_folder()

    def list_projects(self):
        return list_projects()

    def create_project(self, name):
        return create_project(name)

    def set_active_project(self, name):
        return set_active_project(name)

    def rename_project(self, old_name, new_name):
        return rename_project(old_name, new_name)

    def delete_project(self, name):
        return delete_project(name)

    def get_active_project(self):
        return get_active_project()

    def open_active_project_folder(self):
        return open_active_project_folder()

    def start_download(self, url, category, quality, filename=None):
        return start_download(url, category, quality, filename)

    def get_download_queue(self):
        return get_download_queue()

    def cancel_queued_download(self, job_id):
        return cancel_queued_download(job_id)

    def open_downloads_log(self):
        return open_downloads_log()

    def open_crash_log(self):
        return open_crash_log()

    def capture_epidemic_login(self):
        return capture_epidemic_login()

    def list_formats(self, url):
        return list_formats(url)

    def list_supported_sites(self):
        return list_supported_sites()

    def update_ytdlp(self):
        return update_ytdlp()

    def reset_cookies(self):
        return reset_cookies()

    def backup_premiere_config(self):
        return backup_premiere_config()

    def restore_premiere_config(self):
        return restore_premiere_config()

    def browse_media(self, subpath=""):
        return browse_media(subpath)

    def get_file_url(self, path):
        return get_file_url(path)

    def minimize_to_tray(self):
        if config.get("minimize_to_tray", True):
            window.hide()
            return {"ok": True}
        window.minimize()
        return {"ok": True}

    def quit_app(self):
        do_quit()
        return {"ok": True}


def on_loaded():
    threading.Thread(target=hotkey_listener, daemon=True).start()


# ---------------------------------------------------------------------------
# System tray icon (behaves like ReduceMemory: keeps running in the tray,
# window can be hidden/shown from there, hotkeys keep working in background)
# ---------------------------------------------------------------------------

def _tray_image():
    try:
        return Image.open(ICON_FILE)
    except Exception:
        img = Image.new("RGBA", (64, 64), (124, 92, 255, 255))
        draw = ImageDraw.Draw(img)
        draw.text((22, 20), "A", fill="white")
        return img


def _tray_show(icon=None, item=None):
    if window:
        window.show()
        window.restore()


def _tray_start_stop(icon=None, item=None):
    if typing_active:
        stop_typing()
    else:
        if window:
            window.show()
            window.evaluate_js("window.requestTextForHotkey()")


def _tray_screenshot(icon=None, item=None):
    threading.Thread(target=screenshot, daemon=True).start()


def _tray_screenshot_region(icon=None, item=None):
    threading.Thread(target=screenshot_region, daemon=True).start()


def _tray_reduce_memory(icon=None, item=None):
    threading.Thread(target=reduce_memory, daemon=True).start()


def _tray_quit(icon=None, item=None):
    do_quit()


def do_quit():
    global tray_icon

    # Start the force-kill watchdog FIRST, before any graceful-shutdown
    # step runs. Previously this was scheduled only at the end of
    # do_quit(), so if any step below hung (window.destroy() waiting on
    # a WebView2/tray native call that never returns — the actual cause
    # of the app surviving in Task Manager after "closing"), the
    # watchdog thread never got created and the process never died.
    # Starting it up front guarantees the process exits within ~1.5s no
    # matter what hangs afterwards.
    def _hard_exit():
        time.sleep(1.5)
        os._exit(0)

    threading.Thread(target=_hard_exit, daemon=True).start()

    unregister_hotkeys()
    try:
        keyboard.unhook_all()
    except Exception:
        pass
    # If a screen recording is still running, stop ffmpeg cleanly instead
    # of leaving it orphaned in the background after the app "closes".
    try:
        if _recording_state.get("proc"):
            stop_screen_recording()
    except Exception:
        pass
    if tray_icon:
        try:
            tray_icon.stop()
        except Exception:
            pass
    if window:
        try:
            window.destroy()
        except Exception:
            pass
    # (Known issue: `keyboard`'s low-level Windows hook, or window.destroy()
    # itself, can occasionally hang instead of returning — that's exactly
    # what the watchdog started at the top of this function is for.)


def start_tray():
    global tray_icon
    if pystray is None:
        return

    menu = pystray.Menu(
        pystray.MenuItem("Mostrar AutoTyper", _tray_show, default=True),
        pystray.MenuItem("Iniciar / Parar digitação", _tray_start_stop),
        pystray.MenuItem("Screenshot (tela inteira)", _tray_screenshot),
        pystray.MenuItem("Screenshot (selecionar área)", _tray_screenshot_region),
        pystray.MenuItem("Liberar memória (RAM)", _tray_reduce_memory),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem("Sair", _tray_quit),
    )

    tray_icon = pystray.Icon("AutoTyper", _tray_image(), "AutoTyper", menu)
    threading.Thread(target=tray_icon.run, daemon=True).start()


PROJECT_SUBFOLDERS = [
    "01. Documentos", "02. Arquivos", "03. Edicao", "04. Imagens", "05. VFX",
    "06. Sound Effects", "07. Musica", "08. Finalizados", "09. Lixo", "10. Thumbnails"
]
PROJECT_ARQUIVOS_SUBFOLDERS = ["Videos", "Audios", "Outros_Sites"]

ENGINE_DIR = RES / "engine"
YTDLP_EXE = ENGINE_DIR / "yt-dlp.exe"
FFMPEG_EXE = ENGINE_DIR / "ffmpeg.exe"
COOKIE_SCRIPT = ENGINE_DIR / "capturar_cookies.py"

MEDIA_EXTENSIONS = {
    "video": {".mp4", ".mov", ".mkv", ".avi", ".webm", ".m4v"},
    "audio": {".mp3", ".wav", ".m4a", ".aac", ".flac", ".ogg"},
    "image": {".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp"},
}


def _projects_root():
    root = Path(config.get("projects_root") or (BASE / "Projetos"))
    root.mkdir(parents=True, exist_ok=True)
    return root


def _clean_name(name):
    import re
    return re.sub(r'[\\/:*?"<>|]', "_", name).strip() or "Projeto"


def create_project(name):
    root = _projects_root()
    clean = _clean_name(name)
    project_dir = root / clean
    if project_dir.exists():
        return {"ok": False, "message": "Já existe um projeto com esse nome."}

    project_dir.mkdir(parents=True)
    for sub in PROJECT_SUBFOLDERS:
        (project_dir / sub).mkdir(exist_ok=True)
    for sub in PROJECT_ARQUIVOS_SUBFOLDERS:
        (project_dir / "02. Arquivos" / sub).mkdir(exist_ok=True)

    set_active_project(clean)
    status(f"Projeto criado: {clean}")
    return {"ok": True, "name": clean}


def list_projects():
    root = _projects_root()
    names = sorted([p.name for p in root.iterdir() if p.is_dir()])
    return {"ok": True, "projects": names, "active": config.get("active_project")}


def set_active_project(name):
    global config
    project_dir = _projects_root() / name
    if not project_dir.exists():
        return {"ok": False, "message": "Projeto não encontrado."}
    cfg = dict(config)
    cfg["active_project"] = name
    save_config(cfg)
    status(f"Projeto ativo: {name}")
    return {"ok": True, "name": name}


def get_active_project():
    name = config.get("active_project")
    if not name:
        return {"ok": False}
    project_dir = _projects_root() / name
    if not project_dir.exists():
        return {"ok": False}
    return {"ok": True, "name": name, "path": str(project_dir)}


def rename_project(old_name, new_name):
    global config
    root = _projects_root()
    old_dir = root / old_name
    if not old_dir.exists():
        return {"ok": False, "message": "Projeto não encontrado."}

    clean = _clean_name(new_name)
    if not clean or clean == old_name:
        return {"ok": False, "message": "Nome inválido."}

    new_dir = root / clean
    if new_dir.exists():
        return {"ok": False, "message": "Já existe um projeto com esse nome."}

    old_dir.rename(new_dir)

    if config.get("active_project") == old_name:
        cfg = dict(config)
        cfg["active_project"] = clean
        save_config(cfg)

    status(f"Projeto renomeado: {old_name} → {clean}")
    return {"ok": True, "name": clean}


def delete_project(name):
    global config
    root = _projects_root()
    project_dir = root / name
    if not project_dir.exists():
        return {"ok": False, "message": "Projeto não encontrado."}

    shutil.rmtree(project_dir)

    if config.get("active_project") == name:
        cfg = dict(config)
        cfg["active_project"] = ""
        save_config(cfg)

    status(f"Projeto excluído: {name}")
    return {"ok": True}


def open_active_project_folder():
    active = get_active_project()
    if not active.get("ok"):
        return {"ok": False, "message": "Nenhum projeto ativo."}
    return _open_path(active["path"])


def open_engine_folder():
    return _open_path(str(ENGINE_DIR))


def _open_path(path):
    try:
        if sys.platform == "win32":
            os.startfile(path)  # noqa: S606
        elif sys.platform == "darwin":
            os.system(f'open "{path}"')
        else:
            os.system(f'xdg-open "{path}"')
        return {"ok": True}
    except Exception as e:
        return {"ok": False, "message": str(e)}


def _download_target_folder(category):
    """Mirrors Get-PastaDownload from the original script: routes into
    the active project's folder structure, or a flat 'Avulso' folder
    beside the engine when there's no active project."""
    active = get_active_project()
    if not active.get("ok"):
        base = BASE / "Avulso" / category
        base.mkdir(parents=True, exist_ok=True)
        return base

    project_dir = Path(active["path"])
    if category == "Outros":
        base = project_dir / "10. Thumbnails"
    else:
        base = project_dir / "02. Arquivos" / category
    base.mkdir(parents=True, exist_ok=True)
    return base


# Flags applied to every yt-dlp call, mirroring what yt-dlp's own team
# currently recommends against the "HTTP Error 403: Forbidden" that hits
# outdated/naive YouTube requests: force it to try multiple internal
# player clients (some don't need the PO token the plain 'web' client
# now requires) and send a real desktop user-agent instead of yt-dlp's
# default one, which YouTube increasingly rate-limits/blocks on sight.
_COMMON_YTDLP_ARGS = [
    # "tv" and "web_embedded" are the two clients YouTube currently does
    # NOT require a PO Token for (see yt-dlp's PO-Token-Guide wiki). The
    # previous list (default/mweb/web_safari/android) all need a PO
    # Token for GVS requests now, which we don't provide, so those
    # formats get silently skipped and yt-dlp falls through to a plain
    # 403. "formats=missing_pot" is a last-resort safety net: it forces
    # yt-dlp to still try formats it would otherwise skip over a missing
    # token, instead of ending in "No video formats found".
    "--extractor-args", "youtube:player_client=tv,web_embedded;formats=missing_pot",
    "--user-agent",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36",
    "--geo-bypass",
    "--no-check-certificates",
    "--retries", "5",
    "--fragment-retries", "5",
]


def _ytdlp_base_cmd():
    cmd = [str(YTDLP_EXE), *_COMMON_YTDLP_ARGS]
    # YouTube now requires solving a small JS "challenge" (signature/n
    # parameter) to get real download URLs; without a JS runtime yt-dlp
    # prints "n challenge solving failed" and a lot of formats silently
    # vanish, which is what was causing "The page needs to be reloaded."
    # We bundle a portable deno.exe in engine/ specifically for this —
    # nothing else needs to be installed on the user's PC.
    deno_exe = ENGINE_DIR / "deno.exe"
    if deno_exe.exists():
        cmd += ["--js-runtimes", f"deno:{deno_exe}"]
    return cmd


# Quality presets per category, mirroring the original PowerShell menus,
# expanded with the extra tiers/formats that were missing vs. the original
# script (720p/1440p video, wav/flac audio, and an "auto" best-effort mode
# for whichever quality/codec combo is actually available for that URL).
_QUALITY_ARGS = {
    "video": {
        "720p": ["-f", "bv*[height<=720]+ba/b", "-S", "vcodec:h264", "--remux-video", "mp4"],
        "1080p": ["-f", "bv*[height<=1080]+ba/b", "-S", "vcodec:h264", "--remux-video", "mp4"],
        "1440p": ["-f", "bv*[height<=1440]+ba/b", "-S", "vcodec:h264", "--remux-video", "mp4"],
        "4k": ["-f", "bestvideo[height<=2160]+bestaudio/best", "--recode-video", "mp4"],
        "best": ["-f", "bestvideo+bestaudio/best", "--remux-video", "mp4"],
        "auto": ["-f", "bv*+ba/b"],
    },
    "audio": {
        "mp3": ["-x", "--audio-format", "mp3", "--audio-quality", "0"],
        "wav": ["-x", "--audio-format", "wav"],
        "flac": ["-x", "--audio-format", "flac"],
        "original": ["-x"],
        "soundcloud": ["--force-overwrites", "--concurrent-fragments", "16",
                        "--http-chunk-size", "10M", "--throttled-rate", "700K",
                        "-x", "--audio-format", "mp3", "--audio-quality", "0"],
        "epidemic": ["-x", "--audio-format", "mp3", "--audio-quality", "0"],
        "direct": ["--force-overwrites", "--concurrent-fragments", "16",
                   "--http-chunk-size", "10M", "--throttled-rate", "700K", "--no-part"],
    },
    "thumbnail": {
        "default": ["--write-thumbnail", "--skip-download"],
    },
    "playlist": {
        "default": ["-f", "bestvideo+bestaudio/best", "--remux-video", "mp4"],
    },
    "site": {
        "video": ["--force-overwrites", "--concurrent-fragments", "16",
                   "--http-chunk-size", "10M", "--throttled-rate", "700K",
                   "-f", "bestvideo+bestaudio/best"],
        "audio": ["--force-overwrites", "--concurrent-fragments", "16",
                   "--http-chunk-size", "10M", "--throttled-rate", "700K",
                   "-x", "--audio-format", "mp3", "--audio-quality", "0"],
    },
}

_CATEGORY_FOLDER = {
    "video": "Videos",
    "audio": "Audios",
    "thumbnail": "Outros",
    "playlist": "Videos",
    "site": "Outros_Sites",
}

_EPIDEMIC_ID_RE = re.compile(
    r"epidemicsound\.com/(?:music/)?(?:sound-effects/tracks|tracks|track)/([0-9a-zA-Z-]+)"
)
_EPIDEMIC_UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)


def _fix_epidemic_url(link):
    """Mirrors the PowerShell script's URL routing: the yt-dlp extractor
    only understands the OLD-style URL, so we pull the ID out of whatever
    format the user pasted and rebuild the URL yt-dlp expects. UUID ids
    (new 'kosmos' catalog) route through /sound-effects/tracks/ even for
    music; short ids (old catalog) route through /track/."""
    match = _EPIDEMIC_ID_RE.search(link)
    if not match:
        return link
    track_id = match.group(1)
    if _EPIDEMIC_UUID_RE.match(track_id):
        return f"https://www.epidemicsound.com/sound-effects/tracks/{track_id}/"
    return f"https://www.epidemicsound.com/track/{track_id}/"


def _direct_file_extension(link):
    match = re.search(r"\.(mp3|wav|m4a|aac|flac|ogg)(\?|$)", link)
    return match.group(1) if match else "mp3"


def list_formats(url):
    """Runs `yt-dlp -F <url>` and returns the raw formats table (mirrors
    the original script's 'Mostrar formatos' option)."""
    if not YTDLP_EXE.exists():
        return {"ok": False, "message": "yt-dlp.exe não encontrado."}
    try:
        import subprocess
        result = subprocess.run(
            [*_ytdlp_base_cmd(), "-F", url.strip()],
            capture_output=True, text=True, encoding="utf-8", errors="replace",
            creationflags=subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0,
            timeout=60
        )
        output = result.stdout or result.stderr
        return {"ok": result.returncode == 0, "output": output}
    except Exception as e:
        return {"ok": False, "message": str(e)}


def list_supported_sites():
    """Runs `yt-dlp --list-extractors` (mirrors 'Ver sites suportados')."""
    if not YTDLP_EXE.exists():
        return {"ok": False, "message": "yt-dlp.exe não encontrado."}
    try:
        import subprocess
        result = subprocess.run(
            [str(YTDLP_EXE), "--list-extractors"],
            capture_output=True, text=True, encoding="utf-8", errors="replace",
            creationflags=subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0,
            timeout=30
        )
        sites = [s.strip() for s in (result.stdout or "").splitlines() if s.strip()]
        return {"ok": True, "sites": sites}
    except Exception as e:
        return {"ok": False, "message": str(e)}


def update_ytdlp():
    if not YTDLP_EXE.exists():
        return {"ok": False, "message": "yt-dlp.exe não encontrado."}
    try:
        import subprocess
        result = subprocess.run(
            [str(YTDLP_EXE), "-U"],
            capture_output=True, text=True, encoding="utf-8", errors="replace",
            creationflags=subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0,
            timeout=120
        )
        output = result.stdout or result.stderr
        status("yt-dlp atualizado.")
        return {"ok": result.returncode == 0, "output": output}
    except Exception as e:
        return {"ok": False, "message": str(e)}


def reset_cookies():
    cookie_file = ENGINE_DIR / "cookies.txt"
    try:
        if cookie_file.exists():
            cookie_file.unlink()
        cfg = dict(config)
        cfg["epidemic_cookie_browser"] = ""
        save_config(cfg)
        status("Cookies resetados.")
        return {"ok": True}
    except Exception as e:
        return {"ok": False, "message": str(e)}


_URL_RE = re.compile(r"^https?://\S+$")


def get_clipboard_url():
    """Checked when the Downloads tab opens: if the clipboard holds
    something that looks like a URL, the UI pre-fills the link field
    with it — saves a Ctrl+V every time."""
    try:
        text = (pyperclip.paste() or "").strip()
    except Exception:
        return {"ok": False}
    if text and _URL_RE.match(text):
        return {"ok": True, "url": text}
    return {"ok": False}


def start_download(url, category, quality, filename=None):
    """Builds the yt-dlp command for this request and enqueues it — the
    actual run happens on the single download-queue worker thread, one
    job at a time, so pasting a second link while one is downloading
    doesn't start two yt-dlp processes fighting for bandwidth."""
    if not YTDLP_EXE.exists():
        return {"ok": False, "message": f"yt-dlp.exe não encontrado em {ENGINE_DIR}. Rode o app a partir da pasta extraída, não de dentro do .zip."}
    if not FFMPEG_EXE.exists():
        return {"ok": False, "message": f"ffmpeg.exe não encontrado em {ENGINE_DIR}."}
    if not url or not url.strip():
        return {"ok": False, "message": "Cole um link primeiro."}

    url = url.strip()
    presets = _QUALITY_ARGS.get(category, {})
    args = list(presets.get(quality) or next(iter(presets.values()), []))

    folder = _download_target_folder(_CATEGORY_FOLDER.get(category, "Outros"))
    fallback_url = None
    fallback_dest = None

    # Special-cased audio qualities that need their own subfolder/URL logic,
    # exactly like the original PowerShell menus did.
    if category == "audio" and quality == "soundcloud":
        folder = folder / "SoundCloud"
        folder.mkdir(exist_ok=True)
        out_pattern = str(folder / "%(playlist_title)s" / "%(title)s.%(ext)s")
        cmd = [*_ytdlp_base_cmd(), *args, "--newline", "-o", out_pattern, url]

    elif category == "audio" and quality == "epidemic":
        folder = folder / "EpidemicSound"
        folder.mkdir(exist_ok=True)
        out_pattern = str(folder / "%(title)s.%(ext)s")
        fixed_url = _fix_epidemic_url(url)
        cookie_file = ENGINE_DIR / "cookies.txt"
        cmd = [*_ytdlp_base_cmd(), *args, "--ffmpeg-location", str(FFMPEG_EXE), "--newline"]
        if cookie_file.exists():
            cmd += ["--cookies", str(cookie_file)]
        cmd += ["-o", out_pattern, fixed_url]

    elif category == "audio" and quality == "direct":
        folder = folder / "Diretos"
        folder.mkdir(exist_ok=True)
        ext = _direct_file_extension(url)
        safe = _clean_name(filename) if filename else "audio"
        dest = folder / f"{safe}.{ext}"
        cmd = [*_ytdlp_base_cmd(), *args, "-o", str(dest), url]
        fallback_url = url
        fallback_dest = str(dest)

    else:
        if category == "playlist":
            out_pattern = str(folder / "%(playlist_title)s" / "%(title)s.%(ext)s")
        elif filename:
            safe = _clean_name(filename)
            out_pattern = str(folder / f"{safe}.%(ext)s")
        else:
            out_pattern = str(folder / "%(title)s.%(ext)s")

        cmd = [*_ytdlp_base_cmd(), *args, "--ffmpeg-location", str(FFMPEG_EXE),
               "--newline", "-o", out_pattern, url]

    job = {
        "id": uuid.uuid4().hex[:10],
        "url": url,
        "category": category,
        "quality": quality,
        "cmd": cmd,
        "folder": folder,
        "fallback_url": fallback_url,
        "fallback_dest": fallback_dest,
    }
    position = _enqueue_download(job)
    return {"ok": True, "folder": str(folder), "queued": position > 0, "position": position}


# ---------------------------------------------------------------------------
# Download queue — a single background thread runs jobs one at a time so
# pasting several links doesn't spawn competing yt-dlp processes.
# ---------------------------------------------------------------------------

_download_queue = []
_download_queue_lock = threading.Lock()
_download_queue_signal = threading.Event()
_current_download_job = None


def _enqueue_download(job):
    """Adds a job to the end of the queue. Returns its 0-based position
    (0 means it'll run next/immediately, since the worker thread is idle)."""
    with _download_queue_lock:
        position = len(_download_queue) + (1 if _current_download_job else 0)
        _download_queue.append(job)
    _download_queue_signal.set()
    _notify_queue_state()
    return position


def cancel_queued_download(job_id):
    """Removes a job that hasn't started yet. Can't cancel the one
    currently downloading (that's what the progress bar's own stop would
    be for, which yt-dlp doesn't support cleanly mid-transfer)."""
    with _download_queue_lock:
        before = len(_download_queue)
        _download_queue[:] = [j for j in _download_queue if j["id"] != job_id]
        removed = len(_download_queue) != before
    if removed:
        _notify_queue_state()
    return {"ok": removed}


def get_download_queue():
    with _download_queue_lock:
        pending = [_job_summary(j) for j in _download_queue]
    current = _job_summary(_current_download_job) if _current_download_job else None
    return {"ok": True, "current": current, "pending": pending}


def _job_summary(job):
    return {"id": job["id"], "url": job["url"], "category": job["category"], "quality": job["quality"]}


def _notify_queue_state():
    if not window:
        return
    state = get_download_queue()
    payload = json.dumps(state)
    try:
        window.evaluate_js(f"window.onQueueUpdate && window.onQueueUpdate({payload})")
    except Exception:
        pass


def _download_queue_worker():
    global _current_download_job
    while True:
        job = None
        with _download_queue_lock:
            if _download_queue:
                job = _download_queue.pop(0)
        if job is None:
            _download_queue_signal.wait(timeout=1)
            _download_queue_signal.clear()
            continue

        _current_download_job = job
        _notify_queue_state()
        try:
            _run_download_sync(job["cmd"], job["folder"], job["fallback_url"], job["fallback_dest"], url=job["url"])
        except Exception as e:
            _notify_progress(100, f"Erro inesperado: {e}", done=True, ok=False, url=job["url"])
        _current_download_job = None
        _notify_queue_state()


def _run_download_sync(cmd, folder, fallback_url=None, fallback_dest=None, retry_after_update=True, url=None):
    """Runs one yt-dlp job to completion, streaming progress to the UI.
    Blocking on purpose — called from the single download-queue worker
    thread, never directly from the pywebview/Api thread. `url` here is
    just the original link, threaded through so the UI can show which
    job actually finished (the visible input field may have moved on to
    a different queued link by the time this one completes)."""
    log_path = BASE / "downloads_log.txt"

    _notify_progress(0, "Iniciando...", url=url)
    full_output = []

    try:
        proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, encoding="utf-8", errors="replace",
            creationflags=subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0
        )
    except FileNotFoundError:
        msg = ("Não foi possível executar o yt-dlp.exe. O Windows/antivírus pode ter "
               "bloqueado o arquivo (comum após extrair de um .zip). Vá em Configurações do "
               "Windows Defender > Exclusões e adicione a pasta 'engine' do AutoTyper.")
        _notify_progress(100, msg, done=True, ok=False, url=url)
        return
    except PermissionError:
        msg = ("O sistema negou permissão para rodar o yt-dlp.exe — provavelmente foi "
               "colocado em quarentena pelo antivírus. Restaure o arquivo e adicione a "
               "pasta 'engine' às exclusões.")
        _notify_progress(100, msg, done=True, ok=False, url=url)
        return
    except Exception as e:
        _notify_progress(100, f"Erro ao iniciar: {e}", done=True, ok=False, url=url)
        return

    last_line = ""
    try:
        for line in proc.stdout:
            clean = line.strip()
            if clean:
                last_line = clean
                full_output.append(clean)
            match = re.search(r"(\d{1,3}\.\d)%", line)
            if match:
                _notify_progress(float(match.group(1)), last_line, url=url)
        proc.wait()
    except Exception as e:
        full_output.append(f"[exceção ao ler saída: {e}]")

    try:
        log_path.write_text(
            f"$ {' '.join(cmd)}\n\n" + "\n".join(full_output),
            encoding="utf-8"
        )
    except Exception:
        pass

    if proc.returncode == 0:
        _notify_progress(100, "Concluído!", done=True, ok=True, url=url)
        status(f"Download concluído: {folder.name}")
        return

    # HTTP 403/Forbidden almost always means the bundled yt-dlp.exe is
    # a version or two behind and YouTube (or the target site) changed
    # something it relies on. One silent self-update + a single retry
    # fixes the vast majority of these without the user having to know
    # what yt-dlp even is.
    joined_output = "\n".join(full_output)
    looks_like_403 = "403" in joined_output or "forbidden" in joined_output.lower()
    if looks_like_403 and retry_after_update:
        _notify_progress(10, "Erro 403 detectado — atualizando o motor de download e tentando de novo...", url=url)
        try:
            subprocess.run(
                [str(YTDLP_EXE), "-U"], capture_output=True, timeout=120,
                creationflags=subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0
            )
        except Exception:
            pass
        _run_download_sync(cmd, folder, fallback_url, fallback_dest, retry_after_update=False, url=url)
        return

    # yt-dlp failed outright — if this was a raw/CDN link, fall back
    # to a plain HTTP download, same safety net as the original script.
    if fallback_url and fallback_dest:
        _notify_progress(50, "yt-dlp falhou, tentando download direto (modo reserva)...", url=url)
        try:
            import urllib.request
            dest = Path(fallback_dest)
            req = urllib.request.Request(fallback_url, headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=30) as resp, open(dest, "wb") as f:
                total = int(resp.headers.get("Content-Length", 0) or 0)
                downloaded = 0
                chunk = resp.read(65536)
                while chunk:
                    f.write(chunk)
                    downloaded += len(chunk)
                    if total:
                        _notify_progress(round(downloaded / total * 100, 1), f"{downloaded // 1024} KB", url=url)
                    chunk = resp.read(65536)
            _notify_progress(100, "Concluído (modo reserva)!", done=True, ok=True, url=url)
            status(f"Download concluído (reserva): {folder.name}")
            return
        except Exception as e:
            error_summary = f"Modo reserva também falhou: {e}"
            _notify_progress(100, error_summary, done=True, ok=False, url=url)
            status("Erro no download.")
            return

    error_summary = last_line or f"yt-dlp saiu com código {proc.returncode}."
    _notify_progress(100, error_summary, done=True, ok=False, url=url)
    status("Erro no download.")


def open_downloads_log():
    log_path = BASE / "downloads_log.txt"
    if not log_path.exists():
        return {"ok": False, "message": "Nenhum log ainda — tente um download primeiro."}
    return _open_path(str(log_path))


def open_crash_log():
    log_path = BASE / "crash_log.txt"
    if not log_path.exists():
        return {"ok": False, "message": "Nenhum erro registrado ainda — boa notícia."}
    return _open_path(str(log_path))


def _notify_progress(percent, message, done=False, ok=True, url=None):
    if not window:
        return
    payload = json.dumps({"percent": percent, "message": message, "done": done, "ok": ok, "url": url})
    try:
        window.evaluate_js(f"window.onDownloadProgress && window.onDownloadProgress({payload})")
    except Exception:
        pass


def capture_epidemic_login():
    """Opens a real browser window (via the bundled Playwright script) so
    the user can log in to Epidemic Sound; cookies get saved for yt-dlp
    to reuse on subsequent downloads. Requires Python to be available
    (falls back gracefully in a frozen build without one)."""
    if not COOKIE_SCRIPT.exists():
        return {"ok": False, "message": "capturar_cookies.py não encontrado em engine/."}

    python_exe = None
    for candidate in ("python", "python3"):
        from shutil import which
        if which(candidate):
            python_exe = candidate
            break
    if not python_exe:
        return {"ok": False, "message": "Python não encontrado no sistema (necessário para o login automático)."}

    def worker():
        import subprocess
        try:
            proc = subprocess.Popen(
                [python_exe, str(COOKIE_SCRIPT)],
                cwd=str(ENGINE_DIR)
            )
            proc.wait()
            cookie_file = ENGINE_DIR / "cookies.txt"
            if cookie_file.exists():
                status("Login do Epidemic Sound salvo — pode baixar normalmente.")
                if window:
                    try:
                        window.evaluate_js("window.onEpidemicLoginDone && window.onEpidemicLoginDone(true)")
                    except Exception:
                        pass
            else:
                if window:
                    try:
                        window.evaluate_js("window.onEpidemicLoginDone && window.onEpidemicLoginDone(false)")
                    except Exception:
                        pass
        except Exception:
            pass

    try:
        threading.Thread(target=worker, daemon=True).start()
        return {"ok": True}
    except Exception as e:
        return {"ok": False, "message": str(e)}


def _classify_file(path: Path):
    ext = path.suffix.lower()
    for kind, exts in MEDIA_EXTENSIONS.items():
        if ext in exts:
            return kind
    return "other"


def browse_media(subpath=""):
    """Lists folders/files under the active project (or its Avulso
    equivalent) so the front-end can render a folder tree + file list
    for the built-in media player."""
    active = get_active_project()
    base = Path(active["path"]) if active.get("ok") else (BASE / "Avulso")
    base.mkdir(parents=True, exist_ok=True)

    target = (base / subpath).resolve() if subpath else base
    try:
        target.relative_to(base.resolve())
    except ValueError:
        return {"ok": False, "message": "Caminho inválido."}

    if not target.exists():
        return {"ok": False, "message": "Pasta não encontrada."}

    folders, files = [], []
    for item in sorted(target.iterdir(), key=lambda p: p.name.lower()):
        if item.name.startswith("."):
            continue
        rel = str(item.relative_to(base))
        if item.is_dir():
            folders.append({"name": item.name, "path": rel})
        else:
            files.append({
                "name": item.name,
                "path": rel,
                "full_path": str(item),
                "kind": _classify_file(item),
                "size_kb": round(item.stat().st_size / 1024, 1)
            })

    crumbs = str(target.relative_to(base)) if target != base else ""
    return {"ok": True, "base": str(base), "subpath": crumbs, "folders": folders, "files": files}


import http.server
import socketserver
import mimetypes
import uuid

_media_tokens = {}
_media_server_port = None
_media_server_lock = threading.Lock()


class _RangeHTTPHandler(http.server.BaseHTTPRequestHandler):
    """Minimal local file server with HTTP Range support, so <video>/<audio>
    tags can stream and seek project media smoothly. Every path segment is
    an opaque per-session token mapped to an absolute file path — nothing
    is ever served by raw filesystem path, and only 127.0.0.1 can reach it."""

    def log_message(self, *_args):
        pass

    def do_GET(self):
        token = self.path.lstrip("/").split("?")[0]
        path = _media_tokens.get(token)
        if not path or not os.path.isfile(path):
            self.send_error(404, "Arquivo não encontrado")
            return

        fsize = os.path.getsize(path)
        ctype = mimetypes.guess_type(path)[0] or "application/octet-stream"
        start, end = 0, fsize - 1
        status_code = 200

        range_header = self.headers.get("Range")
        if range_header:
            m = re.match(r"bytes=(\d*)-(\d*)", range_header)
            if m:
                if m.group(1):
                    start = int(m.group(1))
                if m.group(2):
                    end = int(m.group(2))
                status_code = 206

        length = max(0, end - start + 1)
        try:
            self.send_response(status_code)
            self.send_header("Content-Type", ctype)
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(length))
            if status_code == 206:
                self.send_header("Content-Range", f"bytes {start}-{end}/{fsize}")
            self.end_headers()
            with open(path, "rb") as f:
                f.seek(start)
                remaining = length
                while remaining > 0:
                    chunk = f.read(min(65536, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
        except (BrokenPipeError, ConnectionAbortedError, ConnectionResetError):
            pass


def _ensure_media_server():
    global _media_server_port
    with _media_server_lock:
        if _media_server_port is not None:
            return
        srv = socketserver.ThreadingTCPServer(("127.0.0.1", 0), _RangeHTTPHandler)
        srv.daemon_threads = True
        _media_server_port = srv.server_address[1]
        threading.Thread(target=srv.serve_forever, daemon=True).start()


def get_file_url(path):
    """Registers the file under a one-time token and returns a local
    http://127.0.0.1 URL for it. Replaces the old file:// URI, which
    WebView2 silently refuses to load into <video>/<audio> elements —
    that silent failure was the actual cause of the player 'not working'."""
    try:
        p = Path(path).resolve()
        if not p.is_file():
            return {"ok": False, "message": "Arquivo não encontrado."}
        _ensure_media_server()
        token = uuid.uuid4().hex
        _media_tokens[token] = str(p)
        return {"ok": True, "url": f"http://127.0.0.1:{_media_server_port}/{token}"}
    except Exception as e:
        return {"ok": False, "message": str(e)}


def launch_farejador():
    farejador = ENGINE_DIR / "farejador_universal.py"
    if not farejador.exists():
        return {"ok": False, "message": "farejador_universal.py não encontrado em engine/."}

    python_exe = None
    for candidate in ("python", "python3"):
        from shutil import which
        if which(candidate):
            python_exe = candidate
            break
    if not python_exe:
        return {"ok": False, "message": "Python não encontrado no sistema (necessário para essa ferramenta)."}

    active = get_active_project()
    base = Path(active["path"]) if active.get("ok") else (BASE / "Avulso")
    dest = base / "02. Arquivos" / "Audios" / "Diretos" if active.get("ok") else base / "Audios" / "Diretos"
    dest.mkdir(parents=True, exist_ok=True)

    try:
        import subprocess
        subprocess.Popen(
            [python_exe, str(farejador), str(dest)],
            cwd=str(ENGINE_DIR)
        )
        return {"ok": True, "folder": str(dest)}
    except Exception as e:
        return {"ok": False, "message": str(e)}


def _premiere_profile_dir():
    """Finds the newest Premiere Pro profile folder under
    Documents\\Adobe\\Premiere Pro\\<version>\\Profile-*, mirroring
    Encontrar-PerfilPremiere from the original script."""
    docs = Path.home() / "Documents" / "Adobe" / "Premiere Pro"
    if not docs.exists():
        return None
    candidates = []
    for version_dir in docs.iterdir():
        if not version_dir.is_dir():
            continue
        for profile_dir in version_dir.glob("Profile-*"):
            if profile_dir.is_dir():
                candidates.append(profile_dir)
    if not candidates:
        return None
    return max(candidates, key=lambda p: p.stat().st_mtime)


def _premiere_backup_dirs():
    backup_root = ENGINE_DIR / "Modelo" / "Premiere"
    shortcuts = backup_root / "Shortcuts"
    workspaces = backup_root / "Workspaces"
    shortcuts.mkdir(parents=True, exist_ok=True)
    workspaces.mkdir(parents=True, exist_ok=True)
    return shortcuts, workspaces


def backup_premiere_config():
    profile = _premiere_profile_dir()
    if not profile:
        return {"ok": False, "message": "Não achei a pasta de perfil do Premiere em Documentos\\Adobe\\Premiere Pro. Abra o Premiere pelo menos uma vez e tente de novo."}

    shortcuts_dst, workspaces_dst = _premiere_backup_dirs()
    shortcuts_src = profile / "Win"
    workspaces_src = profile / "Layouts"

    total_shortcuts = 0
    if shortcuts_src.exists():
        for f in shortcuts_src.glob("*.kys"):
            import shutil
            shutil.copy2(f, shortcuts_dst)
            total_shortcuts += 1

    total_workspaces = 0
    if workspaces_src.exists():
        for f in workspaces_src.glob("*.xml"):
            import shutil
            shutil.copy2(f, workspaces_dst)
            total_workspaces += 1

    status(f"Backup do Premiere: {total_shortcuts} atalho(s) + {total_workspaces} workspace(s).")
    return {"ok": True, "shortcuts": total_shortcuts, "workspaces": total_workspaces}


def restore_premiere_config():
    shortcuts_dir, workspaces_dir = _premiere_backup_dirs()
    shortcuts = list(shortcuts_dir.glob("*.kys"))
    workspaces = list(workspaces_dir.glob("*.xml"))
    if not shortcuts and not workspaces:
        return {"ok": False, "message": "Ainda não tem backup salvo. Rode 'Backup do Premiere' primeiro numa máquina já configurada."}

    profile = _premiere_profile_dir()
    if not profile:
        return {"ok": False, "message": "Não achei a pasta de perfil do Premiere. Abra o Premiere pelo menos uma vez e tente de novo."}

    dst_shortcuts = profile / "Win"
    dst_workspaces = profile / "Layouts"
    dst_shortcuts.mkdir(parents=True, exist_ok=True)
    dst_workspaces.mkdir(parents=True, exist_ok=True)

    import shutil
    for f in shortcuts:
        shutil.copy2(f, dst_shortcuts)
    for f in workspaces:
        shutil.copy2(f, dst_workspaces)

    status(f"Restaurado: {len(shortcuts)} atalho(s) + {len(workspaces)} workspace(s).")
    return {"ok": True, "shortcuts": len(shortcuts), "workspaces": len(workspaces)}


def _write_crash_log(exc_type, exc_value, exc_tb, thread_name="MainThread"):
    """Last-resort safety net: any exception that isn't caught anywhere
    else (main thread or a background thread) gets written here instead
    of just vanishing into a console window nobody sees, since this is a
    --windowed build with no visible stdout."""
    import traceback
    try:
        crash_log = BASE / "crash_log.txt"
        entry = (
            f"\n{'=' * 60}\n"
            f"{datetime.now().isoformat()} — thread: {thread_name}\n"
            f"{'=' * 60}\n"
        )
        entry += "".join(traceback.format_exception(exc_type, exc_value, exc_tb))
        with open(crash_log, "a", encoding="utf-8") as f:
            f.write(entry)
    except Exception:
        pass


def _install_crash_logging():
    def _main_thread_hook(exc_type, exc_value, exc_tb):
        _write_crash_log(exc_type, exc_value, exc_tb, "MainThread")
        sys.__excepthook__(exc_type, exc_value, exc_tb)

    sys.excepthook = _main_thread_hook

    if hasattr(threading, "excepthook"):
        def _thread_hook(args):
            _write_crash_log(args.exc_type, args.exc_value, args.exc_traceback,
                              args.thread.name if args.thread else "unknown")
        threading.excepthook = _thread_hook


if __name__ == "__main__":
    if not _acquire_single_instance():
        # Another instance is already running; it'll pick up the flag
        # file we just dropped and show itself. Don't spawn a second
        # window/tray icon on top of it.
        sys.exit(0)

    _install_crash_logging()
    api = Api()
    window = webview.create_window(
        "AutoTyper",
        str(RES / "index.html"),
        js_api=api,
        width=1280,
        height=800,
        min_size=(1000, 650),
        background_color="#1a1a1a",
        hidden=config.get("start_hidden", False)
    )

    def on_closing():
        # Instead of exiting, minimize to tray like ReduceMemory does,
        # as long as the tray icon is actually running.
        if config.get("minimize_to_tray", True) and tray_icon is not None:
            window.hide()
            return False  # cancel the close
        return True

    window.events.closing += on_closing

    start_tray()
    threading.Thread(target=_show_request_watcher, daemon=True).start()
    threading.Thread(target=_auto_memory_loop, daemon=True).start()
    threading.Thread(target=_download_queue_worker, daemon=True).start()
    webview.start(on_loaded, debug=False)
