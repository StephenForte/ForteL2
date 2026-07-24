# launchd — pipeline health snapshot

Job `com.steve.fortel2-health` runs `refresh_health.sh` at load and daily at 05:05.

**Logs** go to `~/Library/Logs/fortel2-health.{out,err}.log` (not repo `data/`).  
launchd opens those paths *before* starting the script, so the parent directory must already exist — `~/Library/Logs` always does on macOS; gitignored `data/` does not on a fresh clone.

```bash
# install / reload
cp launchd/com.steve.fortel2-health.plist ~/Library/LaunchAgents/
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.steve.fortel2-health.plist 2>/dev/null || true
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.steve.fortel2-health.plist

# snapshot output (created by the script)
ls -la data/pipeline-health.json
```
