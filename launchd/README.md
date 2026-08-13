# launchd — ForteL2 Mac mini jobs

Checked-in LaunchAgents for the operator Mac mini (`/Users/steveforte/ForteL2`).  
User agents only run while that user session is logged in (auto-login on the mini is fine).

| Label | When (local) | What |
|---|---|---|
| `com.steve.fortel2-health` | load + daily **05:05** | `refresh_health.sh` → `data/pipeline-health.json` |
| `com.steve.fortel2-sleep` | daily **23:45** | `run_dev_sleep.sh` → Sepolia `dev-sleep sleep` |
| `com.steve.fortel2-wake` | daily **03:00** | `run_dev_wake.sh` → Sepolia `dev-sleep wake` |
| `com.steve.fortel2-cloudflared` | **KeepAlive** (login + always) | `scripts/08-run-cloudflared-write.sh` → `cloudflared` origin `http://127.0.0.1:9555` |

Checked-in plists under `launchd/` are the **source of truth**. Editing a plist (or copying an updated one into `~/Library/LaunchAgents/`) does nothing until you `bootout` + `bootstrap` that agent — launchd keeps the previously loaded job (H4-004). Run `./scripts/check-launchd.sh` to verify installed agents match the repo schedule and script paths (read-only; it never mutates launchd state).

**Logs** go to `~/Library/Logs/fortel2-{health,sleep,wake,cloudflared}.{out,err}.log` (not repo `data/`).  
launchd opens those paths *before* starting the script, so the parent directory must already exist — `~/Library/Logs` always does on macOS; gitignored `data/` does not on a fresh clone.

Sleep/wake stop and start the **Mac** stack only. They do **not** Suspend Render or pause QuickNode — do those in the dashboards when you want zero credit burn while remote. They also do **not** stop a dashboard-managed `cloudflared`: the tunnel stays up while the write-filter origin goes dark for 23:45–03:00 (D-0034 / D-0035).

**Live (2026-08-12):** the write tunnel is **dashboard-managed** (`SuperForteL2_mini`, Healthy on `supermini.local`). Do **not** bootstrap `com.steve.fortel2-cloudflared` while that connector is up — a second process fights it. The LaunchAgent path below is the optional locally-managed alternate after you stop the dashboard connector.

`com.steve.fortel2-cloudflared` requires a filled `config/cloudflared-write.yml` (copy from `config/cloudflared-write.yml.example`; gitignored; origin **must** be `http://127.0.0.1:9555`). Do not bootstrap it until placeholders are gone, or KeepAlive will restart-loop. Dashboard / Access steps: README “Authenticated Cloudflare tunnel”.

## Install / reload

```bash
# wrappers must be executable
chmod +x refresh_health.sh run_dev_sleep.sh run_dev_wake.sh

cp launchd/com.steve.fortel2-health.plist \
   launchd/com.steve.fortel2-sleep.plist \
   launchd/com.steve.fortel2-wake.plist \
   ~/Library/LaunchAgents/

UID_GUI="$(id -u)"
for label in fortel2-health fortel2-sleep fortel2-wake; do
  plist="$HOME/Library/LaunchAgents/com.steve.${label}.plist"
  launchctl bootout "gui/${UID_GUI}" "$plist" 2>/dev/null || true
  launchctl bootstrap "gui/${UID_GUI}" "$plist"
done

# Write-RPC tunnel — only if the dashboard connector is stopped, and only after
# config/cloudflared-write.yml has no REPLACE_WITH_ placeholders.
# ./scripts/08-run-cloudflared-write.sh --check-config   # must print OK origin http://127.0.0.1:9555
cp launchd/com.steve.fortel2-cloudflared.plist ~/Library/LaunchAgents/
launchctl bootout "gui/${UID_GUI}" "$HOME/Library/LaunchAgents/com.steve.fortel2-cloudflared.plist" 2>/dev/null || true
launchctl bootstrap "gui/${UID_GUI}" "$HOME/Library/LaunchAgents/com.steve.fortel2-cloudflared.plist"

# confirm loaded
launchctl print "gui/${UID_GUI}/com.steve.fortel2-sleep" | head -20
launchctl print "gui/${UID_GUI}/com.steve.fortel2-wake" | head -20
launchctl print "gui/${UID_GUI}/com.steve.fortel2-cloudflared" | head -20
```

Change `Hour` / `Minute` in the plists if you want different local times, then re-copy and re-bootstrap.

## Manual kick / unload

```bash
UID_GUI="$(id -u)"
# run once now (does not change the schedule)
launchctl kickstart -k "gui/${UID_GUI}/com.steve.fortel2-sleep"
launchctl kickstart -k "gui/${UID_GUI}/com.steve.fortel2-wake"

# leave stack up overnight (unload sleep only)
launchctl bootout "gui/${UID_GUI}" ~/Library/LaunchAgents/com.steve.fortel2-sleep.plist

# disable morning auto-start
launchctl bootout "gui/${UID_GUI}" ~/Library/LaunchAgents/com.steve.fortel2-wake.plist

# stop the write-RPC tunnel (rollback / revoke Access token separately)
launchctl bootout "gui/${UID_GUI}" ~/Library/LaunchAgents/com.steve.fortel2-cloudflared.plist
```

## Replace a one-off crontab

If you previously used `crontab` for `dev-sleep`, remove those lines (`crontab -e`) so you do not double-stop / double-start, then install the LaunchAgents above.

## Health snapshot output

```bash
ls -la data/pipeline-health.json
```
