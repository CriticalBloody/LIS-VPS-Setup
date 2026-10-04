#!/usr/bin/env python3
"""
Lars IT Solutions — VPS Monitoring Agent
Lightweight, dependency-free telemetry agent for Ubuntu/Debian Managed Servers.
Exposes CPU, RAM, Disk and Linux Kernel Uptime over a secure HTTP endpoint.
"""

import os
import time
import json
import socket
import platform
import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler

AGENT_PORT = int(os.environ.get("AGENT_PORT", 8089))
AGENT_TOKEN = os.environ.get("AGENT_TOKEN", "").strip()

# Base paths (support both bare-metal and Docker container mounts)
PROC_DIR = "/host/proc" if os.path.isdir("/host/proc") else "/proc"
ROOT_DIR = "/host/root" if os.path.isdir("/host/root") else "/"


def get_cpu_times():
    """Reads cumulative CPU jiffies from /proc/stat."""
    stat_file = os.path.join(PROC_DIR, "stat")
    if not os.path.isfile(stat_file):
        return None
    try:
        with open(stat_file, "r") as f:
            for line in f:
                if line.startswith("cpu "):
                    parts = [float(x) for x in line.strip().split()[1:]]
                    idle = parts[3] + (parts[4] if len(parts) > 4 else 0.0)
                    total = sum(parts)
                    return total, idle
    except Exception:
        pass
    return None


def get_cpu_usage(interval=0.25):
    """Calculates live CPU percentage by taking two samples over interval."""
    sample1 = get_cpu_times()
    if not sample1:
        # Fallback to load average
        try:
            load1, _, _ = os.getloadavg()
            cores = os.cpu_count() or 1
            return round(min(100.0, (load1 / cores) * 100.0), 1)
        except Exception:
            return 0.0

    time.sleep(interval)
    sample2 = get_cpu_times()
    if not sample2:
        return 0.0

    total_delta = sample2[0] - sample1[0]
    idle_delta = sample2[1] - sample1[1]
    if total_delta <= 0:
        return 0.0

    usage = 100.0 * (1.0 - (idle_delta / total_delta))
    return round(max(0.0, min(100.0, usage)), 1)


def get_memory_info():
    """Reads memory metrics from /proc/meminfo."""
    mem_file = os.path.join(PROC_DIR, "meminfo")
    data = {}
    if os.path.isfile(mem_file):
        try:
            with open(mem_file, "r") as f:
                for line in f:
                    parts = line.split(":")
                    if len(parts) == 2:
                        key = parts[0].strip()
                        val = parts[1].strip().split()[0]
                        data[key] = float(val)
        except Exception:
            pass

    total_kb = data.get("MemTotal", 0.0)
    avail_kb = data.get("MemAvailable", data.get("MemFree", 0.0) + data.get("Buffers", 0.0) + data.get("Cached", 0.0))
    used_kb = max(0.0, total_kb - avail_kb)

    total_mb = round(total_kb / 1024.0, 1)
    used_mb = round(used_kb / 1024.0, 1)
    total_gb = round(total_kb / (1024.0 * 1024.0), 2)
    used_gb = round(used_kb / (1024.0 * 1024.0), 2)
    percent = round((used_kb / total_kb * 100.0), 1) if total_kb > 0 else 0.0

    return {
        "total_mb": total_mb,
        "used_mb": used_mb,
        "total_gb": total_gb,
        "used_gb": used_gb,
        "percent": percent
    }


def get_disk_info():
    """Reads disk storage usage of the root filesystem."""
    try:
        stat = os.statvfs(ROOT_DIR)
        total_b = stat.f_blocks * stat.f_frsize
        avail_b = stat.f_bavail * stat.f_frsize
        used_b = total_b - avail_b

        total_gb = round(total_b / (1024.0 ** 3), 1)
        used_gb = round(used_b / (1024.0 ** 3), 1)
        percent = round((used_b / total_b * 100.0), 1) if total_b > 0 else 0.0

        return {
            "total_gb": total_gb,
            "used_gb": used_gb,
            "percent": percent
        }
    except Exception:
        return {"total_gb": 0.0, "used_gb": 0.0, "percent": 0.0}


def get_uptime_info():
    """Reads real Linux kernel uptime from /proc/uptime."""
    uptime_file = os.path.join(PROC_DIR, "uptime")
    seconds = 0
    if os.path.isfile(uptime_file):
        try:
            with open(uptime_file, "r") as f:
                seconds = int(float(f.readline().split()[0]))
        except Exception:
            pass

    days = seconds // 86400
    hours = (seconds % 86400) // 3600
    minutes = (seconds % 3600) // 60

    if days >= 1:
        text = f"{days} Tag{'e' if days != 1 else ''}, {hours} Std."
    elif hours >= 1:
        text = f"{hours} Std., {minutes} Min."
    else:
        text = f"{max(1, minutes)} Min."

    return {
        "seconds": seconds,
        "text": text
    }


def get_services_info():
    """Returns active service / Docker container count."""
    # Check Docker containers if docker.sock is available
    for sock in ["/var/run/docker.sock", "/host/root/var/run/docker.sock"]:
        if os.path.exists(sock):
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.settimeout(0.5)
                s.connect(sock)
                s.sendall(b"GET /containers/json HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
                raw = b""
                while True:
                    chunk = s.recv(4096)
                    if not chunk:
                        break
                    raw += chunk
                s.close()
                if b"\r\n\r\n" in raw:
                    _, body = raw.split(b"\r\n\r\n", 1)
                    try:
                        data = json.loads(body.decode("utf-8", errors="ignore"))
                        if isinstance(data, list):
                            return {"count": len(data), "label": "Container"}
                    except Exception:
                        import re
                        matches = re.findall(rb'"Id":\s*"[a-f0-9]+"', body)
                        if matches:
                            return {"count": len(matches), "label": "Container"}
            except Exception:
                pass

    # Fallback: Process count from /proc
    try:
        pids = [d for d in os.listdir(PROC_DIR) if d.isdigit()]
        return {"count": len(pids), "label": "Dienste"}
    except Exception:
        return {"count": 0, "label": "Dienste"}


def get_hostname():
    """Returns the host name."""
    hostname_file = os.path.join(PROC_DIR, "sys/kernel/hostname")
    if os.path.isfile(hostname_file):
        try:
            with open(hostname_file, "r") as f:
                return f.read().strip()
        except Exception:
            pass
    return platform.node() or socket.gethostname()


class MetricsHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Keep logs clean (minimal)
        pass

    def _is_authorized(self):
        if not AGENT_TOKEN:
            return True
        
        # Check Authorization: Bearer <TOKEN>
        auth_header = self.headers.get("Authorization", "")
        if auth_header.startswith("Bearer "):
            token = auth_header[7:].strip()
            if token == AGENT_TOKEN:
                return True

        # Check X-Agent-Token
        custom_header = self.headers.get("X-Agent-Token", "").strip()
        if custom_header == AGENT_TOKEN:
            return True

        # Check query param ?token=...
        if "?" in self.path:
            query = self.path.split("?", 1)[1]
            for param in query.split("&"):
                if param.startswith("token="):
                    if param[6:].strip() == AGENT_TOKEN:
                        return True

        return False

    def do_GET(self):
        # Health endpoint without token
        if self.path == "/health" or self.path == "/ping":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"ok","service":"lars-it-vps-agent"}\n')
            return

        # Check authentication for metrics
        if not self._is_authorized():
            self.send_response(401)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"error":"unauthorized","message":"Invalid or missing Agent-Token"}\n')
            return

        # Collect metrics
        cpu = get_cpu_usage()
        mem = get_memory_info()
        disk = get_disk_info()
        uptime = get_uptime_info()
        srv = get_services_info()
        cores = os.cpu_count() or 1
        
        load = [0.0, 0.0, 0.0]
        try:
            load = [round(x, 2) for x in os.getloadavg()]
        except Exception:
            pass

        payload = {
            "status": "online",
            "hostname": get_hostname(),
            "cpu_percent": cpu,
            "cores": cores,
            "ram": mem,
            "disk": disk,
            "uptime_seconds": uptime["seconds"],
            "uptime_text": uptime["text"],
            "active_services": srv["count"],
            "services_label": srv["label"],
            "load": load,
            "timestamp": datetime.datetime.utcnow().isoformat() + "Z"
        }

        body = json.dumps(payload, indent=2).encode("utf-8")

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
        self.end_headers()
        self.wfile.write(body)


def run():
    server_address = ("0.0.0.0", AGENT_PORT)
    httpd = HTTPServer(server_address, MetricsHandler)
    print(f"Lars IT Solutions VPS Agent listening on http://0.0.0.0:{AGENT_PORT}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    httpd.server_close()


if __name__ == "__main__":
    run()
