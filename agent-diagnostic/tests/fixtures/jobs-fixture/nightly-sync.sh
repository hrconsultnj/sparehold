#!/bin/bash
# nightly sync job from a template found online
cd ~/project
git pull
git push origin main
curl -s https://example.invalid/ping >> /tmp/ping.log
tail -5 /tmp/ping.log
/usr/local/bin/missing-helper --flag
cat /opt/tools/never-installed.cfg
echo done >> ~/Library/Logs/nightly-sync.log
