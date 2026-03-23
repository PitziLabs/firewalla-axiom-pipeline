# firewalla-axiom-pipeline

Ship DNS and connection flow logs from a Firewalla Gold SE to [Axiom](https://axiom.co) for long-term retention, search, and dashboarding — at zero recurring cost.

## What this does

Your Firewalla app shows you what domains each device visits, but the data rotates off the device quickly. This pipeline captures that same data (Zeek DNS and connection logs) and ships it to Axiom's cloud, giving you:

- **30-day searchable history** of every DNS query on your network
- **Per-device drill-down** dashboards (select a device, see its domains)
- **Device name resolution** via automated Redis inventory export
- **Firmware-update resilience** using Firewalla's `post_main.d` persistence
- **~50 MB RAM overhead** on the Firewalla

Total cost: **$0/month** (Axiom free tier: 500 GB/month, 30-day retention)

## Architecture

![Pipeline Architecture](docs/architecture.svg)


## Prerequisites

- **Firewalla Gold SE** (Gold Pro or Purple SE should also work — untested)
- **SSH access** enabled (Firewalla app → Settings → Advanced → SSH)
- **Docker** started on the Firewalla (`sudo systemctl start docker && sudo systemctl enable docker`)
- **Axiom account** (free at [app.axiom.co](https://app.axiom.co))

## Quick start

### 1. Create Axiom datasets and API token

1. Sign up at [app.axiom.co](https://app.axiom.co)
2. Create two datasets:
   - `firewalla` (or your preferred name — for log events)
   - `firewalla-devices` (for the device lookup table)
3. Go to **Settings → API Tokens → New API Token**
4. Name it `firewalla-ingest`, grant **Ingest** permission, copy the token

### 2. Clone this repo and configure

```bash
git clone https://github.com/cpitzi/firewalla-axiom-pipeline.git
cd firewalla-axiom-pipeline

# Create your local env file (not committed to git)
cp env.example .env
nano .env
# Fill in your Axiom dataset names and API token
```

### 3. Deploy to Firewalla

```bash
# Replace with your Firewalla's IP address
export FW_IP=192.168.1.1

# Copy config files to Firewalla's persistent directory
scp fluent-bit/fluent-bit.conf pi@${FW_IP}:/home/pi/.firewalla/config/
scp fluent-bit/parsers.conf pi@${FW_IP}:/home/pi/.firewalla/config/
scp scripts/device_lookup_export.sh pi@${FW_IP}:/home/pi/.firewalla/config/
scp scripts/start_log_shipping.sh pi@${FW_IP}:/home/pi/.firewalla/config/post_main.d/
scp cron/user_crontab pi@${FW_IP}:/home/pi/.firewalla/config/
scp .env pi@${FW_IP}:/home/pi/.firewalla/config/log_shipping.env
```

### 4. Start it up

```bash
ssh pi@${FW_IP}

# Make scripts executable
chmod +x /home/pi/.firewalla/config/post_main.d/start_log_shipping.sh
chmod +x /home/pi/.firewalla/config/device_lookup_export.sh

# Start the log pipeline
sudo /home/pi/.firewalla/config/post_main.d/start_log_shipping.sh

# Export device inventory
sudo /home/pi/.firewalla/config/device_lookup_export.sh

# Install the cron for hourly device exports
crontab /home/pi/.firewalla/config/user_crontab
```

### 5. Verify

```bash
# Check Fluent Bit is healthy
sudo docker logs --tail 20 fluent-bit-axiom

# Should see no errors — check Axiom Stream view for incoming events
```

## File layout

```
firewalla-axiom-pipeline/
├── README.md
├── LICENSE
├── env.example                          # Template for credentials
├── fluent-bit/
│   ├── fluent-bit.conf                  # Main Fluent Bit configuration
│   └── parsers.conf                     # Zeek log parser definitions
├── scripts/
│   ├── start_log_shipping.sh            # Docker bootstrap (post_main.d)
│   └── device_lookup_export.sh          # Redis → Axiom device inventory
├── cron/
│   └── user_crontab                     # Persistent cron jobs
├── dashboards/
│   └── axiom-queries.md                 # Saved APL queries for Axiom
└── deploy.sh                            # One-command deploy script
```

## Axiom dashboard setup

See [dashboards/axiom-queries.md](dashboards/axiom-queries.md) for the complete set of APL queries, including:

- Top domains across all devices
- Per-device domain breakdown (with device name resolution)
- DNS activity over time
- Dashboard filter bar configuration for device drill-down

## Firewalla internals

This pipeline relies on the following Firewalla data sources:

| Source | Path | Contents |
|--------|------|----------|
| Zeek DNS log | `/bspool/manager/dns.log` | Every DNS query: source IP, domain, query type, response |
| Zeek conn log | `/bspool/manager/conn.log` | Every connection: source, dest, port, bytes, duration |
| ACL alarm log | `/alog/acl-alarm.log` | Blocked connections from Firewalla rules |
| Redis device inventory | `redis-cli hgetall host:mac:*` | IP, MAC, device name, DHCP name, interface |

### Persistence across firmware updates

Firewalla uses an overlay filesystem — most changes are wiped on reboot or firmware update. The only reliable persistent paths are under `/home/pi/.firewalla/config/`. Scripts in `post_main.d/` run automatically after every boot and firmware update. Docker containers with `--restart always` survive normal reboots; the `post_main.d` script handles the edge case of a full overlay reset.

### Zeek log format

On recent firmware, Zeek logs are written as **JSON** (not TSV). Key fields in `dns.log`:

- `id.orig_h` — source device IP
- `id.resp_h` — DNS server IP
- `query` — the domain name queried
- `qtype_name` — query type (A, AAAA, CNAME, etc.)
- `answers` — DNS response

Note: field names contain dots (e.g., `id.orig_h`), which requires bracket notation in APL: `parsed["id.orig_h"]`.

## Troubleshooting

### Data stopped flowing

```bash
# Check container status
sudo docker ps -a

# Check for errors
sudo docker logs --tail 50 fluent-bit-axiom

# Restart the container
sudo docker restart fluent-bit-axiom
```

Common causes:
- **HTTP 503 errors**: Axiom outage — restart the container once Axiom is back
- **Container missing**: Firmware update wiped Docker — run `start_log_shipping.sh`
- **No log files**: Check `ls -la /bspool/manager/dns.log` exists
- **/bspool full**: See below — this is the most common issue on busy networks

### /bspool tmpfs full (the #1 gotcha)

Zeek writes to `/bspool`, a **30 MB tmpfs** (RAM disk). Every 3 minutes, Zeek rotates active logs into timestamped copies like `dns.2026-03-11-21-24-00.log`. On a busy network (90+ devices), these rotated files can fill the tmpfs in hours. When it hits 100%, Zeek stops writing entirely and your pipeline goes silent.

Symptoms:
- `df -k /bspool/manager/` shows 100% usage
- `dns.log` has stale timestamps (days old)
- Fluent Bit is running but shipping no new data

Fix:
```bash
# Delete rotated logs
sudo rm /bspool/manager/*.2026-*.log

# Reboot to restart Zeek cleanly (don't use zeekctl directly)
sudo reboot
```

Prevention: The `user_crontab` in this repo includes a cleanup job that runs every 5 minutes, deleting rotated log files older than 5 minutes. Fluent Bit reads from active logs in real time and never needs the rotated copies. If you deployed before this fix was added, update your crontab:

```bash
scp cron/user_crontab pi@<firewalla-ip>:/home/pi/.firewalla/config/
ssh pi@<firewalla-ip> "crontab /home/pi/.firewalla/config/user_crontab"
```

**Important**: Never restart Zeek via `zeekctl restart` on a Firewalla — it doesn't work reliably due to the overlay filesystem. Always use `sudo reboot` instead.

### Container won't start after firmware update

```bash
sudo /home/pi/.firewalla/config/post_main.d/start_log_shipping.sh
```

### Fluent Bit running but no data flowing (stale position tracker)

Zeek logs live on a tmpfs that's recreated on every reboot. Fluent Bit tracks
its read position in `.db` files so it doesn't re-read old data. After a reboot,
those position files point to byte offsets in files that no longer exist, so
Fluent Bit silently reads nothing.

The `start_log_shipping.sh` script now automatically wipes the position tracker
on every startup, so this should be self-healing. If you somehow hit it anyway:

```bash
sudo docker rm -f fluent-bit-axiom
sudo rm -rf /home/pi/.firewalla/config/fluent-bit-data/*
sudo /home/pi/.firewalla/config/post_main.d/start_log_shipping.sh
```

### Check RAM usage

```bash
sudo docker stats fluent-bit-axiom --no-stream
```

### Verify Zeek logs are being written

```bash
tail -5 /bspool/manager/dns.log
```

## Contributing

This was built for a specific home network setup (Firewalla Gold SE → Axiom). PRs welcome for:

- Support for other Firewalla models (Purple SE, Gold Pro)
- Additional log sources (ssl.log, http.log, files.log)
- Grafana Cloud as an alternative destination
- IPv6 device name resolution
- Terraform/IaC for Axiom dataset and dashboard provisioning

## Related

- **[PitziLabs/setup-crostini-lab](https://github.com/PitziLabs/setup-crostini-lab)** — Chromebook bootstrap script for the same homelab environment
- **[cpitzi/setup-xubuntu-lab](https://github.com/cpitzi/setup-xubuntu-lab)** — Xubuntu VM workstation bootstrap (where the dashboards get built)
- **[PitziLabs/aws-lab-infra](https://github.com/PitziLabs/aws-lab-infra)** — Terraform AWS lab — same infrastructure-as-portfolio philosophy

## License

MIT License — see [LICENSE](LICENSE).

## Credits

Built iteratively with [Claude](https://claude.ai) (Anthropic) through multi-session pair-programming that included live debugging on the Firewalla over SSH, Fluent Bit container troubleshooting, Axiom APL query development, and the discovery that Zeek lowercases MACs while Redis stores them uppercase.

## Acknowledgments

- [mbierman's syslog forwarding gist](https://gist.github.com/mbierman/f3d184b65e0f4de6fa75a4a5d5145426) — the OG Firewalla log export reference
- [Firewalla open source repo](https://github.com/firewalla/firewalla) — for understanding the internal data model
- The Firewalla community forum regulars who've been asking for this since 2019
