#!/bin/bash
# Fixture (redacted): retypes the morning report with keystroke injection, line 4.
set -u
osascript -e 'tell application "System Events" to keystroke "r" using command down'
