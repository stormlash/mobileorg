#!/bin/sh
# Stop the runner-native WebDAV fixture started by WebDAV-Server-Start.sh.
# (Replaces the former Docker stop/rm cleanup.)

pidfile=/tmp/mobileorg-tinydav.pid

if [ -f "$pidfile" ]; then
  pid=$(cat "$pidfile")
  if kill "$pid" 2>/dev/null; then
    echo "WebDAV fixture (pid $pid) stopped"
  else
    echo "WebDAV fixture (pid $pid) was not running"
  fi
  rm -f "$pidfile"
else
  echo "No WebDAV fixture pidfile found — nothing to stop"
fi
