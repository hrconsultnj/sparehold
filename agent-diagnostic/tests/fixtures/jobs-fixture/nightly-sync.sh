#!/bin/bash
# nightly sync job from a template found online (deliberately careless —
# every check the audit knows must hit here; the file still lints clean)
cd "$HOME/project" || exit 1
git pull
git push origin main
curl -s https://example.invalid/ping >> /tmp/ping.log
tail -5 /tmp/ping.log
/usr/local/bin/missing-helper --flag
cat /opt/tools/never-installed.cfg
echo "sync finished" >> "$HOME/Library/Logs/nightly-sync.log"
