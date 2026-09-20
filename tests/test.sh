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

case_dir="$(run_case dry-run)"
ACME_FILE="$case_dir/acme.json" \
PRESERVE_FILE="$case_dir/preserve.txt" \
TRAEFIK_CONTAINER="traefik" \
    "$SCRIPT" > "$case_dir/output.txt" 2>&1

assert_contains "$case_dir/output.txt" "Orphaned certificates:      1"
assert_contains "$case_dir/output.txt" "stale.example.com"
assert_contains "$case_dir/output.txt" "DRY RUN ONLY"
[[ "$(jq '.letsencrypt.Certificates | length' "$case_dir/acme.json")" == "4" ]] \
    || fail "Dry run changed the ACME store"
if grep -q '^stop ' "$DOCKER_LOG"; then
    fail "Dry run stopped Traefik"
fi

: > "$DOCKER_LOG"
printf 'true\n' > "$DOCKER_STATE"
case_dir="$(run_case delete)"
ACME_FILE="$case_dir/acme.json" \
PRESERVE_FILE="$case_dir/preserve.txt" \
TRAEFIK_CONTAINER="traefik" \
    "$SCRIPT" --delete > "$case_dir/output.txt" 2>&1

assert_contains "$case_dir/output.txt" "Cleanup complete"
[[ "$(jq '.letsencrypt.Certificates | length' "$case_dir/acme.json")" == "3" ]] \
    || fail "Delete mode produced the wrong certificate count"
if jq -e '.letsencrypt.Certificates[] | select(.domain.main == "stale.example.com")' \
    "$case_dir/acme.json" >/dev/null; then
    fail "Stale certificate was not removed"
fi
[[ "$(find "$case_dir" -name 'acme.json.bak-*' | wc -l | tr -d ' ')" == "1" ]] \
    || fail "Delete mode did not create exactly one backup"
assert_contains "$DOCKER_LOG" "stop traefik"
assert_contains "$DOCKER_LOG" "start traefik"
[[ "$(cat "$DOCKER_STATE")" == "true" ]] || fail "Traefik was not restarted"

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
    "$SCRIPT" --delete > "$case_dir/output.txt" 2>&1 && \
    fail "All-certificates safety check unexpectedly succeeded"

assert_contains "$case_dir/output.txt" "Cleanup would remove all certificates"
if grep -q '^stop ' "$DOCKER_LOG"; then
    fail "Safety abort happened after Traefik was stopped"
fi

assert_contains <("$SCRIPT" --version) "1.0.0"

echo "PASS: all tests"
