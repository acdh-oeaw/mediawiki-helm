#!/usr/bin/env bash
set -euo pipefail
image=docker.io/library/mediawiki:1.43.11
docker run --rm -v "$PWD/.rendered:/checks:ro" "$image" php -l /checks/LocalSettings.php
docker run --rm -v "$PWD/.rendered:/checks:ro" "$image" php -l /checks/extra.php
id="$(docker run -d --read-only --user 33:33 --cap-drop ALL   --security-opt no-new-privileges --tmpfs /tmp:rw,mode=1777   -p 127.0.0.1::8080   -v "$PWD/.rendered/ports.conf:/etc/apache2/ports.conf:ro"   -v "$PWD/.rendered/vhost.conf:/etc/apache2/sites-enabled/000-default.conf:ro"   --entrypoint /bin/sh "$image" -ec '
    . /etc/apache2/envvars
    export APACHE_RUN_DIR=/tmp/apache2 APACHE_LOCK_DIR=/tmp/apache2
    export APACHE_PID_FILE=/tmp/apache2/apache2.pid
    mkdir -p "$APACHE_RUN_DIR"
    exec apache2 -DFOREGROUND')"
trap 'docker logs "$id"; docker rm -f "$id" >/dev/null' EXIT
port="$(docker port "$id" 8080/tcp | awk -F: '{print $NF}')"
for attempt in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${port}/resources/assets/mediawiki.png" -o /dev/null; then
    echo 'PASS: non-root, read-only Apache serves static assets on 8080'
    exit 0
  fi
  sleep 1
done
exit 1
