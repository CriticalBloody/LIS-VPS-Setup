#!/usr/bin/env bash
# ==============================================================================
# Lars IT Solutions — Managed VPS Onboarding & Monitoring Setup Script
# Repository: https://github.com/CriticalBloody/LIS-VPS-Setup
#
# Führt System-Updates durch, härtet das System (UFW, fail2ban, Auto-Updates),
# installiert Docker und startet den Lars IT Monitoring Agent.
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${BLUE}==============================================================================${NC}"
echo -e "${CYAN}   Lars IT Solutions — Managed Server Onboarding & Agent Setup               ${NC}"
echo -e "${BLUE}==============================================================================${NC}"

# 1. Root Check
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[ERROR] Dieses Skript muss mit root-Rechten ausgeführt werden (sudo bash).${NC}"
   exit 1
fi

# 2. Token Parameter parsen oder sicher generieren
AGENT_TOKEN=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --token=*)
      AGENT_TOKEN="${1#*=}"
      shift
      ;;
    --token)
      AGENT_TOKEN="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ -z "$AGENT_TOKEN" ]]; then
  # 32-Zeichen hexadezimales Token generieren
  AGENT_TOKEN=$(openssl rand -hex 16 2>/dev/null || tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 32)
  echo -e "${YELLOW}[INFO] Kein Token angegeben. Sicheres Token automatisch generiert.${NC}"
fi

# 3. System-Updates durchführen
echo -e "\n${BLUE}[1/5] Führe System-Aktualisierungen durch ...${NC}"
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -q

# 4. Sicherheits- und Basispakete installieren
echo -e "\n${BLUE}[2/5] Installiere Sicherheits- & Verwaltungstools ...${NC}"
DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
    curl \
    ca-certificates \
    gnupg \
    ufw \
    fail2ban \
    unattended-upgrades \
    qemu-guest-agent \
    htop

# Automatische Sicherheitsupdates aktivieren
echo -e "${CYAN}→ Aktiviere automatische Sicherheitsupdates (unattended-upgrades) ...${NC}"
echo 'APT::Periodic::Update-Package-Lists "1";' > /etc/apt/apt.conf.d/20auto-upgrades
echo 'APT::Periodic::Unattended-Upgrade "1";' >> /etc/apt/apt.conf.d/20auto-upgrades
systemctl enable unattended-upgrades --now 2>/dev/null || true
systemctl enable fail2ban --now 2>/dev/null || true
systemctl enable qemu-guest-agent --now 2>/dev/null || true

# 5. UFW Firewall absichern
echo -e "\n${BLUE}[3/5] Konfiguriere UFW Firewall ...${NC}"
ufw default deny incoming 2>/dev/null || true
ufw default allow outgoing 2>/dev/null || true
ufw allow 22/tcp comment 'SSH' 2>/dev/null || true
ufw allow 80/tcp comment 'HTTP Web' 2>/dev/null || true
ufw allow 443/tcp comment 'HTTPS Web' 2>/dev/null || true
ufw allow 8089/tcp comment 'Lars IT Monitoring Agent' 2>/dev/null || true
echo "y" | ufw enable 2>/dev/null || true

# 6. Docker prüfen & ggf. installieren
echo -e "\n${BLUE}[4/5] Prüfe Docker-Installation ...${NC}"
if ! command -v docker &> /dev/null; then
    echo -e "${CYAN}→ Docker nicht gefunden. Installiere offizielle Docker Engine ...${NC}"
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
    systemctl enable docker --now
else
    echo -e "${GREEN}✓ Docker ist bereits installiert.${NC}"
fi

# 7. Lars IT Monitoring Agent einrichten
echo -e "\n${BLUE}[5/5] Richte Lars IT Monitoring Agent ein ...${NC}"
AGENT_DIR="/opt/lars-it-agent"
mkdir -p "$AGENT_DIR"

cat << 'EOF' > "$AGENT_DIR/agent.py"
#!/usr/bin/env python3
import os
import time
import json
import socket
import platform
import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler

AGENT_PORT = int(os.environ.get("AGENT_PORT", 8089))
AGENT_TOKEN = os.environ.get("AGENT_TOKEN", "").strip()

PROC_DIR = "/host/proc" if os.path.isdir("/host/proc") else "/proc"
ROOT_DIR = "/host/root" if os.path.isdir("/host/root") else "/"

def get_cpu_times():
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
    sample1 = get_cpu_times()
    if not sample1:
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
    return {
        "total_mb": round(total_kb / 1024.0, 1),
        "used_mb": round(used_kb / 1024.0, 1),
        "total_gb": round(total_kb / (1024.0 * 1024.0), 2),
        "used_gb": round(used_kb / (1024.0 * 1024.0), 2),
        "percent": round((used_kb / total_kb * 100.0), 1) if total_kb > 0 else 0.0
    }

def get_disk_info():
    try:
        stat = os.statvfs(ROOT_DIR)
        total_b = stat.f_blocks * stat.f_frsize
        avail_b = stat.f_bavail * stat.f_frsize
        used_b = total_b - avail_b
        return {
            "total_gb": round(total_b / (1024.0 ** 3), 1),
            "used_gb": round(used_b / (1024.0 ** 3), 1),
            "percent": round((used_b / total_b * 100.0), 1) if total_b > 0 else 0.0
        }
    except Exception:
        return {"total_gb": 0.0, "used_gb": 0.0, "percent": 0.0}

def get_uptime_info():
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
    return {"seconds": seconds, "text": text}

def get_hostname():
    hostname_file = os.path.join(PROC_DIR, "sys/kernel/hostname")
    if os.path.isfile(hostname_file):
        try:
            with open(hostname_file, "r") as f:
                return f.read().strip()
        except Exception:
            pass
    return platform.node() or socket.gethostname()

def get_services_info():
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
    try:
        pids = [d for d in os.listdir(PROC_DIR) if d.isdigit()]
        return {"count": len(pids), "label": "Dienste"}
    except Exception:
        return {"count": 0, "label": "Dienste"}

class MetricsHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def _is_authorized(self):
        if not AGENT_TOKEN:
            return True
        auth_header = self.headers.get("Authorization", "")
        if auth_header.startswith("Bearer ") and auth_header[7:].strip() == AGENT_TOKEN:
            return True
        if self.headers.get("X-Agent-Token", "").strip() == AGENT_TOKEN:
            return True
        if "?" in self.path:
            query = self.path.split("?", 1)[1]
            for param in query.split("&"):
                if param.startswith("token=") and param[6:].strip() == AGENT_TOKEN:
                    return True
        return False

    def do_GET(self):
        if self.path in ("/health", "/ping"):
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"ok","service":"lars-it-vps-agent"}\n')
            return

        if not self._is_authorized():
            self.send_response(401)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"error":"unauthorized","message":"Invalid or missing Agent-Token"}\n')
            return

        cpu = get_cpu_usage()
        mem = get_memory_info()
        disk = get_disk_info()
        uptime = get_uptime_info()
        srv = get_services_info()
        cores = os.cpu_count() or 1
        load = [round(x, 2) for x in os.getloadavg()] if hasattr(os, "getloadavg") else [0.0, 0.0, 0.0]

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
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    httpd.server_close()

if __name__ == "__main__":
    run()
EOF

cat << 'EOF' > "$AGENT_DIR/Dockerfile"
FROM python:3.11-alpine
WORKDIR /app
COPY agent.py /app/agent.py
ENV PYTHONUNBUFFERED=1 AGENT_PORT=8089
EXPOSE 8089
CMD ["python", "agent.py"]
EOF

cat << EOF > "$AGENT_DIR/docker-compose.yml"
services:
  agent:
    build: .
    image: lars-it-agent:latest
    container_name: lars_it_agent
    restart: unless-stopped
    ports:
      - "8089:8089"
    environment:
      - AGENT_PORT=8089
      - AGENT_TOKEN=${AGENT_TOKEN}
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/host/root:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
    read_only: true
    tmpfs:
      - /tmp
EOF

cat << EOF > "$AGENT_DIR/.env"
AGENT_TOKEN=${AGENT_TOKEN}
EOF

# Agent Container starten / neu starten
cd "$AGENT_DIR"
docker compose down 2>/dev/null || true
docker compose up -d --build

# Funktionsprüfung
sleep 2
HEALTH_CHECK=$(curl -s http://127.0.0.1:8089/health || echo "FAILED")

# Ermittle öffentliche IP
PUBLIC_IP=$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')

echo -e "\n${GREEN}==============================================================================${NC}"
echo -e "${GREEN}   ✓ Managed Server Onboarding erfolgreich abgeschlossen!                   ${NC}"
echo -e "${GREEN}==============================================================================${NC}"
echo -e "  • Server-IP:        ${CYAN}${PUBLIC_IP}${NC}"
echo -e "  • Agent-Port:       ${CYAN}8089${NC}"
echo -e "  • Agent-Status:     ${GREEN}${HEALTH_CHECK}${NC}"
echo -e "  • Monitoring-Token: ${YELLOW}${AGENT_TOKEN}${NC}"
echo -e "------------------------------------------------------------------------------"
echo -e "  Hinterlege dieses Token jetzt im ${CYAN}Lars IT Kundenportal${NC} beim Vertrag dieses"
echo -e "  Servers unter 'Monitoring-Token' und aktiviere die Checkbox."
echo -e "${GREEN}==============================================================================${NC}\n"
