# Validation — mediawiki-helm 0.3.0

Locally executed with Helm v3.17.3:

- helm lint --strict: PASS.
- 14 configuration render cases including fresh install, Bitnami import, migration,
  TLS/policy/storage variants, dedicated MariaDB and external database: PASS.
- 10 rejection checks covering conflicting operations, invalid replica/port values,
  missing credentials/import inputs and dedicated root application user: PASS.
- Typed/nested LocalSettings globals round-trip through generated Secret JSON: PASS.
- Dedicated mode routes the app to its own internal Service/application Secret: PASS.
- External mode creates no DB StatefulSet or DB PVC: PASS.
- Dedicated existing DB PVC/Secret references, separate data storage, and network
  policy port 3306 selection: PASS.
- App never receives dedicated root-password credentials: PASS.
- Installer/updater connectivity wait init-container: PASS.
- YAML parsing, rendered operation shell syntax and all shell script syntax: PASS.
- No old project/customer references in deliverables: PASS.
- Chart packaging and ZIP integrity: PASS.

Not run locally: Docker/PHP or real DB startup, DB installation/migration/import,
Kubernetes admission and CSI permissions, Rancher installation, publishing, TLS,
email or existing extension behavior. No external cluster/repository was modified.

CI includes Docker/PHP/Apache smoke tests, fresh install against MariaDB 12.3.3,
and a separate non-root/read-only MariaDB 11.4.13 runtime integration check.
Publishing depends on CI. These are provided CI checks, not a claim that they have
already passed in GitHub Actions. Stage and back up data before production use.
