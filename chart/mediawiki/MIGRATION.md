# Import an existing Bitnami wiki

A new Kubernetes release does not require a new wiki database. For an existing wiki,
restore the OLD database and uploads first, then upgrade its schema with the new
image. Keep bootstrap.enabled=false throughout this workflow.

## 1. Back up / copy

Stop old web writers and job runners for a consistent final transfer. Back up:
- external database (logical dump + verified restore, appropriate to your DB cluster),
- the complete /bitnami/mediawiki directory and original LocalSettings.php,
- versions and sources of custom extensions/skins, external assets and services.

Rehearse using independent restored data. Retain original volume and backup.
Restore the database into your chosen external MariaDB service, or a dedicated
server created with mariadb.enabled=true, with a user allowed to upgrade that database.
For a dedicated server first deploy with replicas=0 and ALL operation flags false;
wait for MariaDB readiness, then restore your SQL dump into its configured schema.
Do not enable bootstrap for a restored wiki. Choose an image version compatible
with your source DB; the default fresh-install DB image is 11.4.13. Record old table prefix and preserve old wgSecretKey,
wgUpgradeKey, wgScriptPath, wgArticlePath, authentication and permission settings.
Translate those settings to values.yaml. The old LocalSettings.php is NOT executed
or automatically converted: it may contain arbitrary PHP and stale absolute paths.

## 2. Move /bitnami/mediawiki data

You can transfer the WHOLE directory to a PVC, but the chart uses the images
subdirectory for uploads. It does not overlay old core PHP code on the new image.
Old extensions/skins require compatible versions in a derived image. Check custom
wgUploadDirectory, assets or additional persisted files before copying.

Choose ONE method:

### A. Use the transferred PVC directly

If the PVC root contains the CONTENTS of /bitnami/mediawiki, i.e. it has images/:

```yaml
persistence:
  existingClaim: transferred-wiki-data
  subPath: images
bitnamiImport:
  enabled: false
```

If you copied the directory itself as mediawiki/ at PVC root, use subPath:
mediawiki/images. Verify the actual layout; the container path /bitnami is not
part of the PVC path unless you explicitly copied it that way. This method uses
the transferred PVC, which must be writable by UID/GID 33. Use a COPY for testing.

### B. Copy uploads into a clean new PVC with the provided Job

Transfer full data to a separate source PVC in the SAME namespace. Configure:

```yaml
replicaCount: 0
bootstrap: {enabled: false}
migration: {enabled: false}
bitnamiImport:
  enabled: true
  existingClaim: transferred-wiki-data
  imagesSubPath: images # or mediawiki/images, according to actual source layout
persistence:
  existingClaim: '' # create a new uploads-only destination PVC
  subPath: ''
```

The Job mounts source read-only and copies ONLY uploads. It refuses a nonempty
destination and never overwrites existing files intentionally. Source and target
claims must differ. Use a stopped, independent COPY of original data; filesystem
mount behavior/permissions depend on CSI. The source must be readable by UID 33.
The destination must be writable. Interrupted copy leaves partial files: inspect
and use a fresh empty destination before a deliberate retry. A later Helm revision
can create another Job, so turn the operation off after success.

## 3. Configure new release

Set externalDatabase host/port/name/user/password, or an existing credentials Secret.
Use old wgSecretKey/upgrade key in security values or an existing keys Secret.
Keep table prefix, URL paths, language, access rules and extension settings through
localSettings.variables/extraPhp. Never copy old PHP application code over the
new image. Do not enable both old/new Ingress rules for the same hostname during testing.
Install a NEW release with replicas=0 and use a staging hostname/database first.

## 4. Upgrade schema

After upload copy succeeds, disable bitnamiImport. Ensure previous Jobs have finished
and old writers/web Pods using the database/PVC are stopped. Then save values:

```yaml
replicaCount: 0
bootstrap: {enabled: false}
bitnamiImport: {enabled: false}
migration: {enabled: true, runId: upgrade}
```

Upgrade through Rancher. Inspect Job logs and completion. It runs the standard
`php maintenance/run.php update --quick` with generated LocalSettings. No hooks
run schema changes on routine restart. No automatic retries after a failed Job.
Chart blocks concurrent operation flags and its own running web replicas; it cannot
stop another release's writers. Separate install/import/update steps are mandatory.

## 5. Serve and verify

After successful schema upgrade set migration.enabled=false, replicaCount=1 and
mediawiki.readOnly=true. Check Special:Version, pages, auth, permissions, images,
short URLs, extensions and email. Test edits/uploads on the isolated staging copy
by setting readOnly=false deliberately. Preserve wgArticlePath/wgScriptPath if URLs
must remain stable; adjust ingress/rewrite/extension services as needed.

At cutover stop old writers, make final backups/refresh data, run final migration,
verify read-only, switch routing and turn readOnly=false. A schema upgrade cannot
be undone by Helm rollback; restore the matching DB, uploads and configuration
before serving an older image. Do not delete old PVCs until migration is accepted.

## What cannot be inferred from a database and directory alone

Custom PHP logic, secret keys, extension dependencies, external services, URL rules,
SMTP libraries and filesystem permissions need configuration review. This chart
makes all LocalSettings assignments available in values; it cannot infer arbitrary
old PHP safely. No automatic database dump/restore or old administrator reset occurs.
