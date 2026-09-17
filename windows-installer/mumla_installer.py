#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Mumla POC Installer — a Windows GUI (Tkinter) that provisions the S12 Mumla
build onto a Hytera PNC380 POC radio over adb.

This is a faithful, cross-platform Python port of setup-device.sh:
  1. (optional) remove stock upstream Mumla, then clean-install the S12 APK,
  2. generate a client certificate (creates the app DB),
  3. add the Mumble server to favourites (username = the radio number),
  4. set push-to-talk (F12), hide the on-screen button, mic volume, handset
     mode, mic source, etc.,
  5. turn off the device lock screen (Screen lock = None),
  6. enable the background-PTT accessibility service + battery whitelist,
  7. neutralize rival PTT apps (com.pocxin.ptt, com.hytalkpro.ocean).

adb is bundled next to the .exe (PyInstaller). The APK is looked up next to
the .exe (mumla-foss-debug.apk) or chosen with "Browse". sqlite3 is built into
Python, so no external binary is needed to read/edit the app database.
"""

import os
import sys
import queue
import shutil
import sqlite3
import tempfile
import threading
import subprocess

import tkinter as tk
from tkinter import ttk, filedialog, scrolledtext

# --- constants (mirror setup-device.sh) -----------------------------------
PKG = "se.lublin.mumla.s12"
STOCK_MUMLA = "se.lublin.mumla"
RIVAL_PTT = ["com.pocxin.ptt", "com.hytalkpro.ocean"]
DB = "databases/mumble.db"
PREFS = f"shared_prefs/{PKG}_preferences.xml"
GEN_ACT = f"{PKG}/se.lublin.mumla.preference.CertificateGenerateActivity"
A11Y_SVC = f"{PKG}/se.lublin.mumla.service.MumlaPTTAccessibilityService"

MIC_SOURCES = [
    ("voice_comm", "ไมค์สื่อสาร (ลดเสียงรบกวน)"),
    ("auto", "อัตโนมัติ (ตามโหมดโทรศัพท์)"),
    ("mic", "ไมค์หลัก (วิทยุสื่อสาร)"),
    ("camcorder", "ไมค์กล้องวิดีโอ"),
    ("voice_recognition", "ไมค์สั่งงานด้วยเสียง"),
]

DEFAULTS = dict(
    server_name="174.138.20.49",
    server_host="174.138.20.49",
    server_port="64738",
    username="",
    password="",
    ptt_keycode="142",
    mic_volume="100",
    mic_source="voice_comm",
    handset_mode=True,
    force_speaker=True,
    hide_ptt=True,
    auto_connect_on_boot=False,
    disable_screen_lock=True,
    enable_bg_ptt=True,
    clean_reinstall=True,
    remove_stock_mumla=True,
    neutralize_rival_ptt=True,
    disable_rival_ptt=False,
)


# --- adb plumbing ----------------------------------------------------------
def _no_window_kwargs():
    """Keep adb subprocesses from flashing a console window on Windows."""
    if os.name == "nt":
        si = subprocess.STARTUPINFO()
        si.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        return dict(startupinfo=si, creationflags=subprocess.CREATE_NO_WINDOW)
    return {}


def resource_path(name):
    """Resolve a bundled file both in dev and inside a PyInstaller onefile."""
    base = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(base, name)


def find_adb():
    """Prefer a bundled adb(.exe); fall back to one on PATH."""
    name = "adb.exe" if os.name == "nt" else "adb"
    bundled = resource_path(name)
    if os.path.isfile(bundled):
        return bundled
    found = shutil.which("adb")
    if found:
        return found
    # last resort: next to the executable itself
    exe_dir = os.path.dirname(sys.executable if getattr(sys, "frozen", False) else __file__)
    cand = os.path.join(exe_dir, name)
    return cand if os.path.isfile(cand) else name


def find_default_apk():
    """Look for the APK next to the exe / script, then bundled."""
    name = "mumla-foss-debug.apk"
    exe_dir = os.path.dirname(sys.executable if getattr(sys, "frozen", False) else __file__)
    for cand in (os.path.join(exe_dir, name), resource_path(name)):
        if os.path.isfile(cand):
            return cand
    return ""


class Adb:
    def __init__(self, adb_path, serial=None):
        self.adb = adb_path
        self.serial = serial

    def _base(self):
        cmd = [self.adb]
        if self.serial:
            cmd += ["-s", self.serial]
        return cmd

    def run(self, *args, binary=False, timeout=120):
        """Run an adb command, returning (rc, out). out is bytes if binary."""
        proc = subprocess.run(
            self._base() + list(args),
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            timeout=timeout, **_no_window_kwargs(),
        )
        out = proc.stdout if binary else proc.stdout.decode("utf-8", "replace")
        return proc.returncode, out

    # --- higher-level helpers (mirror the shell functions) ---
    def devices(self):
        rc, out = self.run("devices")
        result = []
        for line in out.splitlines()[1:]:
            parts = line.split()
            if len(parts) >= 2 and parts[1] == "device":
                result.append(parts[0])
        return result

    def pull_appfile(self, path, binary=False):
        """adb exec-out run-as PKG cat <path> — read a file from the app dir."""
        rc, out = self.run("exec-out", "run-as", PKG, "cat", path, binary=True)
        if rc != 0:
            return None
        return out if binary else out.decode("utf-8", "replace")

    def have(self, path):
        rc, _ = self.run("shell", "run-as", PKG, "ls", path)
        return rc == 0

    def push_appfile(self, local, dest):
        """Push a local file into the app's private dir via a tmp hop."""
        tmp = "/data/local/tmp/.mumla_push"
        self.run("push", local, tmp)
        self.run("shell", "chmod", "644", tmp)
        rc, _ = self.run("shell", "run-as", PKG, "cp", tmp, dest)
        if rc != 0:
            # fallback: dd from the tmp file
            self.run("shell", "run-as", PKG, "sh", "-c", f"dd if={tmp} of={dest}")
        self.run("shell", "rm", "-f", tmp)

    def stop_app(self):
        self.run("shell", "am", "force-stop", PKG)
        for _ in range(15):
            rc, out = self.run("shell", "pidof", PKG)
            if not out.strip():
                return
            _sleep(1)


def _sleep(seconds):
    import time
    time.sleep(seconds)


# --- prefs editing (mirror set_ptt_prefs) ---------------------------------
PREF_KEYS = [
    "audioInputMethod", "talkKey", "hidePtt", "inputVolume",
    "handset_mode", "force_speaker", "mic_source", "auto_connect_on_boot",
]


def rewrite_prefs(xml, cfg):
    """Drop our managed keys, then inject fresh values before </map>."""
    kept = []
    for line in xml.splitlines():
        if any(f'name="{k}"' in line for k in PREF_KEYS):
            continue
        kept.append(line)
    xml = "\n".join(kept)
    block = (
        f'    <string name="audioInputMethod">ptt</string>\n'
        f'    <int name="talkKey" value="{cfg["ptt_keycode"]}" />\n'
        f'    <boolean name="hidePtt" value="{str(cfg["hide_ptt"]).lower()}" />\n'
        f'    <int name="inputVolume" value="{cfg["mic_volume"]}" />\n'
        f'    <boolean name="handset_mode" value="{str(cfg["handset_mode"]).lower()}" />\n'
        f'    <boolean name="force_speaker" value="{str(cfg["force_speaker"]).lower()}" />\n'
        f'    <string name="mic_source">{cfg["mic_source"]}</string>\n'
        f'    <boolean name="auto_connect_on_boot" value="{str(cfg["auto_connect_on_boot"]).lower()}" />\n'
        f'</map>'
    )
    if "</map>" in xml:
        xml = xml.replace("</map>", block, 1)
    else:
        xml = xml.rstrip() + "\n" + block + "\n"
    return xml


def prefs_ok(xml):
    if not xml:
        return False
    return sum(1 for k in PREF_KEYS if f'name="{k}"' in xml) >= 7


# --- the provisioning worker ----------------------------------------------
class Cancelled(Exception):
    pass


class Provisioner:
    def __init__(self, adb, cfg, apk, log, cancel_event):
        self.adb = adb
        self.cfg = cfg
        self.apk = apk
        self.log = log
        self.cancel = cancel_event
        self.status = {}

    def _check(self):
        if self.cancel.is_set():
            raise Cancelled()

    def read_old_number(self):
        """Read the radio number from a previously-installed S12 Mumla DB."""
        data = self.adb.pull_appfile(DB, binary=True)
        if not data:
            return None
        fd, tmp = tempfile.mkstemp(suffix=".db")
        os.close(fd)
        try:
            with open(tmp, "wb") as f:
                f.write(data)
            con = sqlite3.connect(tmp)
            try:
                row = con.execute(
                    "SELECT username FROM server ORDER BY _id LIMIT 1"
                ).fetchone()
                return row[0] if row and row[0] else None
            finally:
                con.close()
        except sqlite3.Error:
            return None
        finally:
            os.remove(tmp)

    def run(self):
        cfg = self.cfg
        self._check()

        # 1) install ---------------------------------------------------------
        if cfg["remove_stock_mumla"]:
            rc, _ = self.adb.run("shell", "pm", "path", STOCK_MUMLA)
            if rc == 0:
                self.log("[*] ลบ stock Mumla เดิม...")
                self.adb.run("uninstall", STOCK_MUMLA)
        if cfg["clean_reinstall"]:
            rc, _ = self.adb.run("shell", "pm", "path", PKG)
            if rc == 0:
                self.log("[*] ลบ S12 เดิมเพื่อ clean install...")
                self.adb.run("uninstall", PKG)
        self.log(f"[*] ติดตั้ง APK: {os.path.basename(self.apk)} ...")
        rc, out = self.adb.run("install", "-r", self.apk, timeout=300)
        if rc != 0 and "Success" not in out:
            # streamed install occasionally flakes; retry once
            self.log("    install สะดุด — ลองใหม่อีกครั้ง...")
            rc, out = self.adb.run("install", "-r", self.apk, timeout=300)
            if rc != 0 and "Success" not in out:
                raise RuntimeError(f"ติดตั้ง APK ไม่สำเร็จ:\n{out.strip()}")
        self._check()

        # grants
        self.adb.run("shell", "pm", "grant", PKG, "android.permission.RECORD_AUDIO")
        self.adb.run("shell", "pm", "grant", PKG, "android.permission.WRITE_SECURE_SETTINGS")

        # 2b) lock screen ----------------------------------------------------
        if cfg["disable_screen_lock"]:
            self.log("[*] ปิด lock screen (Screen lock = None)...")
            self.adb.run("shell", "locksettings", "set-disabled", "true")
            rc, out = self.adb.run("shell", "locksettings", "get-disabled")
            if "true" in out.lower():
                self.status["lock"] = "off"
                self.log("    lock screen ปิดแล้ว")
            else:
                self.status["lock"] = "UNCHANGED (มี PIN/pattern — ปลดเอง)"
                self.log("    [!] ปิดไม่ได้ (มี PIN/pattern) — ปลดเองที่ Settings > Security > Screen lock > None")

        # 3) certificate + DB init ------------------------------------------
        prefs = self.adb.pull_appfile(PREFS) or ""
        if 'name="certificateId"' in prefs:
            self.log("[*] มี certificate อยู่แล้ว — คงไว้")
            if not self.adb.have(DB):
                self.adb.run("shell", "monkey", "-p", PKG, "-c",
                             "android.intent.category.LAUNCHER", "1")
        else:
            self.log("[*] สร้าง client certificate (+ สร้าง DB)...")
            self.adb.run("shell", "am", "start", "-n", GEN_ACT)
        ok = False
        for _ in range(30):
            self._check()
            prefs = self.adb.pull_appfile(PREFS) or ""
            if self.adb.have(DB) and 'name="certificateId"' in prefs:
                ok = True
                break
            _sleep(1)
        self.adb.stop_app()
        if not ok:
            raise RuntimeError("สร้าง certificate/DB ไม่สำเร็จ — เปิดแอปสักครั้งแล้วลองใหม่")

        tmpdir = tempfile.mkdtemp()
        try:
            # 4) add server --------------------------------------------------
            self.log(f"[*] เพิ่ม server '{cfg['server_name']}' เป็น '{cfg['username']}'...")
            data = self.adb.pull_appfile(DB, binary=True)
            if not data:
                raise RuntimeError("อ่าน DB ไม่ได้")
            dbpath = os.path.join(tmpdir, "mumble.db")
            with open(dbpath, "wb") as f:
                f.write(data)
            con = sqlite3.connect(dbpath)
            try:
                con.execute("PRAGMA journal_mode=DELETE")
                con.execute(
                    "DELETE FROM server WHERE host=? AND port=? AND name=?",
                    (cfg["server_host"], int(cfg["server_port"]), cfg["server_name"]),
                )
                con.execute(
                    "INSERT INTO server (name,host,port,username,password) "
                    "VALUES (?,?,?,?,?)",
                    (cfg["server_name"], cfg["server_host"], int(cfg["server_port"]),
                     cfg["username"], cfg["password"]),
                )
                con.commit()
            finally:
                con.close()
            self.adb.push_appfile(dbpath, DB)
            for ext in ("-journal", "-wal", "-shm"):
                self.adb.run("shell", "run-as", PKG, "rm", "-f", DB + ext)
            self._check()

            # 5) prefs -------------------------------------------------------
            self.log(f"[*] ตั้งค่า PTT/ไมค์ (F12, {cfg['mic_source']}, {cfg['mic_volume']}%)...")
            prefs = self.adb.pull_appfile(PREFS) or ""
            newp = os.path.join(tmpdir, "p.xml")
            with open(newp, "w", encoding="utf-8") as f:
                f.write(rewrite_prefs(prefs, cfg))
            self.adb.push_appfile(newp, PREFS)

            # 6) launch, re-verify prefs stuck ------------------------------
            self.adb.stop_app()
            self.adb.run("shell", "monkey", "-p", PKG, "-c",
                         "android.intent.category.LAUNCHER", "1")
            _sleep(4)
            prefs = self.adb.pull_appfile(PREFS) or ""
            if not prefs_ok(prefs):
                self.log("    แอป flush prefs ทับ — เขียนซ้ำและปิดแอป")
                self.adb.stop_app()
                prefs = self.adb.pull_appfile(PREFS) or ""
                with open(newp, "w", encoding="utf-8") as f:
                    f.write(rewrite_prefs(prefs, cfg))
                self.adb.push_appfile(newp, PREFS)
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)

        # 7) background PTT -------------------------------------------------
        if cfg["enable_bg_ptt"]:
            self.log("[*] เปิด background PTT (accessibility + battery whitelist)...")
            rc, cur = self.adb.run("shell", "settings", "get", "secure",
                                   "enabled_accessibility_services")
            cur = cur.strip()
            if cur in ("null", ""):
                cur = ""
            svcs = cur.split(":") if cur else []
            if A11Y_SVC not in svcs:
                svcs.append(A11Y_SVC)
            joined = ":".join(s for s in svcs if s)
            self.adb.run("shell", "settings", "put", "secure", "accessibility_enabled", "0")
            self.adb.run("shell", "settings", "put", "secure",
                         "enabled_accessibility_services", joined)
            self.adb.run("shell", "settings", "put", "secure", "accessibility_enabled", "1")
            self.adb.run("shell", "dumpsys", "deviceidle", "whitelist", "+" + PKG)
            _sleep(2)
            rc, dump = self.adb.run("shell", "dumpsys", "accessibility")
            if "MumlaPTT" in dump or "Mumla background PTT" in dump:
                self.status["bgptt"] = "on (accessibility bound + battery whitelist)"
                self.log("    accessibility ผูกแล้ว (bound) + battery whitelist")
            else:
                self.status["bgptt"] = "FAILED — เปิด Accessibility เอง"
                self.log("    [!] accessibility ไม่ผูก — เปิดเองที่ Settings > Accessibility > S12 Mumla")

        # 8) neutralize rival PTT -------------------------------------------
        if cfg["neutralize_rival_ptt"]:
            done = []
            for rp in RIVAL_PTT:
                rc, _ = self.adb.run("shell", "pm", "path", rp)
                if rc != 0:
                    continue
                self.adb.run("shell", "am", "force-stop", rp)
                if cfg["disable_rival_ptt"]:
                    self.adb.run("shell", "pm", "disable-user", "--user", "0", rp)
                else:
                    self.adb.run("shell", "cmd", "appops", "set", rp,
                                 "RUN_IN_BACKGROUND", "ignore")
                done.append(rp)
            if done:
                verb = "disabled" if cfg["disable_rival_ptt"] else "bg-restricted + stopped"
                self.status["rival"] = f"{', '.join(done)} ({verb})"
                self.log(f"[*] จัดการแอพคู่แข่ง: {', '.join(done)} ({verb})")
            else:
                self.status["rival"] = "ไม่มีติดตั้ง"

        self.log("")
        self.log(f"[✓] เสร็จสิ้น — เครื่อง {cfg['username']} พร้อมใช้งาน")
        self.log(f"    ไมค์: {cfg['mic_source']} | volume {cfg['mic_volume']}% | "
                 f"handset={cfg['handset_mode']} | force_speaker={cfg['force_speaker']}")
        if self.status.get("lock", "").startswith("UNCHANGED"):
            self.log("    [!] อย่าลืมปิด lock screen เอง: Settings > Security > Screen lock > None")


# --- GUI -------------------------------------------------------------------
class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Mumla POC Installer — S12")
        self.geometry("720x680")
        self.minsize(680, 600)

        self.adb_path = find_adb()
        self.msg_queue = queue.Queue()
        self.cancel_event = threading.Event()
        self.worker = None
        self.vars = {}

        self._build()
        self.after(100, self._drain_queue)
        self.refresh_devices()

    # ---- layout ----
    def _build(self):
        pad = dict(padx=6, pady=3)
        top = ttk.Frame(self)
        top.pack(fill="x", **pad)

        ttk.Label(top, text="อุปกรณ์:").grid(row=0, column=0, sticky="w")
        self.device_cb = ttk.Combobox(top, state="readonly", width=28)
        self.device_cb.grid(row=0, column=1, sticky="w", padx=4)
        ttk.Button(top, text="รีเฟรช", command=self.refresh_devices).grid(row=0, column=2, padx=2)
        ttk.Button(top, text="อ่านเลขเดิม", command=self.read_old_number).grid(row=0, column=3, padx=2)

        # settings notebook
        nb = ttk.Notebook(self)
        nb.pack(fill="x", **pad)

        # --- server / number tab ---
        srv = ttk.Frame(nb)
        nb.add(srv, text="เซิร์ฟเวอร์ / เลขเครื่อง")
        self._entry(srv, 0, "เลขเครื่อง (username)", "username")
        self._entry(srv, 1, "ชื่อ server", "server_name")
        self._entry(srv, 2, "Host / IP", "server_host")
        self._entry(srv, 3, "Port", "server_port")
        self._entry(srv, 4, "รหัสผ่าน (ถ้ามี)", "password")

        # --- audio / ptt tab ---
        aud = ttk.Frame(nb)
        nb.add(aud, text="เสียง / PTT")
        ttk.Label(aud, text="ไมโครโฟน").grid(row=0, column=0, sticky="w", padx=6, pady=3)
        self.vars["mic_source"] = tk.StringVar(value=DEFAULTS["mic_source"])
        self.mic_cb = ttk.Combobox(aud, state="readonly", width=32,
                                   values=[label for _, label in MIC_SOURCES])
        self.mic_cb.grid(row=0, column=1, sticky="w", padx=4)
        self.mic_cb.current([k for k, _ in MIC_SOURCES].index(DEFAULTS["mic_source"]))
        self._entry(aud, 1, "ระดับเสียงไมค์ (%)", "mic_volume")
        self._entry(aud, 2, "PTT keycode (F12=142)", "ptt_keycode")
        self._check(aud, 3, "โหมดโทรศัพท์ (handset — ไมค์ดี)", "handset_mode")
        self._check(aud, 4, "บังคับใช้ลำโพงนอก (เสียงดัง)", "force_speaker")
        self._check(aud, 5, "ซ่อนปุ่ม PTT บนจอ", "hide_ptt")
        self._check(aud, 6, "auto-connect ตอนบูต", "auto_connect_on_boot")

        # --- device / options tab ---
        opt = ttk.Frame(nb)
        nb.add(opt, text="ตัวเลือกอื่น")
        self._check(opt, 0, "ปิด lock screen (Screen lock = None)", "disable_screen_lock")
        self._check(opt, 1, "เปิด background PTT (จอล็อกกดพูดได้)", "enable_bg_ptt")
        self._check(opt, 2, "clean reinstall (ลบตัวเก่าก่อน)", "clean_reinstall")
        self._check(opt, 3, "ลบ stock Mumla เดิม", "remove_stock_mumla")
        self._check(opt, 4, "จัดการแอพ PTT คู่แข่ง (Xin POC ฯลฯ)", "neutralize_rival_ptt")
        self._check(opt, 5, "ปิดแอพคู่แข่งถาวร (disable-user)", "disable_rival_ptt")

        # APK row
        apk = ttk.Frame(self)
        apk.pack(fill="x", **pad)
        ttk.Label(apk, text="APK:").pack(side="left")
        self.apk_var = tk.StringVar(value=find_default_apk())
        ttk.Entry(apk, textvariable=self.apk_var).pack(side="left", fill="x", expand=True, padx=4)
        ttk.Button(apk, text="เลือกไฟล์...", command=self.browse_apk).pack(side="left")

        # action buttons
        act = ttk.Frame(self)
        act.pack(fill="x", **pad)
        self.install_btn = ttk.Button(act, text="ติดตั้งลงเครื่อง", command=self.start_install)
        self.install_btn.pack(side="left")
        self.cancel_btn = ttk.Button(act, text="ยกเลิก", command=self.cancel_install, state="disabled")
        self.cancel_btn.pack(side="left", padx=4)
        ttk.Button(act, text="ล้าง log", command=lambda: self.log_widget.delete("1.0", "end")).pack(side="right")

        # log
        self.log_widget = scrolledtext.ScrolledText(self, height=16, wrap="word",
                                                     font=("Consolas", 10))
        self.log_widget.pack(fill="both", expand=True, padx=6, pady=6)

        self._apply_defaults()

    def _entry(self, parent, row, label, key):
        ttk.Label(parent, text=label).grid(row=row, column=0, sticky="w", padx=6, pady=3)
        v = tk.StringVar()
        self.vars[key] = v
        ttk.Entry(parent, textvariable=v, width=34).grid(row=row, column=1, sticky="w", padx=4)

    def _check(self, parent, row, label, key):
        v = tk.BooleanVar()
        self.vars[key] = v
        ttk.Checkbutton(parent, text=label, variable=v).grid(
            row=row, column=0, columnspan=2, sticky="w", padx=6, pady=2)

    def _apply_defaults(self):
        for k, val in DEFAULTS.items():
            if k in self.vars:
                self.vars[k].set(val)

    # ---- device ops ----
    def refresh_devices(self):
        try:
            devs = Adb(self.adb_path).devices()
        except Exception as e:
            self.log(f"[!] เรียก adb ไม่ได้: {e}")
            devs = []
        self.device_cb["values"] = devs
        if devs:
            if self.device_cb.get() not in devs:
                self.device_cb.current(0)
            self.log(f"[*] พบอุปกรณ์: {', '.join(devs)}")
        else:
            self.device_cb.set("")
            self.log("[*] ไม่พบอุปกรณ์ — เสียบ USB + เปิด USB debugging")

    def _current_serial(self):
        s = self.device_cb.get().strip()
        return s or None

    def read_old_number(self):
        serial = self._current_serial()
        if not serial:
            self.log("[!] ยังไม่ได้เลือกอุปกรณ์")
            return

        def work():
            adb = Adb(self.adb_path, serial)
            num = Provisioner(adb, {}, "", self.log, self.cancel_event).read_old_number()
            if num:
                self.msg_queue.put(("set_username", num))
                self.log(f"[*] อ่านเลขเดิมจากแอพเก่า: {num}")
            else:
                self.log("[!] อ่านเลขเดิมไม่ได้ (ไม่มีแอพเก่า/ไม่มี server) — พิมพ์เลขเอง")

        threading.Thread(target=work, daemon=True).start()

    def browse_apk(self):
        path = filedialog.askopenfilename(
            title="เลือกไฟล์ APK", filetypes=[("APK", "*.apk"), ("ทั้งหมด", "*.*")])
        if path:
            self.apk_var.set(path)

    # ---- install ----
    def _collect_cfg(self):
        cfg = {}
        for k in DEFAULTS:
            if k == "mic_source":
                cfg[k] = [key for key, _ in MIC_SOURCES][self.mic_cb.current()]
            elif isinstance(DEFAULTS[k], bool):
                cfg[k] = bool(self.vars[k].get())
            else:
                cfg[k] = str(self.vars[k].get()).strip()
        return cfg

    def start_install(self):
        serial = self._current_serial()
        if not serial:
            self.log("[!] ยังไม่ได้เลือกอุปกรณ์")
            return
        apk = self.apk_var.get().strip()
        if not apk or not os.path.isfile(apk):
            self.log("[!] ยังไม่ได้เลือกไฟล์ APK ที่ถูกต้อง")
            return
        cfg = self._collect_cfg()
        if not cfg["username"]:
            self.log("[!] ยังไม่ได้ใส่เลขเครื่อง (username)")
            return
        if not cfg["server_host"] or not cfg["server_port"].isdigit():
            self.log("[!] host/port ไม่ถูกต้อง")
            return

        self.cancel_event.clear()
        self.install_btn.config(state="disabled")
        self.cancel_btn.config(state="normal")
        self.log("=" * 56)
        self.log(f"[*] เริ่มติดตั้งเครื่อง {cfg['username']} (serial {serial})")

        def work():
            adb = Adb(self.adb_path, serial)
            try:
                Provisioner(adb, cfg, apk, self.log, self.cancel_event).run()
            except Cancelled:
                self.log("[!] ยกเลิกแล้ว")
            except Exception as e:
                self.log(f"[!] ผิดพลาด: {e}")
            finally:
                self.msg_queue.put(("done", None))

        self.worker = threading.Thread(target=work, daemon=True)
        self.worker.start()

    def cancel_install(self):
        self.cancel_event.set()
        self.log("[*] กำลังยกเลิก...")

    # ---- queue / log ----
    def log(self, text):
        self.msg_queue.put(("log", text))

    def _drain_queue(self):
        try:
            while True:
                kind, payload = self.msg_queue.get_nowait()
                if kind == "log":
                    self.log_widget.insert("end", payload + "\n")
                    self.log_widget.see("end")
                elif kind == "set_username":
                    self.vars["username"].set(payload)
                elif kind == "done":
                    self.install_btn.config(state="normal")
                    self.cancel_btn.config(state="disabled")
        except queue.Empty:
            pass
        self.after(100, self._drain_queue)


if __name__ == "__main__":
    App().mainloop()
