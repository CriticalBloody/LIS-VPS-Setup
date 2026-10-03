# Lars IT Solutions — Managed VPS Onboarding & Monitoring Setup

> **Repository:** `https://github.com/CriticalBloody/LIS-VPS-Setup`  
> **Einsatzzweck:** Automatisches System-Update, Sicherheits-Härtung (UFW, fail2ban, unattended-upgrades), Docker-Installation und Start des schlanken Lars IT Telemetrie-Agenten auf Kunden- und Managed-Servern.

---

## 🚀 Schnellstart auf einem frischen Ubuntu / Debian VPS

Verbinde dich per SSH mit dem Ziel-Server und führe diesen Befehl aus:

```bash
curl -sSL https://raw.githubusercontent.com/CriticalBloody/LIS-VPS-Setup/main/install.sh | sudo bash
```

### Mit eigenem Token (z. B. aus dem Lars IT Portal generiert):

```bash
curl -sSL https://raw.githubusercontent.com/CriticalBloody/LIS-VPS-Setup/main/install.sh | sudo bash -s -- --token="DEIN_GEHEIMES_TOKEN"
```

---

## 🛠 Was das Skript automatisch erledigt:

1. **System-Updates:** `apt-get update && apt-get -y upgrade`
2. **Sicherheits-Tools:** Installiert `ufw`, `fail2ban`, `unattended-upgrades`, `qemu-guest-agent`, `htop`.
3. **Automatisches Patching:** Tägliche automatische Sicherheits-Updates via `unattended-upgrades`.
4. **Firewall (UFW):** Schließt alle Ports außer `22` (SSH), `80` (HTTP), `443` (HTTPS) und `8089` (Agent).
5. **Docker Engine:** Installiert offizielle Docker Engine, falls noch nicht vorhanden.
6. **Lars IT Agent:**
   - Erstellt `/opt/lars-it-agent`
   - Startet isolierten Docker-Container `lars_it_agent` (~12 MB RAM)
   - Gibt CPU-, RAM-, SSD- und echte Linux-Kernel-Uptime sicher als JSON zurück
   - Geschützt via Bearer Token Authentifizierung

---

## 🔒 Datenschutz & Sicherheit

Der Agent liest ausschließlich hardwarebezogene Telemetriedaten (`/proc/stat`, `/proc/meminfo`, `/proc/uptime`, `statvfs('/')`) über ein read-only Volume (`:ro`) aus.  
**Es werden keinerlei Kundendaten, Passwörter, Dateien oder Webseiten-Inhalte ausgelesen.**

---

## 📦 Dateien im Repository

- `install.sh`: Das All-in-One Installationsskript
- `agent.py`: Schlanker, dependency-freier Python 3 Telemetrie-Webservice
- `Dockerfile`: Minimales Alpine-Docker-Image
- `docker-compose.yml`: Compose-Definition für `/opt/lars-it-agent`
