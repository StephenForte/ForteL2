# launchd — ForteL2 Mac mini jobs

Checked-in LaunchAgents for the operator Mac mini (`/Users/steveforte/ForteL2`).  
User agents only run while that user session is logged in (auto-login on the mini is fine).

| Label | When (local) | What |
|---|---|---|
| `com.steve.fortel2-health` | load + daily **05:05** | `refresh_health.sh` → `data/pipeline-health.json` |
| `com.steve.fortel2-sleep` | daily **23:45** | `run_dev_sleep.sh` → Sepolia `dev-sleep sleep` |
| `com.steve.fortel2-wake` | daily **03:00** | `run_dev_wake.sh` → Sepolia `dev-sleep wake` |

Checked-in plists under `launchd/` are the **source of truth**. Editing a plist (or copying an updated one into `~/Library/LaunchAgents/`) does nothing until you `bootout` + `bootstrap` that agent — launchd keeps the previously loaded job (H4-004). Run `./scripts/check-launchd.sh` to verify installed agents match the repo schedule and script paths (read-only; it never mutates launchd state).

**Logs** go to `~/Library/Logs/fortel2-{health,sleep,wake}.{out,err}.log` (not repo `data/`).  
launchd opens those paths *before* starting the script, so the parent directory must already exist — `~/Library/Logs` always does on macOS; gitignored `data/` does not on a fresh clone.

Sleep/wake stop and start the **Mac** stack only. They do **not** Suspend Render or pause QuickNode — do those in the dashboards when you want zero credit burn while remote.

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

# confirm loaded
launchctl print "gui/${UID_GUI}/com.steve.fortel2-sleep" | head -20
launchctl print "gui/${UID_GUI}/com.steve.fortel2-wake" | head -20
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
```

## Replace a one-off crontab

If you previously used `crontab` for `dev-sleep`, remove those lines (`crontab -e`) so you do not double-stop / double-start, then install the LaunchAgents above.

## Health snapshot output

```bash
ls -la data/pipeline-health.json
```
