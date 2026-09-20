#!/usr/bin/env bash
set -Eeuo pipefail

readonly VERSION="1.0.0"
readonly PROGRAM_NAME="traefik-acme-cleanup.sh"

# Defaults match a standard Pangolin installation. Environment overrides are
# useful for non-standard deployments and automated tests.
readonly ACME_FILE="${ACME_FILE:-/opt/pangolin/config/letsencrypt/acme.json}"
readonly PRESERVE_FILE="${PRESERVE_FILE:-/opt/pangolin/traefik-admin-preserve.txt}"
readonly TRAEFIK_CONTAINER="${TRAEFIK_CONTAINER:-traefik}"

MODE="dry-run"

usage() {
    cat <<EOF
Usage: $PROGRAM_NAME [--delete | --help | --version]

Without arguments, the script performs a dry run. Use --delete only after
reviewing the reported orphaned certificates.
EOF
}

case "${1:-}" in
    "") ;;
    --delete) MODE="delete" ;;
    --help|-h) usage; exit 0 ;;
    --version|-V) printf '%s %s\n' "$PROGRAM_NAME" "$VERSION"; exit 0 ;;
    *)
        printf 'ERROR: Unknown argument: %s\n\n' "$1" >&2
        usage >&2
        exit 1
        ;;
esac

if (( $# > 1 )); then
    echo "ERROR: Only one argument is accepted." >&2
    usage >&2
    exit 1
fi

WORK_DIR="$(mktemp -d)"
INSTALL_CANDIDATE=""

cleanup() {
    rm -rf -- "$WORK_DIR"
    if [[ -n "$INSTALL_CANDIDATE" ]]; then
        rm -f -- "$INSTALL_CANDIDATE"
    fi
}
trap cleanup EXIT

readonly ACTIVE="$WORK_DIR/active-domains.txt"
readonly ACTIVE_JSON="$WORK_DIR/active-domains.json"
readonly NEW_ACME="$WORK_DIR/acme.json.new"
readonly ROUTERS_FILE="$WORK_DIR/routers.json"
readonly PRESERVED_DOMAINS="$WORK_DIR/preserve-domains.txt"

echo "Pangolin / Traefik ACME Cleanup v$VERSION"
echo "========================================"
echo

# Check host-side requirements.
for command_name in docker jq grep sed sort stat wc cp chmod chown date mv tr mktemp rm sleep; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $command_name" >&2
        exit 1
    fi
done

if [[ ! -f "$ACME_FILE" ]]; then
    printf 'ERROR: ACME store not found:\n       %s\n' "$ACME_FILE" >&2
    exit 1
fi

if ! jq empty "$ACME_FILE" 2>/dev/null; then
    echo "ERROR: The existing ACME store is not valid JSON." >&2
    exit 1
fi

if ! jq -e '.letsencrypt.Certificates | arrays' "$ACME_FILE" >/dev/null 2>&1; then
    echo "ERROR: .letsencrypt.Certificates was not found in the ACME store." >&2
    exit 1
fi

# The Traefik API is queried inside the container; no dashboard exposure is
# required. The container image must provide wget.
if ! docker inspect "$TRAEFIK_CONTAINER" >/dev/null 2>&1; then
    printf 'ERROR: Traefik container not found:\n       %s\n' "$TRAEFIK_CONTAINER" >&2
    exit 1
fi

if [[ "$(docker inspect -f '{{.State.Running}}' "$TRAEFIK_CONTAINER")" != "true" ]]; then
    echo "ERROR: The Traefik container is not running." >&2
    exit 1
fi

echo "Reading active Traefik routers..."

if ! docker exec "$TRAEFIK_CONTAINER" \
        wget -qO- http://127.0.0.1:8080/api/http/routers \
        > "$ROUTERS_FILE"; then
    echo "ERROR: Unable to query the Traefik API inside the container." >&2
    exit 1
fi

if ! jq -e 'type == "array"' "$ROUTERS_FILE" >/dev/null 2>&1; then
    echo "ERROR: The Traefik API did not return a JSON array." >&2
    exit 1
fi

readonly ROUTER_COUNT="$(jq 'length' "$ROUTERS_FILE")"
if (( ROUTER_COUNT == 0 )); then
    echo "ERROR: Traefik reports zero routers; cleanup aborted." >&2
    exit 1
fi

# Extract every backtick-quoted hostname from Host(), including rules with
# multiple Host() arguments. HostRegexp() rules are deliberately excluded.
jq -r '
    .[].rule // empty
    | scan("Host\\([^)]*\\)")
    | scan("`[^`]+`")
    | ltrimstr("`")
    | rtrimstr("`")
' "$ROUTERS_FILE" \
    | tr '[:upper:]' '[:lower:]' \
    | sort -u > "$ACTIVE"

readonly TRAEFIK_HOST_COUNT="$(wc -l < "$ACTIVE" | tr -d ' ')"
if (( TRAEFIK_HOST_COUNT == 0 )); then
    echo "ERROR: No active Host() domains were detected; cleanup aborted." >&2
    exit 1
fi

PRESERVE_COUNT=0
if [[ -f "$PRESERVE_FILE" ]]; then
    grep -vE '^[[:space:]]*(#|$)' "$PRESERVE_FILE" \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | tr '[:upper:]' '[:lower:]' \
        | sort -u > "$PRESERVED_DOMAINS" || true

    PRESERVE_COUNT="$(wc -l < "$PRESERVED_DOMAINS" | tr -d ' ')"
    if (( PRESERVE_COUNT > 0 )); then
        cat "$PRESERVED_DOMAINS" >> "$ACTIVE"
        sort -u -o "$ACTIVE" "$ACTIVE"
    fi
else
    echo
    printf 'WARNING: Preserve file not found:\n         %s\n' "$PRESERVE_FILE" >&2
    echo "Continuing without manually preserved domains." >&2
fi

readonly ACTIVE_COUNT="$(wc -l < "$ACTIVE" | tr -d ' ')"

# HostRegexp routers commonly belong to the separate DNS-01 resolver. They are
# displayed for review, but their wildcard names cannot be inferred safely.
REGEXP_ROUTERS="$(
    jq -r '
        .[]
        | select((.rule // "") | test("HostRegexp"))
        | [.name, .rule, (.tls.certResolver // "none")]
        | @tsv
    ' "$ROUTERS_FILE"
)"

if [[ -n "$REGEXP_ROUTERS" ]]; then
    echo
    echo "HostRegexp routers detected"
    echo "---------------------------"
    echo "$REGEXP_ROUTERS"
    echo
    echo "NOTE: Wildcard certificates are often stored by a separate custom"
    echo "DNS-01 resolver. Additional ACME stores will not be modified."
fi

jq -R . < "$ACTIVE" | jq -s . > "$ACTIVE_JSON"

readonly CERT_COUNT="$(jq '.letsencrypt.Certificates | length' "$ACME_FILE")"

# A certificate is orphaned only when none of its main/SAN names is active or
# manually preserved. DNS names are compared case-insensitively.
readonly ORPHAN_FILTER='
    ([.domain.main] + (.domain.sans // []) | map(ascii_downcase)) as $names
    | select(
        ($names | map(. as $name | ($active[0] | index($name)) != null) | any)
        | not
      )
'

readonly ORPHAN_COUNT="$(
    jq --slurpfile active "$ACTIVE_JSON" \
        "[.letsencrypt.Certificates[] | $ORPHAN_FILTER] | length" \
        "$ACME_FILE"
)"

echo
echo "Summary"
echo "-------"
printf "Traefik routers:            %s\n" "$ROUTER_COUNT"
printf "Active Host() domains:      %s\n" "$TRAEFIK_HOST_COUNT"
printf "Preserved domains:          %s\n" "$PRESERVE_COUNT"
printf "Effective protected names:  %s\n" "$ACTIVE_COUNT"
printf "Certificates in store:      %s\n" "$CERT_COUNT"
printf "Orphaned certificates:      %s\n" "$ORPHAN_COUNT"

if (( PRESERVE_COUNT > 0 )); then
    echo
    echo "Manually preserved domains"
    echo "--------------------------"
    cat "$PRESERVED_DOMAINS"
fi

echo
echo "Orphaned certificates"
echo "---------------------"
if (( ORPHAN_COUNT == 0 )); then
    echo "None."
else
    jq -r --slurpfile active "$ACTIVE_JSON" "
        .letsencrypt.Certificates[]
        | $ORPHAN_FILTER
        | if ((.domain.sans // []) | length) > 0
          then \"\(.domain.main) [SANs: \(.domain.sans | join(\", \"))]\"
          else .domain.main
          end
    " "$ACME_FILE" | sort
fi

if [[ "$MODE" == "dry-run" ]]; then
    echo
    echo "DRY RUN ONLY"
    echo "------------"
    echo "No files were modified."
    if (( ORPHAN_COUNT > 0 )); then
        echo
        echo "After reviewing the list, remove these certificates with:"
        echo "  sudo ./$PROGRAM_NAME --delete"
    fi
    exit 0
fi

if (( ORPHAN_COUNT == 0 )); then
    echo
    echo "Nothing to remove."
    exit 0
fi

# Refuse an empty resulting store. This also catches a broken active-domain
# discovery before it can destroy all certificates.
if (( CERT_COUNT == 0 || ORPHAN_COUNT >= CERT_COUNT )); then
    echo "ERROR: Cleanup would remove all certificates; safety abort." >&2
    exit 1
fi

readonly EXPECTED_COUNT=$(( CERT_COUNT - ORPHAN_COUNT ))
if (( EXPECTED_COUNT <= 0 )); then
    echo "ERROR: Expected certificate count is invalid; safety abort." >&2
    exit 1
fi

readonly ORIGINAL_OWNER="$(stat -c '%u:%g' "$ACME_FILE")"
readonly ORIGINAL_MODE="$(stat -c '%a' "$ACME_FILE")"
readonly TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
readonly BACKUP="${ACME_FILE}.bak-${TIMESTAMP}"

echo
printf 'Creating backup:\n  %s\n' "$BACKUP"
cp -a -- "$ACME_FILE" "$BACKUP"

echo
echo "Generating cleaned ACME store..."
jq --slurpfile active "$ACTIVE_JSON" "
    .letsencrypt.Certificates |= map(
        ([.domain.main] + (.domain.sans // []) | map(ascii_downcase)) as \$names
        | select(
            \$names
            | map(. as \$name | (\$active[0] | index(\$name)) != null)
            | any
          )
    )
" "$ACME_FILE" > "$NEW_ACME"

if ! jq empty "$NEW_ACME" 2>/dev/null; then
    echo "ERROR: The generated ACME store is invalid JSON." >&2
    exit 1
fi

readonly NEW_COUNT="$(jq '.letsencrypt.Certificates | length' "$NEW_ACME")"
if (( NEW_COUNT != EXPECTED_COUNT )); then
    printf 'ERROR: Certificate count validation failed. Expected %s, got %s.\n' \
        "$EXPECTED_COUNT" "$NEW_COUNT" >&2
    exit 1
fi

echo
echo "Validation successful:"
printf "  Before:  %s\n  Remove:  %s\n  After:   %s\n" \
    "$CERT_COUNT" "$ORPHAN_COUNT" "$NEW_COUNT"

restore_and_restart() {
    local reason="$1"
    echo
    printf 'ERROR: %s\n' "$reason" >&2
    echo "Restoring the backup..." >&2

    if ! cp -a -- "$BACKUP" "$ACME_FILE"; then
        printf 'CRITICAL: Backup restoration failed. Backup: %s\n' "$BACKUP" >&2
    fi

    echo "Starting Traefik..." >&2
    if ! docker start "$TRAEFIK_CONTAINER" >/dev/null; then
        echo "CRITICAL: Traefik could not be restarted." >&2
    fi
    exit 1
}

echo
echo "Stopping Traefik..."
if ! docker stop "$TRAEFIK_CONTAINER" >/dev/null; then
    echo "ERROR: Traefik could not be stopped; the ACME store was not changed." >&2
    exit 1
fi

# Prepare permissions before the atomic rename, so a partial copy never becomes
# the live store. The candidate resides on the same filesystem as acme.json.
INSTALL_CANDIDATE="${ACME_FILE}.tmp.$$"
if ! cp -- "$NEW_ACME" "$INSTALL_CANDIDATE" \
    || ! chown "$ORIGINAL_OWNER" "$INSTALL_CANDIDATE" \
    || ! chmod "$ORIGINAL_MODE" "$INSTALL_CANDIDATE" \
    || ! mv -f -- "$INSTALL_CANDIDATE" "$ACME_FILE"; then
    restore_and_restart "The cleaned ACME store could not be installed."
fi
INSTALL_CANDIDATE=""

if ! jq empty "$ACME_FILE" 2>/dev/null; then
    restore_and_restart "Final ACME store validation failed."
fi

readonly FINAL_COUNT="$(jq '.letsencrypt.Certificates | length' "$ACME_FILE")"
if (( FINAL_COUNT != EXPECTED_COUNT )); then
    restore_and_restart "The final certificate count is incorrect."
fi

echo "Starting Traefik..."
if ! docker start "$TRAEFIK_CONTAINER" >/dev/null; then
    restore_and_restart "Traefik did not start with the cleaned ACME store."
fi

sleep 3
if [[ "$(docker inspect -f '{{.State.Running}}' "$TRAEFIK_CONTAINER")" != "true" ]]; then
    restore_and_restart "Traefik is not running after restart."
fi

echo
echo "Cleanup complete"
echo "================"
printf "Before:     %s certificates\n" "$CERT_COUNT"
printf "Removed:    %s certificates\n" "$ORPHAN_COUNT"
printf "Remaining:  %s certificates\n" "$FINAL_COUNT"
printf "\nBackup:\n  %s\n" "$BACKUP"
printf "\nPreserve file:\n  %s\n" "$PRESERVE_FILE"
echo
echo "No additional custom-resolver ACME store was modified."
