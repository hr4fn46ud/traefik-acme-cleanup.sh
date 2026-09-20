# Changelog

All notable changes to this project are documented here.

## [1.0.0] - 2026-09-20

### Added

- Safe-by-default discovery of stale certificates in Traefik's `letsencrypt` ACME store.
- Explicit `--delete` mode with backup, validation, atomic replacement, and rollback.
- Active-domain discovery through Traefik's internal API.
- Manual protection through `traefik-admin-preserve.txt`.
- Reporting for `HostRegexp` routers without modifying separate custom-resolver ACME stores.
- Pangolin-focused installation, recovery, and troubleshooting documentation.
