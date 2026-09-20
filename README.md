# traefik-acme-cleanup.sh

`traefik-acme-cleanup.sh` removes stale certificates from Traefik's standard
ACME store in a Pangolin Docker deployment. It is conservative by design: the
default mode only reports findings, deletion requires an explicit `--delete`,
and the script refuses to remove every certificate in the store.

Current version: **1.0.0**

## The problem

Removing a Pangolin resource, Traefik router, site, or old hostname does not
necessarily remove the certificate that Traefik previously obtained for it.
The certificate entry can remain in `acme.json` indefinitely. Over time, the
store accumulates names which are no longer routed and should no longer be
renewed.

Deleting entries blindly is risky. A certificate can cover a main name and
several Subject Alternative Names (SANs), some names may need to survive while
temporarily unused, and wildcard certificates may live in a different ACME
store.

## Original idea and approach

The original cleanup script compared the certificates in Traefik's normal
Let's Encrypt resolver with the hostnames currently exposed by Traefik. This
version retains that approach and makes the workflow safer:

1. Query the running Traefik container's internal HTTP API.
2. Extract concrete names from active `Host()` router rules.
3. Add names from an administrator-managed preserve file.
4. Mark a certificate as orphaned only if **none** of its main or SAN names is
   active or preserved.
5. Report the result in dry-run mode.
6. In delete mode, back up the store, build and validate a cleaned copy, stop
   Traefik, replace the store atomically, validate again, and restart Traefik.

This cleanup is permanent only when the obsolete Pangolin resource or Traefik
router has already been removed. If the router still exists, Traefik may simply
request the certificate again. Automation: still very obedient, including
when told to repeat the original mistake.

## Scope

The script modifies only:

```text
/opt/pangolin/config/letsencrypt/acme.json
```

It reads active routers from the container named `traefik` and reads protected
names from:

```text
/opt/pangolin/traefik-admin-preserve.txt
```

It does **not** discover or modify additional ACME stores used by custom
resolvers, including separate DNS-01 stores.

## Requirements

- A typical Pangolin Docker installation under `/opt/pangolin`
- Bash 4 or newer
- Docker CLI access and a running container named `traefik`
- `jq` and standard GNU/Linux utilities
- `wget` inside the Traefik container
- Traefik's internal API reachable at `http://127.0.0.1:8080` from inside the
  container
- Root privileges for delete mode in the usual `/opt/pangolin` installation

The script expects the resolver data at `.letsencrypt.Certificates` in
`acme.json`. It aborts if that structure is missing.

On Debian or Ubuntu, install the host-side non-standard dependency with:

```bash
sudo apt-get update
sudo apt-get install jq
```

## Installation

From the repository directory:

```bash
sudo install -m 0755 traefik-acme-cleanup.sh \
  /opt/pangolin/traefik-acme-cleanup.sh

sudo install -m 0644 traefik-admin-preserve.txt \
  /opt/pangolin/traefik-admin-preserve.txt
```

Confirm the installed version:

```bash
/opt/pangolin/traefik-acme-cleanup.sh --version
```

## Recommended workflow

### 1. Remove the obsolete resource

Remove the old domain/resource in Pangolin and confirm its corresponding
Traefik router has disappeared. Do this before touching the ACME store.

### 2. Protect intentionally retained names

Edit `/opt/pangolin/traefik-admin-preserve.txt` and add one exact DNS name per
line. Full-line comments and blank lines are ignored:

```text
# Administrative endpoint kept for later use
admin.example.com

# Exact wildcard name as it appears in the certificate
*.storage.example.com
```

Entries are compared case-insensitively. Inline comments are not supported.
The preserve file does not create or renew certificates; it only prevents
matching entries from being removed from the standard store.

### 3. Run a dry run

Dry run is the default and does not modify files or stop Traefik:

```bash
cd /opt/pangolin
sudo ./traefik-acme-cleanup.sh
```

Review all counts, preserved names, detected `HostRegexp` routers, and every
certificate listed under `Orphaned certificates`.

### 4. Delete the reviewed entries

Only after the dry-run result is correct:

```bash
cd /opt/pangolin
sudo ./traefik-acme-cleanup.sh --delete
```

Traefik is briefly stopped while the validated replacement is installed. The
script then restarts it and verifies that the container is running.

### 5. Verify the deployment

```bash
docker ps --filter name=traefik
docker logs --since 5m traefik
sudo jq '.letsencrypt.Certificates | length' \
  /opt/pangolin/config/letsencrypt/acme.json
```

Test the affected HTTPS endpoints and confirm that active certificates are
still served.

## Safety mechanisms

- Dry run unless `--delete` is supplied explicitly
- Refuses unknown or multiple command-line arguments
- Requires a running Traefik container and a non-empty router list
- Aborts when no concrete `Host()` names can be discovered
- Validates the source, generated, and installed JSON
- Keeps a multi-name certificate if at least one main/SAN name is protected
- Refuses to remove all certificates
- Creates a timestamped backup before stopping Traefik
- Preserves the original owner and file mode
- Uses a same-filesystem temporary file and atomic rename
- Restores the backup and attempts to restart Traefik if installation,
  validation, or startup fails
- Never writes to additional custom-resolver ACME stores

No script can determine business intent. The preserve file and the mandatory
review step remain the administrator's responsibility.

## Backups and restore

Successful delete runs create a backup beside the live store:

```text
/opt/pangolin/config/letsencrypt/acme.json.bak-YYYYMMDD-HHMMSS
```

The script reports the exact path. Keep the backup until the cleaned deployment
has been verified.

To restore manually, use the path printed by the cleanup run:

```bash
sudo docker stop traefik
sudo cp -a \
  /opt/pangolin/config/letsencrypt/acme.json.bak-YYYYMMDD-HHMMSS \
  /opt/pangolin/config/letsencrypt/acme.json
sudo jq empty /opt/pangolin/config/letsencrypt/acme.json
sudo docker start traefik
```

Do not restore while Traefik is writing the store.

## Separate custom-resolver / DNS-01 stores

Pangolin deployments may use one or more custom resolvers with separate ACME
stores for DNS-01 challenges, especially for wildcard certificates referenced
by `HostRegexp()` routers. Store names and DNS providers vary by deployment.
Concrete wildcard names cannot be derived safely from a regular expression.

For that reason, this script only displays `HostRegexp` router name, rule, and
certificate resolver. It never discovers, rewrites, or cleans any additional
custom-resolver store. Do not point `ACME_FILE` at such a store and assume the
same discovery logic is sufficient; DNS-01 cleanup needs resolver-aware rules
and a separate review.

## Non-standard paths and names

Defaults can be overridden for a non-standard deployment:

```bash
sudo ACME_FILE=/srv/pangolin/letsencrypt/acme.json \
  PRESERVE_FILE=/srv/pangolin/traefik-admin-preserve.txt \
  TRAEFIK_CONTAINER=pangolin-traefik \
  ./traefik-acme-cleanup.sh
```

Use the same overrides again for `--delete`. Environment overrides are an
advanced feature: verify each path before running as root.

## Troubleshooting

### `Traefik container not found`

Find the actual name with `docker ps --format '{{.Names}}'`. If it differs, set
`TRAEFIK_CONTAINER` as shown above.

### `Unable to query the Traefik API`

Test the query directly:

```bash
docker exec traefik \
  wget -qO- http://127.0.0.1:8080/api/http/routers | jq .
```

Check that `wget` exists in the container and that the Traefik API/dashboard is
enabled on the expected internal entry point. The API need not be public.

### `No active Host() domains were detected`

The script intentionally aborts rather than guessing. Inspect the router rules
returned by the API. A deployment using only `HostRegexp()` rules is not safe
for this automatic cleanup method.

### A valid certificate appears orphaned

Do not use `--delete`. Confirm that the corresponding router is active and add
each exact required name to `traefik-admin-preserve.txt`. Then rerun the dry
run.

### An obsolete certificate is not reported

At least one name on that certificate is still used by a `Host()` router or is
listed in the preserve file. The entire certificate is retained when any one
of its names remains protected.

### Traefik fails after cleanup

The script attempts automatic rollback. If Traefik still does not run, inspect
`docker logs traefik`, restore the printed backup manually, and start the
container. Separate custom-resolver stores remain untouched.

### `stat: invalid option -- c`

Delete mode expects GNU `stat`, as found on normal Linux Pangolin hosts. macOS
uses a different interface and is not a supported production target. Run the
script on the Pangolin host, not on an administrator workstation.

## Development

Run the local regression suite:

```bash
bash tests/test.sh
```

If ShellCheck is installed:

```bash
shellcheck traefik-acme-cleanup.sh tests/test.sh
```

## License

Released under the [MIT License](LICENSE).
