#!/usr/bin/env python3
"""AltVM guest agent (Linux).

Listens on virtio-vsock port 7700 and speaks newline-delimited JSON with the host.
No network, SSH keys or IP discovery required — it works even in isolated VMs.
Installed automatically by cloud-init for catalog VMs; for other guests copy this file to
/usr/local/bin/altvm-agent and install guest-agent/altvm-agent.service.
"""
import base64, json, os, socket, subprocess, threading, time

PORT = 7700
VERSION = "1.0"


def sh(cmd, timeout=30):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except Exception:
        return ""


def info(_req):
    ips = []
    for line in sh(["ip", "-o", "addr", "show", "scope", "global"]).splitlines():
        parts = line.split()
        if len(parts) >= 4:
            ips.append({"iface": parts[1], "family": parts[2], "addr": parts[3].split("/")[0]})
    osname = ""
    try:
        for line in open("/etc/os-release"):
            if line.startswith("PRETTY_NAME="):
                osname = line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    mem = {}
    try:
        for line in open("/proc/meminfo"):
            k, v = line.split(":", 1)
            if k in ("MemTotal", "MemAvailable"):
                mem[k] = int(v.split()[0]) * 1024
    except OSError:
        pass
    st = os.statvfs("/")
    return {
        "hostname": socket.gethostname(),
        "os": osname,
        "kernel": os.uname().release,
        "arch": os.uname().machine,
        "uptime": float(open("/proc/uptime").read().split()[0]),
        "load": os.getloadavg(),
        "ips": ips,
        "memTotal": mem.get("MemTotal"),
        "memAvailable": mem.get("MemAvailable"),
        "diskTotal": st.f_blocks * st.f_frsize,
        "diskFree": st.f_bavail * st.f_frsize,
        "agentVersion": VERSION,
    }


def exec_(req):
    args = req.get("args") or []
    if isinstance(args, str):
        args = ["/bin/sh", "-c", args]
    stdin = req.get("stdin", "")
    env = dict(os.environ)
    env.update(req.get("env") or {})
    t0 = time.time()
    try:
        p = subprocess.run(args, input=stdin, capture_output=True, text=True, errors="replace",
                           timeout=req.get("timeout", 300), cwd=req.get("cwd") or None, env=env)
        return {"exitCode": p.returncode, "stdout": p.stdout, "stderr": p.stderr, "seconds": time.time() - t0}
    except subprocess.TimeoutExpired as e:
        return {"exitCode": 124, "stdout": e.stdout or "", "stderr": "timeout", "seconds": time.time() - t0}


def later(cmd):
    def run():
        time.sleep(0.5)
        subprocess.run(cmd)
    threading.Thread(target=run, daemon=True).start()


def shutdown(_req):
    later(["systemctl", "poweroff"])
    return {"accepted": True}


def reboot(_req):
    later(["systemctl", "reboot"])
    return {"accepted": True}


def fstrim(_req):
    return {"output": sh(["fstrim", "-av"], timeout=600)}


def timesync(req):
    epoch = req.get("epoch")
    if epoch:
        sh(["date", "-u", "-s", "@%d" % int(epoch)])
    return {"now": time.time()}


def write_file(req):
    path = req["path"]
    os.makedirs(os.path.dirname(path) or "/", exist_ok=True)
    with open(path, "wb") as f:
        f.write(base64.b64decode(req.get("content", "")))
    if "mode" in req:
        os.chmod(path, int(str(req["mode"]), 8))
    return {"bytes": os.path.getsize(path)}


def read_file(req):
    with open(req["path"], "rb") as f:
        return {"content": base64.b64encode(f.read()).decode()}


OPS = {"ping": lambda r: {"pong": True, "version": VERSION}, "info": info, "exec": exec_,
       "shutdown": shutdown, "reboot": reboot, "fstrim": fstrim, "timesync": timesync,
       "write_file": write_file, "read_file": read_file}


def serve(conn):
    buf = b""
    with conn:
        while True:
            chunk = conn.recv(65536)
            if not chunk:
                return
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                try:
                    req = json.loads(line)
                    fn = OPS.get(req.get("op"))
                    if fn is None:
                        resp = {"id": req.get("id"), "ok": False, "error": "unknown op"}
                    else:
                        resp = {"id": req.get("id"), "ok": True, "result": fn(req)}
                except Exception as e:  # report, never crash the agent
                    resp = {"id": None, "ok": False, "error": str(e)}
                conn.sendall(json.dumps(resp).encode() + b"\n")


def main():
    s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((socket.VMADDR_CID_ANY, PORT))
    s.listen(16)
    while True:
        conn, _ = s.accept()
        threading.Thread(target=serve, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()
