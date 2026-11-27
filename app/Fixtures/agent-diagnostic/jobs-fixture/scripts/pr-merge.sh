#!/bin/bash
# Fixture (redacted): a scheduled PR merger the audit must name by line.
# Line 5 merges pull requests unattended; line 6 calls a path that does not exist.
set -u
gh pr merge --auto --squash --repo fixture-org/fixture-repo
/usr/local/bin/fixture-report-uploader --since 24h
