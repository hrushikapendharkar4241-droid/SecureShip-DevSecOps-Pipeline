#!/usr/bin/env bash
# Run ShopPilot's backend unit + API tests INSIDE the freshly built image, against a
# throw-away PostgreSQL. Testing the exact artifact that will ship removes the classic
# "passed on the CI box, broke in the container" gap.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
require_cmd docker jq

OUT="$REPORTS_DIR/tests"
mkdir -p "$OUT"
TEST_IMAGE="$BACKEND_IMAGE:$APP_TAG-test"
TEST_DB="${TEST_DB:-postgres}"            # postgres | none
NET="$(helper_network)"
suffix="${BUILD_NUMBER}-$$"
db="secureship-testdb-$suffix"
runner="secureship-tests-$suffix"

cleanup() { docker rm -f "$db" "$runner" >/dev/null 2>&1 || true; }
trap cleanup EXIT

env_args=(-e TESTING=1 -e "APP_VERSION=$APP_TAG" -e ALERTS_ENABLED=false -e SMTP_HOST=
          -e "SECRET_KEY=ci-only-secret-key-not-used-anywhere-else-0123456789")
if [ "$TEST_DB" = "postgres" ]; then
  log "Starting throw-away PostgreSQL for tests ($db)"
  docker run -d --name "$db" --network "$NET" \
    -e POSTGRES_PASSWORD=secureship_test -e POSTGRES_DB=shoppilot postgres:16-alpine >/dev/null
  for _ in $(seq 1 30); do
    docker exec "$db" pg_isready -U postgres -d shoppilot >/dev/null 2>&1 && break
    sleep 1
  done
  # ShopPilot's conftest.py only runs against a database whose name ends in "_test" and differs
  # from DATABASE_URL's, and creates it itself (the postgres superuser has CREATEDB).
  env_args+=(-e "DATABASE_URL=postgresql://postgres:secureship_test@$db:5432/shoppilot"
             -e "TEST_DATABASE_URL=postgresql://postgres:secureship_test@$db:5432/shoppilot_test")
fi

log "Running pytest inside $TEST_IMAGE"
docker create --name "$runner" --network "$NET" "${env_args[@]}" "$TEST_IMAGE" \
  sh -c "mkdir -p /tmp/out && python -m pytest ${PYTEST_ARGS:--q} \
         --junitxml=/tmp/out/junit.xml --cov=. --cov-report=xml:/tmp/out/coverage.xml --cov-report=term" >/dev/null
set +e
docker start -a "$runner"
rc=$?
set -e
docker cp "$runner:/tmp/out/." "$OUT/" >/dev/null 2>&1 || warn "no test output could be copied from the container"

# pytest exit codes: 0 ok, 1 tests failed, 5 no tests collected, other = runner error
case $rc in
  0) write_status "$OUT/tests.status.json" ran "all tests passed" "{\"exit_code\": $rc}"; ok "Tests passed" ;;
  1) write_status "$OUT/tests.status.json" ran "some tests failed" "{\"exit_code\": $rc}"; warn "Some tests failed" ;;
  5) write_status "$OUT/tests.status.json" no_tests "pytest collected no tests" "{\"exit_code\": $rc}"; warn "No tests were collected" ;;
  *) write_status "$OUT/tests.status.json" error "pytest runner error (exit $rc)" "{\"exit_code\": $rc}"; warn "Test runner error (exit $rc)" ;;
esac

# Record failures, but let the policy gate make the decision so every report is still produced.
exit 0
