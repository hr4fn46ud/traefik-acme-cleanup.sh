# Changelog

All notable changes to this project are documented here.

## [1.1.0] - 2026-11-21

### Added

- Automatic protection for wildcard certificates (`PROTECT_WILDCARDS`, default
  enabled): certificates with at least one wildcard name are never removed,
  because wildcard names never appear in `Host()` rules and a DNS-01 wildcard
  may live in the standard store.
- Signal handling for `SIGINT`, `SIGTERM` and `SIGHUP`: an interrupt during
  the critical write phase restores the backup and restarts Traefik instead of
  leaving the deployment stopped.
- Configurable Traefik internal API endpoint via `TRAEFIK_API_URL` (default
  `http://127.0.0.1:8080`).
- Optional backup rotation via `KEEP_BACKUPS`; the default keeps all backups.
- Explicit `--dry-run` flag for clarity in automated pipelines.
- `--force` as a documented override for the remove-all safety abort, only
  accepted together with `--delete`.
- Additional regression tests: help/version output, argument validation,
  invalid store rejection, wildcard protection on and off, API URL override,
  backup retention and `--force` behaviour.
- CI: manual dispatch trigger, run suppression for concurrent pushes, and a
  `bash -n` syntax check step.

### Changed

- The report and the store generation now share a single jq keep-filter, so
  the dry-run list and the deletion can never disagree.
- The candidate store is flushed with `sync` (best effort) before the atomic
  rename.
- The remove-all safety abort prints the exact `--delete --force` command for
  the rare case where removing everything is actually intended.

## [1.0.0] - 2026-09-20

### Added

- Safe-by-default discovery of stale certificates in Traefik's `letsencrypt` ACME store.
- Explicit `--delete` mode with backup, validation, atomic replacement, and rollback.
- Active-domain discovery through Traefik's internal API.
- Manual protection through `traefik-admin-preserve.txt`.
- Reporting for `HostRegexp` routers without modifying separate custom-resolver ACME stores.
- Pangolin-focused installation, recovery, and troubleshooting documentation.
