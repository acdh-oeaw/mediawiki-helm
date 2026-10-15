# mediawiki-helm

Chart **0.3.0**, MediaWiki **1.43.11 LTS**, Docker Official Image (Apache/PHP).
No Bitnami chart or commercial image dependency. Install via Helm or Rancher.
Choose a dedicated MariaDB server (`mariadb.enabled=true`) or an existing external
MariaDB/MySQL endpoint (`mariadb.enabled=false`, default). No separate LocalSettings.php file is needed.

## Two workflows

- **Completely new wiki:** initialize an empty database with `bootstrap.enabled`.
- **Existing wiki / Bitnami migration:** restore the database, transfer persistent
  data, translate old configuration to values, then run `migration.enabled`.
  Do NOT initialize a blank wiki first and then overwrite its database.

See examples/new-instance.values.yaml, examples/bitnami-import.values.yaml and
MIGRATION.md. Source and target data must be independent during the first test.

## Fresh installation

1. Choose examples/dedicated-mariadb.values.yaml to provision a standalone DB,
   or pre-create an empty external database/user and use examples/new-instance.values.yaml.
   Put credentials in a PRIVATE values file.
2. Generate two stable keys (`openssl rand -hex 32`, twice). Set security.secretKey
   and security.upgradeKey. They must remain unchanged on normal upgrades.
3. Copy examples/new-instance.values.yaml, replace placeholders and choose storage,
   hostname/TLS and administrator credentials. Initially replicas=0, bootstrap=true.
4. Install from source (or use the published chart in Rancher):

```bash
helm install wiki ./chart/mediawiki --create-namespace -n wiki -f my.private.yaml \
  --wait --wait-for-jobs --timeout 35m
kubectl get jobs -n wiki
kubectl logs -n wiki job/ACTUAL_INSTALL_JOB
```

5. After successful Job completion, edit the SAME values file: bootstrap.enabled=false,
   replicaCount=1, then upgrade. In Rancher use Apps > Installed Apps > Upgrade/Edit Values.

```bash
helm upgrade wiki ./chart/mediawiki -n wiki -f my.private.yaml --wait --timeout 10m
```

The installer refuses a database containing ANY tables. It writes initial schema
and admin account using the standard CLI installer, then runs the updater using
the values-generated configuration to initialize selected extension schemas.
Its temporary LocalSettings.php is discarded with the Job; runtime keys/config
come from values. Installation is not an automatic hook or a recurring init task.
Do not re-enable bootstrap after a successful installation.


## Database mode

| Setting | Behavior |
|---|---|
| mariadb.enabled: false | Use externalDatabase host/port/database/credentials; create no DB server or DB PVC |
| mariadb.enabled: true | Create one dedicated MariaDB StatefulSet, internal Service and DB PVC; ignore externalDatabase connection values |

Dedicated example (merge with the required wiki/security/bootstrap settings):

```yaml
mariadb:
  enabled: true
  image:
    repository: docker.io/library/mariadb
    tag: '11.4.13'
  auth:
    database: mediawiki
    username: mediawiki
    password: REPLACE_APP_DB_PASSWORD
    rootPassword: REPLACE_ROOT_PASSWORD
  persistence:
    size: 8Gi
```

External example:

```yaml
mariadb:
  enabled: false
externalDatabase:
  host: mariadb-maxscale.database.svc.cluster.local
  port: 3306
  database: mediawiki
  user: mediawiki
  password: REPLACE_DB_PASSWORD
```

The dedicated server uses the MariaDB Docker Official Image 11.4.13, separate from
MediaWiki. It creates the configured database and app user on FIRST initialization
of an empty DB volume. MediaWiki automatically receives the internal Service name
and app credentials (never root credentials). No operator, Galera or replication
is installed: this is one standalone DB, intended for an individual wiki.

mariadb.auth.existingSecret can provide database-user, database-password and
root-password instead of inline auth values. mariadb.auth.database still sets the
schema name. mariadb.persistence.existingClaim reuses a DB data PVC; storageClass,
size, resources, image/digest and scheduling can be configured independently.
Do not mount a Bitnami MEDIAWIKI files volume as a MariaDB datadir.

Initialization environment variables do NOT rotate users/passwords or create a new
schema on a previously initialized volume. Keep credentials stable; coordinate
SQL password changes with app and Secret changes. Dedicated DB data PVCs are kept
on uninstall; backups/restores remain the administrator's responsibility. Switching
mariadb.enabled on an existing release does NOT migrate its data and can stop the
old DB workload. Back up and transfer the DB explicitly before switching endpoints.
For imports choose a database version compatible with the source; importing a
MariaDB 12 dump into the default 11.4 server is not assumed to be supported. Set
mariadb.image.tag to an appropriate version (e.g. matching your source) first.

The DB runs as UID/GID 999 with writable datadir, /run/mysqld and /tmp, read-only
root filesystem and no elevated capabilities. Test CSI/fsGroup permissions on
existing volumes. Schema install/upgrade Jobs wait up to 600s for DB connectivity.
NetworkPolicy, when enabled, permits port 3306 only from this release's labeled
Pods in the same namespace; adjust it explicitly if another workload needs access.

## All LocalSettings variables in values.yaml

Any MediaWiki global can be assigned using its exact PHP name WITHOUT `$`:

```yaml
localSettings:
  variables:
    wgLanguageCode: de
    wgScriptPath: ''
    wgEnableUploads: true
    wgFileExtensions: [png, jpg, jpeg, pdf, svg]
    wgDefaultSkin: vector
    wgGroupPermissions:
      '*': {edit: false, createaccount: false}
      user: {edit: true}
    wgSMTP:
      host: smtp.example.org
      IDHost: wiki.example.org
      port: 25
      auth: false
  skins: [Vector]
  extensions: [Cite, ParserFunctions, WikiEditor]
  extraPhp: |
    // Optional trusted PHP for constants, expressions or incremental changes.
    $wgGroupPermissions['sysop']['editinterface'] = true;
    // require '/var/www/html/extensions/CustomExtension/settings.php';
```

Booleans/numbers/null/strings/nested maps and lists retain their types. Dollar signs,
quotes and newlines in string values are JSON data, not executable PHP.
`variables` assigns full values: arrays are replaced, not recursively merged into
MediaWiki defaults. Use extraPhp for incremental array changes or PHP constants
(e.g. CACHE_ACCEL), require statements and custom initialization functions.
Variables names must be PHP identifiers. No Helm tpl evaluation is performed.

Order of precedence:
1. Defaults built from mediawiki/externalDatabase/security values and image paths.
2. localSettings.variables (can override ANY global, including DB connection and keys).
3. wfLoadSkin / wfLoadExtension from the declared lists.
4. localSettings.extraPhp.
5. Operational mediawiki.readOnly=true forces HTTP maintenance mode, not CLI.

Use externalDatabase/security keys as the normal connection/key interface; do not
silently override them in variables. For fresh installs, endpoint/DB credentials,
site name/server and key values belong in the corresponding top-level sections;
installer language, script path and DB prefix come from variables. The installer
uses those parameters, not arbitrary extension globals during initial core creation.
The final updater and web process load all configured globals and extensions.
Do not set reserved PHP runtime globals such as GLOBALS or _SERVER.

Loading an extension does not download it. Bundled extensions are available in the
image; custom extensions, compatible skins and required PHP modules must be added
to a derived image or explicitly mounted. Use releases compatible with MediaWiki
1.43. SMTP may require PEAR Mail/Net_SMTP packages not included by default.

Chart creates Kubernetes Secrets for settings.json, extra.php, inline DB credentials
and stable keys. They are still stored in Helm release values/history; use private
values files or existing Secrets for credentials. Optional existing Secret contracts:

- externalDatabase.existingSecret: keys database-user and database-password
  (customizable with userKey/passwordKey).
- security.existingSecret: keys secret-key and upgrade-key.
- bootstrap.existingSecret: key admin-password (customizable with passwordKey).

No random key regeneration occurs. Changing chart-managed configuration rolls web
Pods via checksum; after external Secret changes restart the Deployment explicitly.
Full configuration uses Rancher's YAML editor; the form shows the most common fields.

## Storage and runtime

- Application code remains in the image at /var/www/html; never replace it with old code.
- Only uploads are persistent at /var/www/html/images, with optional PVC subPath.
- Original transferred Bitnami data can stay intact on a separate PVC. See MIGRATION.md.
- Non-root UID/GID 33, read-only root filesystem, writable /tmp and uploads.
- Apache listens on 8080, Service exposes 80; TLS terminates at Ingress.
- Recreate rollouts and maximum one web replica suit RWO storage.
- Chart-created uploads PVCs carry helm.sh/resource-policy=keep. Existing PVCs are
  referenced without Helm ownership changes. Never uninstall old data prematurely.
- Verify UID 33 permissions and CSI fsGroup support on COPIED data.
- ImagesSubPath and destination subPath are relative to PVC root, not container paths.

NetworkPolicy is optional: when enabled, allow HTTP ingress and unrestricted egress.
Tune for your cluster. A DB server is installed only when mariadb.enabled=true. No exporter, SMTP server,
cron/job runner, search engine or other extension service is installed implicitly.

## Publish and install through Rancher

1. Put this directory's contents at the root of a new public GitHub repository,
   including .github/workflows. The project/repository name is mediawiki-helm; the Helm chart name is mediawiki.
2. Allow Actions with contents:write. Push main or manually run **Publish MediaWiki
   Helm chart**. Validation precedes publishing. Workflow creates a versioned GitHub
   Release with the tgz and a gh-pages branch containing index.yaml.
3. In GitHub Settings > Pages select gh-pages, /(root), Deploy from a branch.
4. In Rancher > Apps > Repositories add the HTTP URL:
   `https://OWNER.github.io/mediawiki-helm/` (replace OWNER).
5. Refresh Charts, select MediaWiki, namespace and values. No publishing or cluster
   changes have been performed by generating this package.

Increment Chart.yaml version for each release. Already published versions are immutable.
If publication fails after release creation, repair gh-pages using the existing release;
do not overwrite its package. Private repositories require appropriate Rancher access.

## Validation

```bash
bash scripts/install-helm.sh
export PATH="$PWD/.tools:$PATH"
python3 -m pip install PyYAML==6.0.3
python3 scripts/validate.py
bash scripts/smoke-test.sh # Docker required
helm package chart/mediawiki
```

See VALIDATION.md for checks actually run. Staging DB/import tests are required
before production; Helm cannot roll back SQL changes. Extension behavior, auth,
permissions, SMTP, short URLs and TLS must be verified with your configuration.

## References

- https://hub.docker.com/_/mediawiki
- https://www.mediawiki.org/wiki/Manual:Install.php
- https://www.mediawiki.org/wiki/Manual:Upgrading
- https://www.mediawiki.org/wiki/Manual:Configuration_settings
- https://phabricator.wikimedia.org/T401570

MediaWiki 1.43.4+ fixes MariaDB 12 read_only='OFF' detection. Keep the pinned
1.43 patch release current. image.digest overrides tag when supplied.

CI tests fresh installation against MariaDB 12 and separately against the dedicated
11.4.13 image as UID 999 with read-only root filesystem. These tests run in Actions,
not as part of local render validation.
