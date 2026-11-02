"""SysGraph for Windows: a compact always-on-top graph of CPU, GPU, NPU, VRAM and memory.

Port of SysGraph.swift. Standard library only (tkinter + ctypes); GPU data comes
from nvidia-smi, which ships with the NVIDIA driver.

Run:       pyw SysGraph.py        (no console window)
       or  python SysGraph.py

Drag the window to move it, drag any edge or corner to resize it,
right-click for the menu (Quit). Position and size are saved per screen size.
"""

import ctypes
import ctypes.wintypes as wt
import json
import os
import shutil
import subprocess
import sys
import threading
import tkinter as tk

HISTORY = 120  # 2 minutes of 1-second samples
INTERVAL_MS = 1000

COLORS = {
    "CPU": "#33ff66",
    "GPU": "#00e5ff",
    "VRM": "#ff33e6",
    "MEM": "#ff9500",
    "NPU": "#ffd60a",
}
BG = "#141414"
GRID = "#2a2a2a"

# Fills drawn as solid colours blended with the background (tkinter has no alpha).
def _blend(hex_color, alpha, bg=BG):
    c = [int(hex_color[i:i + 2], 16) for i in (1, 3, 5)]
    b = [int(bg[i:i + 2], 16) for i in (1, 3, 5)]
    return "#" + "".join(f"{round(b[k] + (c[k] - b[k]) * alpha):02x}" for k in range(3))

VRM_FILL = _blend(COLORS["VRM"], 0.30)
MEM_FILL = _blend(COLORS["MEM"], 0.22)
OVERLAP_FILL = _blend(COLORS["MEM"], 0.22, VRM_FILL)

STATE_FILE = os.path.join(os.environ.get("APPDATA", os.path.expanduser("~")), "SysGraph", "window.json")


# ── Data collection ─────────────────────────────────────────────────────────

class FILETIME(ctypes.Structure):
    _fields_ = [("lo", wt.DWORD), ("hi", wt.DWORD)]

    def value(self):
        return (self.hi << 32) | self.lo


class MEMORYSTATUSEX(ctypes.Structure):
    _fields_ = [
        ("dwLength", wt.DWORD),
        ("dwMemoryLoad", wt.DWORD),
        ("ullTotalPhys", ctypes.c_ulonglong),
        ("ullAvailPhys", ctypes.c_ulonglong),
        ("ullTotalPageFile", ctypes.c_ulonglong),
        ("ullAvailPageFile", ctypes.c_ulonglong),
        ("ullTotalVirtual", ctypes.c_ulonglong),
        ("ullAvailVirtual", ctypes.c_ulonglong),
        ("ullAvailExtendedVirtual", ctypes.c_ulonglong),
    ]


kernel32 = ctypes.windll.kernel32


class CpuSampler:
    """Delta-based CPU %, from GetSystemTimes (kernel time includes idle)."""

    def __init__(self):
        self.prev = self._read()

    @staticmethod
    def _read():
        idle, kern, user = FILETIME(), FILETIME(), FILETIME()
        kernel32.GetSystemTimes(ctypes.byref(idle), ctypes.byref(kern), ctypes.byref(user))
        return idle.value(), kern.value(), user.value()

    def sample(self):
        cur = self._read()
        d_idle, d_kern, d_user = (c - p for c, p in zip(cur, self.prev))
        self.prev = cur
        total = d_kern + d_user
        if total <= 0:
            return 0.0
        return max(0.0, min(100.0, (total - d_idle) / total * 100))


def memory_percent():
    """Physical memory in use (total - available) as % of total, as Task Manager shows."""
    m = MEMORYSTATUSEX()
    m.dwLength = ctypes.sizeof(MEMORYSTATUSEX)
    if not kernel32.GlobalMemoryStatusEx(ctypes.byref(m)) or m.ullTotalPhys == 0:
        return 0.0
    return (m.ullTotalPhys - m.ullAvailPhys) / m.ullTotalPhys * 100


class GpuSampler:
    """Streams nvidia-smi once per second in a background thread.

    The GPU is the first device that reports a memory total. A device whose name
    contains "NPU" (RTX Spark laptops list one) supplies NPU utilization.
    """

    def __init__(self):
        self.util = 0.0
        self.vram = 0.0
        self.npu = 0.0
        self.has_npu = False
        self.name = None
        self.available = shutil.which("nvidia-smi") is not None
        self.proc = None
        if self.available:
            threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        cmd = [
            "nvidia-smi",
            "--query-gpu=index,name,utilization.gpu,memory.used,memory.total",
            "--format=csv,noheader,nounits",
            "-lms", str(INTERVAL_MS),
        ]
        try:
            self.proc = subprocess.Popen(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
        except OSError:
            self.available = False
            return
        for line in self.proc.stdout:
            parts = [p.strip() for p in line.split(",")]
            if len(parts) < 5:
                continue
            if "NPU" in parts[1].upper():
                try:
                    self.npu = max(0.0, min(100.0, float(parts[2])))
                    self.has_npu = True
                except ValueError:
                    pass
                continue
            try:
                util = float(parts[2])
                used = float(parts[3])
                total = float(parts[4])
            except ValueError:
                continue  # "[N/A]" fields, e.g. the NPU
            if total <= 0:
                continue
            if self.name is None:
                self.name = parts[1]
            elif parts[1] != self.name:
                continue
            self.util = max(0.0, min(100.0, util))
            self.vram = max(0.0, min(100.0, used / total * 100))
        self.available = False

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()


# ── Window ──────────────────────────────────────────────────────────────────

def load_state():
    try:
        with open(STATE_FILE, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_state(state):
    try:
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        with open(STATE_FILE, "w", encoding="utf-8") as f:
            json.dump(state, f)
    except OSError:
        pass


class SysGraph:
    def __init__(self):
        try:
            ctypes.windll.shcore.SetProcessDpiAwareness(1)
        except (AttributeError, OSError):
            pass

        self.root = tk.Tk()
        self.root.title("SysGraph")
        self.root.overrideredirect(True)
        self.root.attributes("-topmost", True)
        self.root.configure(bg=BG)

        self.scale = self.root.winfo_fpixels("1i") / 96.0
        self.screen_key = f"{self.root.winfo_screenwidth()}x{self.root.winfo_screenheight()}"
        w, h = int(300 * self.scale), int(80 * self.scale)
        geom = load_state().get(self.screen_key)
        if not geom:
            sw, sh = self.root.winfo_screenwidth(), self.root.winfo_screenheight()
            geom = f"{w}x{h}+{(sw - w) // 2}+{sh - h - int(60 * self.scale)}"
        self.root.geometry(geom)

        self.canvas = tk.Canvas(self.root, bg=BG, highlightthickness=0, cursor="fleur")
        self.canvas.pack(fill="both", expand=True)

        self.cpu = CpuSampler()
        self.gpu = GpuSampler()
        self.series = {k: [0.0] * HISTORY for k in COLORS}

        self.menu = tk.Menu(self.root, tearoff=0)
        self.menu.add_command(label="Quit", command=self.quit)

        self.canvas.bind("<Motion>", self._hover)
        self.canvas.bind("<ButtonPress-1>", self._press)
        self.canvas.bind("<B1-Motion>", self._drag)
        self.canvas.bind("<ButtonRelease-1>", lambda e: self._save())
        self.canvas.bind("<Button-3>", lambda e: self.menu.tk_popup(e.x_root, e.y_root))
        self.canvas.bind("<Configure>", lambda e: self.draw())
        self.root.bind("<Escape>", lambda e: self.quit())
        self.root.protocol("WM_DELETE_WINDOW", self.quit)

        self.tick()

    # Resize by dragging any edge or corner; move by dragging anywhere else.
    CURSORS = {"n": "size_ns", "s": "size_ns", "w": "size_we", "e": "size_we",
               "nw": "size_nw_se", "se": "size_nw_se", "ne": "size_ne_sw", "sw": "size_ne_sw"}

    def _edge(self, e):
        m = max(6, int(8 * self.scale))
        w, h = self.canvas.winfo_width(), self.canvas.winfo_height()
        return ("n" if e.y < m else "s" if e.y >= h - m else "") + \
               ("w" if e.x < m else "e" if e.x >= w - m else "")

    def _hover(self, e):
        self.canvas.configure(cursor=self.CURSORS.get(self._edge(e), "fleur"))

    def _press(self, e):
        self.edge = self._edge(e)
        self.start = (e.x_root, e.y_root, self.root.winfo_x(), self.root.winfo_y(),
                      self.root.winfo_width(), self.root.winfo_height())

    def _drag(self, e):
        x0, y0, wx, wy, ww, wh = self.start
        dx, dy = e.x_root - x0, e.y_root - y0
        if not self.edge:
            self.root.geometry(f"+{wx + dx}+{wy + dy}")
            return
        min_w, min_h = int(120 * self.scale), int(40 * self.scale)
        x, y, w, h = wx, wy, ww, wh
        if "e" in self.edge:
            w = max(min_w, ww + dx)
        if "w" in self.edge:
            w = max(min_w, ww - dx)
            x = wx + ww - w
        if "s" in self.edge:
            h = max(min_h, wh + dy)
        if "n" in self.edge:
            h = max(min_h, wh - dy)
            y = wy + wh - h
        self.root.geometry(f"{w}x{h}+{x}+{y}")

    def _save(self):
        state = load_state()
        state[self.screen_key] = self.root.geometry()
        save_state(state)

    def quit(self):
        self._save()
        self.gpu.stop()
        self.root.destroy()

    def tick(self):
        latest = {
            "CPU": self.cpu.sample(),
            "GPU": self.gpu.util,
            "VRM": self.gpu.vram,
            "MEM": memory_percent(),
            "NPU": self.gpu.npu,
        }
        for k, v in latest.items():
            s = self.series[k]
            s.append(v)
            del s[0]
        self.latest = latest
        self.draw()
        self.root.after(INTERVAL_MS, self.tick)

    def _points(self, values, w, h):
        n = len(values)
        step = w / (n - 1)
        pts = []
        for i, v in enumerate(values):
            pts += [i * step, h - v / 100 * h]
        return pts

    def draw(self):
        c = self.canvas
        c.delete("all")
        w, h = c.winfo_width(), c.winfo_height()
        if w < 2 or h < 2 or not hasattr(self, "latest"):
            return

        for pct in (25, 50, 75):
            y = h - pct / 100 * h
            c.create_line(0, y, w, y, fill=GRID, dash=(3, 3))

        # VRAM and system RAM are separate pools on Windows (dedicated VRAM on a
        # discrete card; the GPU carveout on RTX Spark), so they are drawn as two
        # overlapping fills from zero rather than stacked as on the Mac.
        vrm, mem = self.series["VRM"], self.series["MEM"]
        overlap = [min(a, b) for a, b in zip(vrm, mem)]
        for values, fill in ((mem, MEM_FILL), (vrm, VRM_FILL), (overlap, OVERLAP_FILL)):
            c.create_polygon(self._points(values, w, h) + [w, h, 0, h], fill=fill, outline="")

        lw = max(1, round(1.5 * self.scale))
        c.create_line(self._points(vrm, w, h), fill=COLORS["VRM"], width=max(1, round(self.scale)))
        c.create_line(self._points(mem, w, h), fill=COLORS["MEM"], width=lw)
        if self.gpu.has_npu:
            c.create_line(self._points(self.series["NPU"], w, h), fill=COLORS["NPU"], width=lw)
        c.create_line(self._points(self.series["GPU"], w, h), fill=COLORS["GPU"], width=lw)
        c.create_line(self._points(self.series["CPU"], w, h), fill=COLORS["CPU"], width=lw)

        font = ("Consolas", 7, "bold")
        x = int(6 * self.scale)
        y = int(4 * self.scale)
        keys = ("CPU", "GPU", "NPU", "VRM", "MEM") if self.gpu.has_npu else ("CPU", "GPU", "VRM", "MEM")
        for k in keys:
            text = f"{k} n/a" if k in ("GPU", "VRM") and not self.gpu.available else f"{k} {round(self.latest[k])}%"
            c.create_rectangle(x, y + 5 * self.scale, x + 8 * self.scale, y + 7 * self.scale,
                               fill=COLORS[k], outline="")
            t = c.create_text(x + 11 * self.scale, y, text=text, anchor="nw", fill=COLORS[k], font=font)
            x = c.bbox(t)[2] + int(8 * self.scale)

        g = int(8 * self.scale)
        c.create_line(w - g, h - 2, w - 2, h - g, fill="#555555")
        c.create_line(w - g // 2, h - 2, w - 2, h - g // 2, fill="#555555")

    def run(self):
        self.root.mainloop()


if __name__ == "__main__":
    if sys.platform != "win32":
        sys.exit("This version is for Windows. On macOS use SysGraph.swift.")
    SysGraph().run()
