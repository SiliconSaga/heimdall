# Monitoring data services

How Heimdall watches databases, and why it watches volumes rather than databases.

## There is no database exporter

This cluster runs **no PostgreSQL exporter**. There are no `pg_*` metrics — no connection counts, no transaction rates, no `pg_postmaster_start_time_seconds`. Percona can ship PMM and CloudNativePG has its own exporter, but neither is enabled here.

Everything below therefore infers database health from the **volume** underneath it. That is a weaker instrument than reading the engine, and it is worth knowing where the limit is:

| Question | Answerable today | How |
|---|---|---|
| Did this database lose its data? | yes | volume usage collapsed, or the volume is new |
| Is it about to run out of disk? | yes | usage vs capacity |
| Did it restart? | yes | pod start time |
| Are backups being written? | partly | repository growth, and backup Job failures |
| How many connections is it serving? | **no** | needs an exporter |
| Is replication lagging? | **no** | needs an exporter |
| Is a specific *database* inside the cluster healthy? | **no** | needs an exporter |

The last row matters more after consolidation. Once many tenants share one cluster, per-volume metrics describe the *server*, not the individual databases on it. Adding an exporter is the natural next step and is tracked with the shared-cluster work.

## Why volume behaviour is a good data-loss signal

A database volume's usage curve is normally flat or slowly rising. Postgres does not free large amounts of space on its own — `VACUUM` reuses pages inside existing files rather than returning them. So a **sharp fall in used bytes is not housekeeping**. It means something replaced the data.

That is exactly the seed-Gitea failure this platform keeps hitting: the repositories lived on an `emptyDir`, so a pod move discarded them while the Postgres PVC survived. The database kept insisting five repositories existed while the files were gone. A used-bytes cliff is the shape that failure makes.

Two independent signals cover it:

- **Usage collapsed** — the volume is the same one, but its contents are not.
- **The volume is new** — a recreated PVC means the old data was never carried over. This catches the case where usage never collapses because the volume was replaced wholesale.

pgBackRest repositories (`*-repo1`) are deliberately **excluded from the collapse rule**. Expiring an old backup legitimately frees space there, so the same shape is normal.

## The panels

The `Data services` row on the Heimdall Overview dashboard:

| Panel | Reads |
|---|---|
| Volume age (days) | how long each database volume has existed |
| Data volume used | usage over time — the cliff detector |
| Backup repositories | pgBackRest repo size over time |
| Volume fullness | used vs capacity |
| Database pod uptime | time since each database-plane pod started |

**Volume age is coloured inverted on purpose.** Young is red, old is green. Everywhere else on the dashboard a low number is good; here a volume that is minutes old where a months-old one is expected is the whole finding.

**A flat backup-repository line is the thing to look for.** Backups stopping is silent — nothing fails, nothing restarts, and it stays invisible until a restore is attempted. Growth is the only evidence they are still happening.

## The alerts

Group `heimdall.data-services`, defined in `crossplane/composition.yaml`.

| Alert | Fires when | Tier |
|---|---|---|
| `HeimdallDatabaseVolumeShrank` | usage falls below half of an hour ago, for 10m | **watched** |
| `HeimdallDatabaseVolumeCritical` | volume over 93% full, for 5m | **watched** |
| `HeimdallDatabaseVolumeFillingUp` | volume over 85% full, for 15m | quiet |
| `HeimdallDatabaseVolumeRecreated` | volume younger than 15 minutes, for 2m | quiet |
| `HeimdallDatabaseBackupFailed` | a backup Job reports failure, for 5m | quiet |

**Two of these carry `watched: "true"`, and that label is doing real work.** AlertManager matches the watched route *first*, before severity — so `severity: critical` on its own would have landed in the silent tier alongside everything else. Data disappearing is the one thing that should not wait to be noticed, so it is labelled up into the tier normally reserved for named services.

The tiers, defined by the AlertManager route tree in `crossplane/composition.yaml`:

| Topic | Priority | Reaches |
|---|---|---|
| `heimdall-info` | 2 | silent — visible in the app, no sound |
| `heimdall-workload` | 3 | audible |
| `heimdall-watched` | 4 | heads-up notification |
| — | 5 | reserved for on-call, deliberately unused |

Priority 5 is the only one that pierces Do Not Disturb, and nothing is routed there yet.

`HeimdallDatabaseVolumeRecreated` **is expected to fire whenever a database is legitimately provisioned**, and resolves on its own after fifteen minutes. That is not noise to be tuned out — it is the confirmation that a new volume appeared, which is the same event as an unexpected one. What distinguishes them is whether you were expecting it.

### When the collapse alert fires

1. **Stop writes before investigating** if anything can still write to the database. A half-empty database that is being written to is losing the evidence.
2. Check whether the volume is the original: `kubectl get pvc -n <ns>` and compare age against the panel.
3. Check the backup repository. If it is intact, restoring is a real option. If it is also empty, the loss is total.

The order matters. Restoring over a database that was merely *unmounted* rather than wiped turns a recoverable incident into an unrecoverable one.

## Coverage gap this closed

The pre-existing `heimdall.pvc-fill` group is scoped to `namespace="heimdall"` — it watches Prometheus, Loki and Tempo storage only. **Database volumes in tenant namespaces had no fill alerting at all.** Ting, Keycloak and Gitea could have filled their data volumes without a single alert. The `heimdall.data-services` group covers them by PVC name pattern rather than by namespace, so a new tenant is covered the moment its volume matches.
