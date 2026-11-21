#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
readonly SCRIPT="$ROOT_DIR/traefik-acme-cleanup.sh"
readonly FIXTURES="$ROOT_DIR/tests/fixtures"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    local file="$1"
    local expected="$2"
    grep -Fq -- "$expected" "$file" \
        || fail "Expected '$expected' in $file"
}

expect_failure() {
    local description="$1"
    shift
    if "$@" > "$TEST_DIR/last-failure.txt" 2>&1; then
        fail "Expected a non-zero exit code: $description"
    fi
}

count_backups() {
    find "$1" -maxdepth 1 -name 'acme.json.bak-*' | wc -l | tr -d ' '
}

mkdir -p "$TEST_DIR/bin"

cat > "$TEST_DIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$DOCKER_LOG"
case "$1" in
    inspect)
        if [[ "${2:-}" == "-f" ]]; then
            cat "$DOCKER_STATE"
        fi
        ;;
    exec)
        cat "$ROUTERS_FIXTURE"
        ;;
    stop)
        printf 'false\n' > "$DOCKER_STATE"
        ;;
    start)
        printf 'true\n' > "$DOCKER_STATE"
        ;;
    *) exit 2 ;;
esac
EOF

cat > "$TEST_DIR/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$TEST_DIR/bin/stat" <<'EOF'
#!/usr/bin/env bash
set -eu
if [[ "$(uname -s)" == "Darwin" ]]; then
    case "$2" in
        %u:%g) exec /usr/bin/stat -f '%u:%g' "$3" ;;
        %a) exec /usr/bin/stat -f '%Lp' "$3" ;;
    esac
fi
exec /usr/bin/stat "$@"
EOF

chmod +x "$TEST_DIR/bin/docker" "$TEST_DIR/bin/sleep" "$TEST_DIR/bin/stat"

export PATH="$TEST_DIR/bin:$PATH"
export DOCKER_LOG="$TEST_DIR/docker.log"
export DOCKER_STATE="$TEST_DIR/docker.state"
export ROUTERS_FIXTURE="$FIXTURES/routers.json"
printf 'true\n' > "$DOCKER_STATE"
: > "$DOCKER_LOG"

run_case() {
    local case_name="$1"
    local case_dir="$TEST_DIR/$case_name"
    mkdir -p "$case_dir"
    cp "$FIXTURES/acme.json" "$case_dir/acme.json"
    printf '# Keep while offline\nPRESERVED.EXAMPLE.COM\n' > "$case_dir/preserve.txt"
    printf '%s\n' "$case_dir"
}

# ---------------------------------------------------------------- help/version

bash "$SCRIPT" --help > "$TEST_DIR/help.txt" 2>&1 \
    || fail "--help exited non-zero"
assert_contains "$TEST_DIR/help.txt" "Usage:"
assert_contains "$TEST_DIR/help.txt" "--dry-run"
assert_contains "$TEST_DIR/help.txt" "TRAEFIK_API_URL"

assert_contains <(bash "$SCRIPT" --version) "1.1.0"

# ------------------------------------------------------------ argument parsing

expect_failure "unknown argument" bash "$SCRIPT" --bogus
assert_contains "$TEST_DIR/last-failure.txt" "Unknown argument: --bogus"

expect_failure "--force without --delete" bash "$SCRIPT" --force
assert_contains "$TEST_DIR/last-failure.txt" "--force is only accepted together with --delete"

# ------------------------------------------------------------------ invalid store

case_dir="$(run_case invalid-json)"
printf 'not-json\n' > "$case_dir/acme.json"
expect_failure "invalid ACME store" \
    env ACME_FILE="$case_dir/acme.json" \
        PRESERVE_FILE="$case_dir/preserve.txt" \
        TRAEFIK_CONTAINER="traefik" \
        bash "$SCRIPT" --dry-run
assert_contains "$TEST_DIR/last-failure.txt" "not valid JSON"

# --------------------------------------------------------------------- dry run

: > "$DOCKER_LOG"
printf 'true\n' > "$DOCKER_STATE"
case_dir="$(run_case dry-run)"
ACME_FILE="$case_dir/acme.json" \
PRESERVE_FILE="$case_dir/preserve.txt" \
TRAEFIK_CONTAINER="traefik" \
    bash "$SCRIPT" > "$case_dir/output.txt" 2>&1

assert_contains "$case_dir/output.txt" "Orphaned certificates:      1"
assert_contains "$case_dir/output.txt" "stale.example.com"
assert_contains "$case_dir/output.txt" "DRY RUN ONLY"
assert_contains "$case_dir/output.txt" "Wildcard protection:        on (1)"
assert_contains "$case_dir/output.txt" "*.wildcard.example.com"
[[ "$(jq '.letsencrypt.Certificates | length' "$case_dir/acme.json")" == "5" ]] \
    || fail "Dry run changed the ACME store"
if grep -q '^stop ' "$DOCKER_LOG"; then
    fail "Dry run stopped Traefik"
fi

# ------------------------------------------------ explicit --dry-run flag is equal

: > "$DOCKER_LOG"
printf 'true\n' > "$DOCKER_STATE"
case_dir="$(run_case dry-run-flag)"
ACME_FILE="$case_dir/acme.json" \
PRESERVE_FILE="$case_dir/preserve.txt" \
TRAEFIK_CONTAINER="traefik" \
    bash "$SCRIPT" --dry-run > "$case_dir/output.txt" 2>&1
assert_contains "$case_dir/output.txt" "DRY RUN ONLY"

# ------------------------------------------------------- TRAEFIK_API_URL override

: > "$DOCKER_LOG"
printf 'true\n' > "$DOCKER_STATE"
case_dir="$(run_case api-url)"
ACME_FILE="$case_dir/acme.json" \
PRESERVE_FILE="$case_dir/preserve.txt" \
TRAEFIK_CONTAINER="traefik" \
TRAEFIK_API_URL="http://127.0.0.1:9999" \
    bash "$SCRIPT" > "$case_dir/output.txt" 2>&1
assert_contains "$case_dir/output.txt" "DRY RUN ONLY"
assert_contains "$DOCKER_LOG" "http://127.0.0.1:9999/api/http/routers"
if grep -Fq "127.0.0.1:8080" "$DOCKER_LOG"; then
    fail "Default API URL was used despite TRAEFIK_API_URL override"
fi

# ------------------------------------------------- wildcard protection disabled

: > "$DOCKER_LOG"
printf 'true\n' > "$DOCKER_STATE"
case_dir="$(run_case wildcards-off)"
ACME_FILE="$case_dir/acme.json" \
PRESERVE_FILE="$case_dir/preserve.txt" \
TRAEFIK_CONTAINER="traefik" \
PROTECT_WILDCARDS=0 \
    bash "$SCRIPT" > "$case_dir/output.txt" 2>&1
assert_contains "$case_dir/output.txt" "Orphaned certificates:      2"
assert_contains "$case_dir/output.txt" "*.wildcard.example.com"
assert_contains "$case_dir/output.txt" "Wildcard protection:        off (1)"
assert_contains "$case_dir/output.txt" "DRY RUN ONLY"

# ----------------------------------------------------------------- delete mode

: > "$DOCKER_LOG"
printf 'true\n' > "$DOCKER_STATE"
case_dir="$(run_case delete)"
ACME_FILE="$case_dir/acme.json" \
PRESERVE_FILE="$case_dir/preserve.txt" \
TRAEFIK_CONTAINER="traefik" \
    bash "$SCRIPT" --delete > "$case_dir/output.txt" 2>&1

assert_contains "$case_dir/output.txt" "Cleanup complete"
[[ "$(jq '.letsencrypt.Certificates | length' "$case_dir/acme.json")" == "4" ]] \
    || fail "Delete mode produced the wrong certificate count"
if jq -e '.letsencrypt.Certificates[] | select(.domain.main == "stale.example.com")' \
    "$case_dir/acme.json" >/dev/null; then
    fail "Stale certificate was not removed"
fi
if jq -e '.letsencrypt.Certificates[] | select(.domain.main == "active.example.com")' \
    "$case_dir/acme.json" >/dev/null; then :; else
    fail "Active certificate was removed"
fi
if jq -e '.letsencrypt.Certificates[] | select(.domain.main == "preserved.example.com")' \
    "$case_dir/acme.json" >/dev/null; then :; else
    fail "Preserved certificate was removed"
fi
if jq -e '.letsencrypt.Certificates[] | select(.domain.main == "*.wildcard.example.com")' \
    "$case_dir/acme.json" >/dev/null; then :; else
    fail "Wildcard certificate was removed despite protection"
fi
[[ "$(count_backups "$case_dir")" == "1" ]] \
    || fail "Delete mode did not create exactly one backup"
assert_contains "$DOCKER_LOG" "stop traefik"
assert_contains "$DOCKER_LOG" "start traefik"
[[ "$(cat "$DOCKER_STATE")" == "true" ]] || fail "Traefik was not restarted"

# ------------------------------------------------------------- backup retention

: > "$DOCKER_LOG"
printf 'true\n' > "$DOCKER_STATE"
case_dir="$(run_case retention)"
touch -d '2026-01-01 00:00:00' "$case_dir/acme.json.bak-20260101-000000"
touch -d '2026-01-02 00:00:00' "$case_dir/acme.json.bak-20260102-000000"
touch -d '2026-01-03 00:00:00' "$case_dir/acme.json.bak-20260103-000000"
ACME_FILE="$case_dir/acme.json" \
PRESERVE_FILE="$case_dir/preserve.txt" \
TRAEFIK_CONTAINER="traefik" \
KEEP_BACKUPS=2 \
    bash "$SCRIPT" --delete > "$case_dir/output.txt" 2>&1
assert_contains "$case_dir/output.txt" "Cleanup complete"
assert_contains "$case_dir/output.txt" "Pruning old backups (keeping 2)"
[[ "$(count_backups "$case_dir")" == "2" ]] \
    || fail "Backup retention did not keep exactly two backups"
[[ -f "$case_dir/acme.json.bak-20260103-000000" ]] \
    || fail "Backup retention pruned the wrong files"
[[ ! -f "$case_dir/acme.json.bak-20260101-000000" ]] \
    || fail "Oldest backup was retained"
[[ ! -f "$case_dir/acme.json.bak-20260102-000000" ]] \
    || fail "Second-oldest backup was retained"

# --------------------------------------------------------- remove-all safeguard

: > "$DOCKER_LOG"
printf 'true\n' > "$DOCKER_STATE"
case_dir="$(run_case safety)"
cat > "$case_dir/routers.json" <<'EOF'
[{"name":"unknown@docker","rule":"Host(`unknown.example.com`)","tls":{"certResolver":"letsencrypt"}}]
EOF
ROUTERS_FIXTURE="$case_dir/routers.json" \
ACME_FILE="$case_dir/acme.json" \
PRESERVE_FILE="$case_dir/missing-preserve.txt" \
TRAEFIK_CONTAINER="traefik" \
PROTECT_WILDCARDS=0 \
    bash "$SCRIPT" --delete > "$case_dir/output.txt" 2>&1 && \
    fail "All-certificates safety check unexpectedly succeeded"

assert_contains "$case_dir/output.txt" "Cleanup would remove all certificates"
assert_contains "$case_dir/output.txt" "--delete --force"
if grep -q '^stop ' "$DOCKER_LOG"; then
    fail "Safety abort happened after Traefik was stopped"
fi

# --------------------------------------------------- --force overrides safeguard

: > "$DOCKER_LOG"
printf 'true\n' > "$DOCKER_STATE"
case_dir="$(run_case force)"
cat > "$case_dir/routers.json" <<'EOF'
[{"name":"unknown@docker","rule":"Host(`unknown.example.com`)","tls":{"certResolver":"letsencrypt"}}]
EOF
ROUTERS_FIXTURE="$case_dir/routers.json" \
ACME_FILE="$case_dir/acme.json" \
PRESERVE_FILE="$case_dir/missing-preserve.txt" \
TRAEFIK_CONTAINER="traefik" \
PROTECT_WILDCARDS=0 \
    bash "$SCRIPT" --delete --force > "$case_dir/output.txt" 2>&1 \
    || fail "--delete --force failed unexpectedly"
assert_contains "$case_dir/output.txt" "Cleanup complete"
[[ "$(jq '.letsencrypt.Certificates | length' "$case_dir/acme.json")" == "0" ]] \
    || fail "--delete --force left certificates behind"
assert_contains "$DOCKER_LOG" "start traefik"
[[ "$(cat "$DOCKER_STATE")" == "true" ]] || fail "Traefik was not restarted"

echo "PASS: all tests"
