#!/usr/bin/env bash
# CI-only real installer test against disposable MariaDB; never uses cluster data.
set -euo pipefail
image=docker.io/library/mediawiki:1.43.11
network="mw-ci-${GITHUB_RUN_ID:-local}-$$"
db="$network-db"
web="$network-web"
cleanup() {
  docker container stop "$web" "$db" >/dev/null 2>&1 || true
  docker container remove "$web" "$db" >/dev/null 2>&1 || true
  docker network remove "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker network create "$network" >/dev/null
db_runtime=()
if [[ "${MARIADB_TEST_NONROOT:-false}" == true ]]; then
  db_runtime=(--user 999:999 --read-only --cap-drop ALL --security-opt no-new-privileges
    --tmpfs /var/lib/mysql:rw,uid=999,gid=999 --tmpfs /run/mysqld:rw,uid=999,gid=999
    --tmpfs /tmp:rw,mode=1777)
fi
docker run "${db_runtime[@]}" -d --name "$db" --network "$network" --network-alias db \
  -e MARIADB_ROOT_PASSWORD=ci-root-password -e MARIADB_DATABASE=wiki \
  -e MARIADB_USER=wiki -e MARIADB_PASSWORD=ci-db-password \
  "${MARIADB_TEST_IMAGE:-mariadb:12.3.3}" >/dev/null
ready=false
for attempt in $(seq 1 90); do
  if docker exec "$db" healthcheck.sh --connect --innodb_initialized; then ready=true; break; fi
  sleep 1
done
[[ "$ready" == true ]] || { docker logs "$db"; exit 1; }
helm template ci chart/mediawiki -f examples/ci.values.yaml \
  --set replicaCount=0,bootstrap.enabled=true,bootstrap.adminPassword=Ci-admin-password-123 \
  --set externalDatabase.host=db,externalDatabase.database=wiki,externalDatabase.user=wiki,externalDatabase.password=ci-db-password \
  --set mediawiki.name=IntegrationWiki --set localSettings.extensions='{Cite}' > .rendered/integration.yaml
python3 - <<'PY'
from pathlib import Path
import yaml,base64
out=Path('.integration');out.mkdir(exist_ok=True)
ds=[d for d in yaml.safe_load_all(Path('.rendered/integration.yaml').read_text()) if d]
secrets={d['metadata']['name']:d for d in ds if d['kind']=='Secret'}
for d in ds:
 if d['kind'] in ('Secret','ConfigMap'):
  target=out/d['metadata']['name'];target.mkdir(exist_ok=True)
  for k,v in d['data'].items():
   (target/k).write_bytes(base64.b64decode(v) if d['kind']=='Secret' else v.encode())
job=next(d for d in ds if d['kind']=='Job')
ctr=job['spec']['template']['spec']['containers'][0]
(out/'install.sh').write_text(ctr['args'][0])
env=[]
for e in ctr['env']:
 if 'value' in e: value=e['value']
 else:
  ref=e['valueFrom']['secretKeyRef'];value=base64.b64decode(secrets[ref['name']]['data'][ref['key']]).decode()
 env.append(e['name']+'='+str(value))
(out/'env').write_text('\n'.join(env)+'\n')
# The Job projects the admin Secret key as password.
(out/'ci-mediawiki-admin/password').write_bytes((out/'ci-mediawiki-admin/admin-password').read_bytes())
PY
common=(--rm --network "$network" --user 33:33 --read-only --cap-drop ALL \
  --security-opt no-new-privileges --tmpfs /tmp:rw,mode=1777 \
  --tmpfs /var/www/html/images:rw,uid=33,gid=33 \
  --env-file "$PWD/.integration/env" \
  -v "$PWD/.integration/ci-mediawiki-runtime:/etc/mediawiki-runtime:ro" \
  -v "$PWD/.integration/ci-mediawiki-settings:/etc/mediawiki:ro" \
  -v "$PWD/.integration/ci-mediawiki-security:/etc/mediawiki-security:ro" \
  -v "$PWD/.integration/ci-mediawiki-admin:/etc/mediawiki-admin:ro")
docker run "${common[@]}" --entrypoint /bin/sh "$image" -ec "$(cat .integration/install.sh)"
# A second install must stop before changing an existing database.
if docker run "${common[@]}" --entrypoint /bin/sh "$image" -ec "$(cat .integration/install.sh)" > .integration/retry.log 2>&1; then
  echo 'FAIL: installer accepted a nonempty DB' >&2; exit 1
fi
grep -q 'Database is not empty' .integration/retry.log
# Start the actual web runtime against the newly initialized DB.
docker run -d --name "$web" --network "$network" --user 33:33 --read-only \
  --cap-drop ALL --security-opt no-new-privileges --tmpfs /tmp:rw,mode=1777 \
  --tmpfs /var/www/html/images:rw,uid=33,gid=33 -p 127.0.0.1::8080 \
  --env-file "$PWD/.integration/env" \
  -v "$PWD/.integration/ci-mediawiki-runtime/LocalSettings.php:/var/www/html/LocalSettings.php:ro" \
  -v "$PWD/.integration/ci-mediawiki-runtime/ports.conf:/etc/apache2/ports.conf:ro" \
  -v "$PWD/.integration/ci-mediawiki-runtime/vhost.conf:/etc/apache2/sites-enabled/000-default.conf:ro" \
  -v "$PWD/.integration/ci-mediawiki-settings:/etc/mediawiki:ro" \
  -v "$PWD/.integration/ci-mediawiki-security:/etc/mediawiki-security:ro" \
  --entrypoint /bin/sh "$image" -ec '
    . /etc/apache2/envvars
    export APACHE_RUN_DIR=/tmp/apache2 APACHE_LOCK_DIR=/tmp/apache2
    export APACHE_PID_FILE=/tmp/apache2/apache2.pid
    mkdir -p "$APACHE_RUN_DIR"
    exec apache2 -DFOREGROUND' >/dev/null
port="$(docker port "$web" 8080/tcp | awk -F: '{print $NF}')"
for attempt in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:$port/api.php?action=query&meta=siteinfo&format=json" -o .integration/siteinfo.json; then
    if python3 -c 'import json; assert json.load(open(".integration/siteinfo.json"))["query"]["general"]["sitename"] == "IntegrationWiki"'; then
      echo 'PASS: fresh install, extension updater, nonempty DB rejection and live API on selected MariaDB image'
      exit 0
    fi
  fi
  sleep 1
done
docker logs "$web"
exit 1
