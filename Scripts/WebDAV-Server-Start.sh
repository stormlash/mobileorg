#!/bin/sh
# Start the runner-native WebDAV fixture used by WebDavTests.
#
# Replaces the former Docker-based server (phylor/webdav-ssl), which GitHub
# macOS runners cannot host: builds the tiny Go WebDAV server in
# Tools/tinydav (vendored dependencies, no network pulls) and launches it
# against the fixture content with the fixture credentials.
#
# Safe to call repeatedly — including from the "All Tests" scheme pre-action
# after CI already started the fixture: a live server is reused.
#
# Self-locating (works from any cwd and from Xcode scheme pre-actions, which
# invoke it via "$SRCROOT/Scripts/WebDAV-Server-Start.sh").

set -e

repoRoot=$(cd "$(dirname "$0")/.." && pwd)
toolDir="$repoRoot/Tools/tinydav"
fixture="$repoRoot/MobileOrgTests/Resources/WebDavTests"
host=mobileOrgWebDav.schnuddelhuddel.de
port=32773
user=schnuddelhuddel
password=schnuddelhuddel
pidfile=/tmp/mobileorg-tinydav.pid
logfile=/tmp/mobileorg-tinydav.log

# The tests connect to $host:$port; make that resolve to loopback when it
# does not already (GitHub macOS runners have passwordless sudo).
if ! grep -q "[[:space:]]$host" /etc/hosts 2>/dev/null; then
  if command -v sudo >/dev/null 2>&1; then
    echo "Adding 127.0.0.1 $host to /etc/hosts"
    echo "127.0.0.1 $host" | sudo tee -a /etc/hosts >/dev/null
  else
    echo "warning: no sudo available to add $host to /etc/hosts; tests may not connect" >&2
  fi
fi

if curl -k -s -o /dev/null --user "$user:$password" "https://$host:$port/"; then
  echo "WebDAV fixture already running at https://$host:$port — reusing it"
  exit 0
fi

if ! command -v go >/dev/null 2>&1; then
  for candidate in /usr/local/go/bin /opt/homebrew/bin; do
    if [ -x "$candidate/go" ]; then
      PATH="$candidate:$PATH"
      export PATH
      break
    fi
  done
fi
if ! command -v go >/dev/null 2>&1; then
  echo "error: the Go toolchain is required to build the WebDAV fixture (see Tools/tinydav/README.md)" >&2
  exit 1
fi

mkdir -p "$toolDir/bin"
echo "Building the WebDAV fixture server (Tools/tinydav)"
( cd "$toolDir" && go build -mod=vendor -o bin/tinydav . )

# Fresh throwaway certificate per launch. The certificate tracked in
# MobileOrgTests/Resources/WebDavTests/certs is self-signed AND long expired
# (2018); a modern URLSession may decline to let the app's trust-anything
# challenge handler override an expired trust evaluation, so we no longer
# rely on it. The app's challenge handler accepts any server certificate,
# and the client trusts nothing here anyway.
certDir=$(mktemp -d /tmp/mobileorg-tinydav-certs.XXXXXX)
if ! openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
     -keyout "$certDir/web.key" -out "$certDir/web.crt" \
     -subj "/CN=$host" >/dev/null 2>&1; then
  echo "error: openssl is required to generate the fixture TLS certificate" >&2
  exit 1
fi

echo "Starting WebDAV fixture on https://$host:$port"
"$toolDir/bin/tinydav" \
  -root "$fixture/content" \
  -port "$port" \
  -user "$user" \
  -password "$password" \
  -tls-cert "$certDir/web.crt" \
  -tls-key "$certDir/web.key" \
  > "$logfile" 2>&1 &
echo $! > "$pidfile"

# Wait until it answers (or surface why it did not come up).
tries=0
while [ $tries -lt 20 ]; do
  if curl -k -s -o /dev/null --user "$user:$password" "https://$host:$port/"; then
    echo "WebDAV fixture ready (pid $(cat "$pidfile"), log $logfile)"
    exit 0
  fi
  tries=$((tries + 1))
  sleep 0.5
done

echo "error: WebDAV fixture did not come up; log follows:" >&2
cat "$logfile" >&2 || true
exit 1
