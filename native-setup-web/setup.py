"""Native AiboOS development package. Local files and approved host driver preparation only."""
import hashlib
import http.server
import json
import lzma
import os
import pathlib
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import threading
import webbrowser

BASE = pathlib.Path(sys.executable if getattr(sys, "frozen", False) else __file__).resolve().parent
ASSETS = pathlib.Path(getattr(sys, "_MEIPASS", BASE))
PAYLOAD = BASE / "native"
TOKEN = secrets.token_hex(32)
LOCK = threading.RLock()
STATE = {"busy": False, "ready": False, "driver_missing": False, "progress": 0, "status": "Ready.", "log": "", "stages": [
    {"title": title, "state": "pending", "detail": detail} for title, detail in [
        ("USB connection", "Looking for connected Apple devices."),
        ("DFU mode", "Not yet checked."),
        ("Windows DFU driver", "Not yet checked."),
        ("AiboOS ARM64 image", "Ready for local verification."),
        ("Linux kernel and A9 device trees", "Ready for local verification."),
        ("Native boot", "Physical boot not yet verified."),
        ("Permanent installation", "No verified A9 storage installer.")
    ]
]}
STATE["stages"][5]["state"] = STATE["stages"][6]["state"] = "blocked"
DEST = None

def stage(i, status, detail):
    with LOCK:
        STATE["stages"][i].update(state=status, detail=detail)

def update(**kw):
    with LOCK:
        STATE.update(kw)

def snapshot():
    with LOCK:
        return json.loads(json.dumps(STATE))

def scan():
    rows = []
    if os.name == "nt":
        query = r"""$ErrorActionPreference='Stop'; Get-CimInstance Win32_PnPEntity | Where-Object {$_.Present -eq $true -and $_.PNPDeviceID -match '^USB\\VID_05AC&PID_[0-9A-F]{4}\\'} | ForEach-Object {if($_.PNPDeviceID -match 'VID_05AC&PID_([0-9A-F]{4})'){ $p=$Matches[1]; Write-Output "$p|$($_.Service)"}}"""
        proc = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", query], capture_output=True, text=True, timeout=20, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        if proc.returncode:
            raise RuntimeError(proc.stderr.strip() or "Windows device lookup failed.")
        for line in proc.stdout.splitlines():
            if re.fullmatch(r"[0-9a-fA-F]{4}\|[A-Za-z0-9_-]*", line.strip()):
                p, driver = line.strip().split("|")
                rows.append((p.lower(), driver.lower()))
    else:
        for dev in pathlib.Path("/sys/bus/usb/devices").glob("*"):
            try:
                if (dev / "idVendor").read_text().strip().lower() == "05ac":
                    rows.append(((dev / "idProduct").read_text().strip().lower(), "linux"))
            except OSError:
                pass
    dfu = [d for p, d in rows if p == "1227"]
    stage(0, "ok" if rows else "pending", "Apple USB device detected." if rows else "No Apple USB device detected.")
    stage(1, "ok" if len(dfu)==1 else "pending", "One DFU device detected." if len(dfu)==1 else "Connect one iPhone in DFU for driver checks.")
    missing = os.name == "nt" and len(dfu)==1 and dfu[0] not in ("winusb", "libusbk", "libusb0")
    good = os.name == "nt" and len(dfu)==1 and not missing
    stage(2, "ok" if good else "pending", ("Compatible binding: "+dfu[0]+" (access not tested).") if good else "Driver installation can be requested for one DFU device." if missing else "Windows driver binding not confirmed.")
    update(driver_missing=missing)

def hashfile(p):
    with p.open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()

def manifest():
    expected = {}
    for line in (PAYLOAD / "SHA256SUMS.txt").read_text().splitlines():
        digest, name = line.split(maxsplit=1)
        if not re.fullmatch("[0-9a-f]{64}", digest):
            raise ValueError("Invalid checksum")
        expected[name] = digest
    return expected

def verify(name, sums):
    p = PAYLOAD / name
    if not p.is_file() or hashfile(p) != sums.get(name):
        raise ValueError("Missing or damaged native file: "+name)
    return p

def prepare(directory):
    sums = manifest()
    stage(3, "active", "Checking compressed ARM64 image.")
    src = verify("AiboOS-ARM64-rootfs.ext4.xz", sums)
    directory.mkdir(parents=True, exist_ok=False)
    target = directory / "AiboOS-ARM64-rootfs.ext4"
    count = 0
    limit = 256 * 1024 * 1024
    with lzma.open(src, "rb") as stream, target.open("xb") as out:
        while chunk := stream.read(1024*1024):
            count += len(chunk)
            if count > limit:
                raise ValueError("Unexpected ARM64 filesystem size.")
            out.write(chunk)
            update(progress=int(count*80/limit))
    if count != limit or hashfile(target) != sums.get("AiboOS-ARM64-rootfs.ext4"):
        raise ValueError("Decompressed ARM64 image verification failed.")
    stage(3,"ok","256 MiB ext4 system image verified.")
    stage(4,"active","Checking kernel and device trees.")
    for name in ("Image.gz","s8000-n69u.dtb","s8003-n69.dtb","kernel-commit.txt"):
        p = verify(name,sums)
        shutil.copyfile(p,directory/name)
        if hashfile(directory/name) != sums[name]:
            raise ValueError("Copied file verification failed: "+name)
    stage(4,"ok","ARM64 Linux kernel and both A9 device trees verified.")
    update(progress=100)

def driver():
    scan()
    if not snapshot()["driver_missing"]:
        update(status="No missing compatible DFU driver detected.")
        return
    script = BASE / "Prepare-DFU-Driver.ps1"
    if not script.is_file():
        raise RuntimeError("Bundled Windows driver helper missing.")
    p = subprocess.run(["powershell.exe","-NoProfile","-File",str(script)], capture_output=True, text=True, creationflags=getattr(subprocess,"CREATE_NO_WINDOW",0))
    update(log=(p.stdout+"\n"+p.stderr)[-5000:])
    scan()
    update(status="Driver helper completed; binding rechecked." if p.returncode==0 else "Driver preparation stopped. See advanced information.")

def launch(action):
    global DEST
    with LOCK:
        if STATE["busy"]:
            return
        STATE["busy"] = True
    def worker():
        global DEST
        candidate = None
        try:
            if action=="prepare":
                update(ready=False,progress=0,status="Verifying native system files…")
                DEST = None
                parent=pathlib.Path.home()/"AiboOS"/"Images"
                parent.mkdir(parents=True,exist_ok=True)
                candidate=parent/secrets.token_hex(8)
                prepare(candidate)
                DEST=candidate
                update(ready=True,status="Native files verified and saved on this computer. No phone installation performed.")
            elif action=="driver":
                driver()
            else:
                scan()
                update(status="USB status refreshed.")
        except Exception as exc:
            if action=="prepare":
                if candidate is not None and candidate.exists():
                    shutil.rmtree(candidate,ignore_errors=True)
                stage(3,"error","Image preparation stopped.")
                stage(4,"pending","Native file verification not completed.")
                update(progress=0,ready=False)
            update(status=str(exc))
        finally:
            update(busy=False)
    threading.Thread(target=worker, daemon=True).start()

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a):
        pass
    def reply(self,body,ctype):
        self.send_response(200)
        self.send_header("Content-Type",ctype)
        self.send_header("Content-Length",str(len(body)))
        self.send_header("Cache-Control","no-store")
        self.send_header("X-Content-Type-Options","nosniff")
        self.end_headers()
        self.wfile.write(body)
    def allowed(self):
        return self.headers.get("Host")==f"127.0.0.1:{self.server.server_port}"
    def auth(self):
        return self.allowed() and secrets.compare_digest(self.headers.get("X-AiboOS-Token",""),TOKEN)
    def do_GET(self):
        if not self.allowed():
            self.send_error(403);return
        if self.path=="/":
            self.reply((ASSETS/"index.html").read_text(encoding="utf-8").replace("__TOKEN__",TOKEN).encode(),"text/html; charset=utf-8")
        elif self.path=="/logo.png":
            self.reply((ASSETS/"logo.png").read_bytes(),"image/png")
        elif self.path=="/status" and self.auth():
            self.reply(json.dumps(snapshot()).encode(),"application/json")
        else:
            self.send_error(404)
    def do_POST(self):
        if not self.auth():
            self.send_error(403);return
        if self.path in ("/prepare","/scan","/driver"):
            launch(self.path[1:])
        elif self.path=="/folder" and DEST and snapshot()["ready"]:
            if os.name=="nt": os.startfile(DEST)
            else: subprocess.Popen(["xdg-open",str(DEST)])
        else:
            self.send_error(404);return
        self.reply(json.dumps(snapshot()).encode(),"application/json")

if __name__=="__main__":
    if "--selftest" in sys.argv:
        with tempfile.TemporaryDirectory() as d:
            prepare(pathlib.Path(d)/"image")
            assert snapshot()["progress"]==100
        print("PASS: complete native bundle and decompressed image verified.")
    else:
        server=http.server.ThreadingHTTPServer(("127.0.0.1",0),Handler)
        launch("scan")
        webbrowser.open(f"http://127.0.0.1:{server.server_port}/")
        server.serve_forever()
