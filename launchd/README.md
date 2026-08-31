# launchd — ForteL2 Mac mini jobs

Checked-in LaunchAgents for the operator Mac mini. They execute a **pinned clone** of `main` at `/Users/steveforte/fortel2-agents`, not the mutable `~/ForteL2` checkout (D-0113 Finding 2). Parallel workers check branches out of `~/ForteL2` at will; a stale or broken branch there would silently change overnight sleep/wake.

Deploy / update that clone with `./scripts/deploy-agents.sh` (fast-forward-only; refuses dirty / diverged / not-main / wrong origin). `.env.sepolia` in the pinned tree is a symlink back to the dev checkout — one source of secrets. `data/` is also a symlink so `refresh_health.sh` (writes repo-relative `data/`) and `alert-watch.sh` (reads `$FORTEL2_ROOT/data` after the env file sets `FORTEL2_ROOT` to the checkout) share the same files. The pinned tree does **not** self-update; agents never refuse-if-not-main (a fail-closed guard at 03:00 is worse than the hazard).

User agents only run while that user session is logged in (auto-login on the mini is fine).

| Label | When (local) | What |
|---|---|---|
| `com.steve.fortel2-health` | load + daily **05:00** | `refresh_health.sh` → `data/pipeline-health.json` |
| `com.steve.fortel2-sleep` | daily **23:45** | `run_dev_sleep.sh` → Sepolia `dev-sleep sleep` |
| `com.steve.fortel2-wake` | daily **03:00** | `run_dev_wake.sh` → Sepolia `dev-sleep wake` |
| `com.steve.fortel2-resolve-games` | load + hourly at **:00** | `resolve-games-sepolia.sh --execute` (L1 bond recovery; runs through the sleep window) |
| `com.steve.fortel2-alerts` | load + hourly at **:30** | `alert-watch.sh` |

Checked-in plists under `launchd/` are the **source of truth**. Editing a plist (or copying an updated one into `~/Library/LaunchAgents/`) does nothing until you `bootout` + `bootstrap` that agent — launchd keeps the previously loaded job (H4-004). Run `./scripts/check-launchd.sh` to verify installed agents match the repo schedule and script paths, and that the pinned tree exists, is this repo, is on `main`, and is clean (read-only; it never mutates launchd state). A host still pointing at `~/ForteL2` is **FAIL** (half-migrated). The same script also reports the **system** Cloudflare tunnel daemon (`com.cloudflare.cloudflared`: plist present/absent, `launchctl print system/…` state and last exit code). Plist absent is informational, not a FAIL. That section is read-only (no `gui/$UID`, no sudo, no restart).

**Logs** go to `~/Library/Logs/fortel2-{health,sleep,wake,resolve-games,alerts}.{out,err}.log` (not repo `data/`).  
launchd opens those paths *before* starting the script, so the parent directory must already exist — `~/Library/Logs` always does on macOS; gitignored `data/` does not on a fresh clone.

Sleep/wake stop and start the **Mac** stack only. They do **not** Suspend Render or pause QuickNode — do those in the dashboards when you want zero credit burn while remote. They also do **not** stop the dashboard-managed `cloudflared` system LaunchDaemon: the tunnel stays up while the write-filter origin goes dark for 23:45–03:00 (D-0034 / D-0035).

**Cloudflare tunnel (D-0035):** the live write tunnel is **dashboard-managed** (`SuperForteL2_mini`, Healthy on `supermini.local`) as a system LaunchDaemon at `/Library/LaunchDaemons/com.cloudflare.cloudflared.plist`. Do **not** run a user LaunchAgent `cloudflared` — a second process fights the dashboard connector. The manual yaml path (`scripts/08-run-cloudflared-write.sh` + `config/cloudflared-write.yml`) exists only if you retire the dashboard connector.

## Install / reload

Wrappers (`run_dev_sleep.sh`, `run_dev_wake.sh`, `refresh_health.sh`) `cd "$(dirname "$0")"`, so they run from the pinned tree without edits. `scripts/dev-sleep.sh` and `scripts/*-sepolia.sh` resolve the repo via `lib.sh` (`FORTEL2_ROOT` from the symlinked `.env.sepolia`).

The installed **wake** plist is wrapped by LaunchControl `fdautil exec`. A blind `cp` of the repo template drops that wrapper; the failure mode is silent (job "ran" and did nothing). Patch paths in place for wake; `cp` the others.

```bash
# 1. Create / fast-forward the pinned clone; symlink secrets.
./scripts/deploy-agents.sh

# 2. Copy templates except wake (wake keeps LaunchControl fdautil).
cp /Users/steveforte/fortel2-agents/launchd/com.steve.fortel2-health.plist \
   /Users/steveforte/fortel2-agents/launchd/com.steve.fortel2-sleep.plist \
   /Users/steveforte/fortel2-agents/launchd/com.steve.fortel2-alerts.plist \
   /Users/steveforte/fortel2-agents/launchd/com.steve.fortel2-resolve-games.plist \
   ~/Library/LaunchAgents/

# Wake: substitute the checkout path only. Do not cp — that drops fdautil.
sed -i '' 's|/Users/steveforte/ForteL2|/Users/steveforte/fortel2-agents|g' \
  ~/Library/LaunchAgents/com.steve.fortel2-wake.plist

# 3. Reload every job (file copy is not enough — H4-004).
UID_GUI="$(id -u)"
for label in fortel2-health fortel2-sleep fortel2-wake fortel2-resolve-games fortel2-alerts; do
  plist="$HOME/Library/LaunchAgents/com.steve.${label}.plist"
  launchctl bootout "gui/${UID_GUI}" "$plist" 2>/dev/null || true
  launchctl bootstrap "gui/${UID_GUI}" "$plist"
done

# 4. Confirm loaded + audit (must PASS pinned tree; must not mention ~/ForteL2).
./scripts/check-launchd.sh
launchctl print "gui/${UID_GUI}/com.steve.fortel2-sleep" | head -20
launchctl print "gui/${UID_GUI}/com.steve.fortel2-wake" | head -20
launchctl print "gui/${UID_GUI}/com.steve.fortel2-resolve-games" | head -20
```

Change `Hour` / `Minute` in the plists if you want different local times, then re-copy (wake: re-patch paths, keep fdautil) and re-bootstrap.

## Manual kick / unload

```bash
UID_GUI="$(id -u)"
# run once now (does not change the schedule)
launchctl kickstart -k "gui/${UID_GUI}/com.steve.fortel2-sleep"
launchctl kickstart -k "gui/${UID_GUI}/com.steve.fortel2-wake"
launchctl kickstart -k "gui/${UID_GUI}/com.steve.fortel2-resolve-games"

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

That `data/` is `$DATA_DIR` from the symlinked `.env.sepolia` (the Sepolia datadir, not a second copy under the pinned tree).
