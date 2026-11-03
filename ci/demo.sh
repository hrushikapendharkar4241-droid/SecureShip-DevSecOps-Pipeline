#!/usr/bin/env bash
# One-command helpers for the demo scenarios in docs/DEMO_SCENARIOS.md. Run from the repo root
# in Git Bash / WSL / Linux, with the lab running.
#
#   ./ci/demo.sh branches [path-to-shoppilot]   create + push the three "bad" ShopPilot branches
#                                               (default path: ~/SareeERP-Pro). master is not touched.
#   ./ci/demo.sh tamper                         scenario 6: edit / delete ledger entries, show what
#                                               detects it, then restore the ledger
#   ./ci/demo.sh append-only                    scenario 6b: show the anchor store can't be truncated
#   ./ci/demo.sh evidence <build-number>        copy that build's reports to ./demo-evidence/<n>/
#   ./ci/demo.sh build [KEY=VALUE&...]          start one Jenkins build, wait, print "<n> <result> <gate> <deploy>"
#   ./ci/demo.sh all [path-to-shoppilot]        EVERYTHING, unattended (~1.5–2 h): clean releases, rollback,
#                                               blocked builds, tamper demo -> demo-evidence/SUMMARY.md
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash: don't rewrite /var/... container paths into C:/Program Files/...

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JENKINS=secureship-jenkins
TARGET=secureship-lab-target
say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }

cmd_branches() {
  local repo="${1:-$HOME/SareeERP-Pro}" base tmp tok
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || fail "$repo is not a Git repository – pass the ShopPilot folder"
  base="$(git -C "$repo" rev-parse --abbrev-ref origin/HEAD 2>/dev/null | sed 's#^origin/##')"; base="${base:-master}"
  git -C "$repo" fetch -q origin "$base" || { echo "  could not fetch ShopPilot from GitHub"; return 1; }
  tmp="$(mktemp -d)"
  make_branch() {  # make_branch <name> <message> <change-function>
    local name="$1" msg="$2" fn="$3" wt="$tmp/${1//\//-}"
    git -C "$repo" worktree add -q -B "$name" "$wt" "origin/$base" || return 1
    ( cd "$wt" && "$fn" && git add -A && git commit -q -m "$msg" ) || return 1
    git -C "$repo" push -q -f -u origin "$name" || { echo "  could not push $name"; return 1; }
    git -C "$repo" worktree remove --force "$wt" || true
    printf '  \033[32m✔\033[0m pushed %s\n' "$name"
  }
  ch_vuln()   { printf '\n# DEMO ONLY: old version with a known HIGH CVE (CVE-2019-10906, fixed in 2.10.1)\nJinja2==2.10\n' >> backend/requirements.txt; }
  ch_test()   { printf 'def test_demo_failure():\n    """DEMO ONLY: proves a failing test blocks the release."""\n    assert 1 == 2\n' > backend/tests/test_demo_failure.py; }
  ch_secret() {  # a FAKE token (random characters) in GitHub's token format – not a real credential
    tok="ghp_$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 36)"
    printf '# DEMO ONLY: fake credential to prove secret scanning blocks the release\nGITHUB_TOKEN = "%s"\n' "$tok" > backend/leak_demo.py
  }
  say "Creating demo branches in $repo from origin/$base (your working folder and $base are not changed)"
  make_branch demo/vulnerable-dep "demo: add vulnerable dependency" ch_vuln   || return 1
  make_branch demo/failing-test   "demo: add failing test"         ch_test   || return 1
  make_branch demo/leaked-secret  "demo: add fake hard-coded token" ch_secret || return 1
  rm -rf "$tmp"
  cat <<EOF

  Now in Jenkins → SecureShip → Build with Parameters, run once each with APP_BRANCH =
    demo/vulnerable-dep   → gate FAIL (HIGH fixable CVE), deploy skipped
    demo/failing-test     → gate FAIL (1 failing test)
    demo/leaked-secret    → gate FAIL (github-pat secret)
  Delete them afterwards with:  git -C "$repo" push origin --delete demo/vulnerable-dep demo/failing-test demo/leaked-secret
EOF
}

cmd_tamper() {
  running "$JENKINS" || fail "Jenkins is not running – start the lab first"
  docker exec -i "$JENKINS" bash -s <<'IN'
set -uo pipefail
cd /var/jenkins_home/workspace/SecureShip 2>/dev/null || { echo "Run the SecureShip job at least once first"; exit 1; }
export LEDGER_KEY="$LEDGER_HMAC_KEY"
install -m 600 /run/secrets/deploy_key /tmp/demo_key && export SSH_KEY=/tmp/demo_key
export LEDGER_PATH="${LEDGER_PATH:-/var/jenkins_home/secureship/ledger.jsonl}"; L="$LEDGER_PATH"
n="$(grep -c . "$L" 2>/dev/null || echo 0)"
[ "$n" -ge 3 ] || { echo "The ledger has $n entries – run at least 3 builds first"; exit 1; }
cp "$L" /tmp/ledger.bak
trap 'cp /tmp/ledger.bak "$L"; rm -f /tmp/demo_key' EXIT
hdr() { printf '\n\033[1;35m━━━ %s ━━━\033[0m\n' "$*"; }

hdr "0. Untouched ledger ($n entries): full check (chain + HMAC + external anchors)"
scripts/verify-ledger.sh

hdr "A. Attacker rewrites an OLD entry (#1): risk score set to 0 to make that release look clean"
python3 - "$L" <<'PY'
import json, sys
p = sys.argv[1]; lines = open(p, encoding="utf-8").read().splitlines()
e = json.loads(lines[0])
show = lambda: {k: e.get(k) for k in ("seq", "build", "gate_decision", "risk_score", "deploy_status")}
print("   before:", show()); e["risk_score"] = 0; print("   after :", show())
lines[0] = json.dumps(e, sort_keys=True)
open(p, "w", encoding="utf-8").write("\n".join(lines) + "\n")
PY
scripts/verify-ledger.sh
cp /tmp/ledger.bak "$L"

hdr "B. Attacker DELETES the 2 NEWEST entries – the attack a hash chain alone cannot see"
head -n -2 /tmp/ledger.bak > "$L"
echo "   Chain + HMAC only (no anchors):"
python3 -m secureship ledger verify --ledger "$L"
echo
echo "   With the external anchors on the deployment server:"
scripts/verify-ledger.sh

cp /tmp/ledger.bak "$L"
hdr "Restored the original ledger – check again"
scripts/verify-ledger.sh
IN
}

cmd_append_only() {
  running "$TARGET" || fail "lab-target is not running"
  local f=/opt/secureship/anchors/ledger-anchors.jsonl
  say "Anchor store attributes ('a' = append-only)"
  docker exec "$TARGET" lsattr "$f" || true
  say "The deploy user (= what a compromised Jenkins can do) tries to wipe the anchors"
  if docker exec -u deploy "$TARGET" sh -c ": > $f" 2>&1; then
    echo "  !! truncation succeeded – this filesystem does not support chattr +a (see SECURITY_POLICY.md, Honest limits)"
  else
    printf '  \033[32m✔ blocked\033[0m – the deploy user can append, but cannot truncate or delete the file\n'
  fi
  say "...and tries to delete it"
  if docker exec -u deploy "$TARGET" rm "$f" 2>&1; then echo "  !! delete succeeded"; else printf '  \033[32m✔ blocked\033[0m\n'; fi
  docker exec "$TARGET" sh -c "wc -l < $f | xargs echo '  anchors still present:'"
}

cmd_evidence() {
  local b="${1:?usage: ./ci/demo.sh evidence <build-number>}" out
  [[ "$b" =~ ^[0-9]+$ ]] || fail "build number must be numeric"
  out="$ROOT/demo-evidence/$b"; mkdir -p "$out"
  docker cp "$JENKINS:/var/jenkins_home/jobs/SecureShip/builds/$b/archive/reports/." "$out/" \
    || fail "no archived reports for build #$b"
  echo "  copied to demo-evidence/$b/ – open evidence.html in your browser"
}

# Start a Jenkins build through its REST API (from inside the Jenkins container, which has curl + jq),
# wait for it, print "<number> <jenkins-result> <gate-decision> <deploy-status>".
jenkins_build() {
  running "$JENKINS" || fail "Jenkins is not running – start the lab first (./ci/bootstrap.sh)"
  docker exec -i -e "PARAMS=${1:-}" "$JENKINS" bash -s <<'IN'
set -euo pipefail
J=http://localhost:8080; jar="$(mktemp)"; trap 'rm -f "$jar"' EXIT
c() { curl -fsS -u "$JENKINS_ADMIN_ID:$JENKINS_ADMIN_PASSWORD" -c "$jar" -b "$jar" "$@"; }
hdr="$(c "$J/crumbIssuer/api/json" | jq -r '.crumbRequestField + ": " + .crumb')"
if c "$J/job/SecureShip/api/json" | jq -e '[.property[]? | select(.parameterDefinitions)] | length > 0' >/dev/null; then
  url="$J/job/SecureShip/buildWithParameters"
else
  url="$J/job/SecureShip/build"   # very first run: parameters are registered by this build (defaults apply)
fi
loc="$(c -D - -o /dev/null -H "$hdr" -X POST --data "${PARAMS:-}" "$url" | tr -d '\r' | awk 'tolower($1)=="location:" {print $2}')"
[ -n "$loc" ] || { echo "Jenkins did not queue the build" >&2; exit 1; }
n=""
for _ in $(seq 1 720); do
  n="$(c "${loc%/}/api/json" | jq -r '.executable.number // empty')"; [ -n "$n" ] && break; sleep 5
done
[ -n "$n" ] || { echo "build never left the queue" >&2; exit 1; }
start=$(date +%s); last=0
printf '   build #%s started (%s)\n' "$n" "${PARAMS:-defaults}" >&2
while :; do
  j="$(c "$J/job/SecureShip/$n/api/json")"
  [ "$(jq -r .building <<<"$j")" = "false" ] && break
  now=$(date +%s)
  if [ $((now - last)) -ge 120 ]; then
    stage="$(c "$J/job/SecureShip/$n/wfapi/describe" 2>/dev/null | jq -r '[.stages[]? | select(.status=="IN_PROGRESS") | .name] | join(", ")' 2>/dev/null || true)"
    printf '   … #%s %d min – %s\n' "$n" $(((now - start) / 60)) "${stage:-starting}" >&2; last=$now
  fi
  sleep 15
done
ev="$JENKINS_HOME/jobs/SecureShip/builds/$n/archive/reports/evidence.json"
gate="$(jq -r '.gate.decision // "NONE"' "$ev" 2>/dev/null || echo NONE)"
dep="$(jq -r '.deployment.status // "NONE"' "$ev" 2>/dev/null || echo NONE)"
c "$J/job/SecureShip/$n/consoleText" > "/tmp/console-$n.txt" 2>/dev/null || true
echo "$n $(jq -r '.result // "UNKNOWN"' <<<"$j") $gate $dep"
IN
}

save_build() {  # save_build <n> – reports + console log into demo-evidence/<n>/
  local n="$1" out="$ROOT/demo-evidence/$1"
  mkdir -p "$out"
  docker cp "$JENKINS:/var/jenkins_home/jobs/SecureShip/builds/$n/archive/reports/." "$out/" >/dev/null 2>&1 || true
  docker cp "$JENKINS:/tmp/console-$n.txt" "$out/console.txt" >/dev/null 2>&1 || true
}

cmd_all() {
  local repo="${1:-$HOME/SareeERP-Pro}" sum="$ROOT/demo-evidence/SUMMARY.md" n res gate dep ok all_ok=1
  running "$JENKINS" && running "$TARGET" || fail "the lab is not running – run ./ci/bootstrap.sh first"
  mkdir -p "$ROOT/demo-evidence"
  # Jenkins answers /login before configuration-as-code has created the job
  for _ in $(seq 1 60); do
    docker exec "$JENKINS" sh -c 'curl -fsS -o /dev/null -u "$JENKINS_ADMIN_ID:$JENKINS_ADMIN_PASSWORD" http://localhost:8080/job/SecureShip/api/json' && break
    sleep 5
  done
  {
    echo "# SecureShip demo run – $(date '+%Y-%m-%d %H:%M')"
    echo
    echo "| Scenario | Jenkins build | Jenkins result | Gate | Deployment | Expected | OK |"
    echo "|---|---|---|---|---|---|---|"
  } > "$sum"

  : > "$ROOT/demo-evidence/scenarios.tsv"
  run() {  # run <scenario> <params> <expected-deploy-status>
    say "Scenario: $1"
    if ! read -r n res gate dep < <(jenkins_build "$2"); then
      echo "  could not run this build"; all_ok=0; return 1
    fi
    save_build "$n"
    ok="❌"; [ "$dep" = "$3" ] && ok="✅"
    [ "$ok" = "✅" ] || all_ok=0
    printf '   #%s  result=%s  gate=%s  deployment=%s  (expected %s) %s\n' "$n" "$res" "$gate" "$dep" "$3" "$ok"
    echo "| $1 | #$n | $res | $gate | $dep | $3 | $ok |" >> "$sum"
    printf '%s\t%s\t%s\t%s\n' "${1%%.*}" "$n" "$dep" "$3" >> "$ROOT/demo-evidence/scenarios.tsv"
    [ "$ok" = "✅" ]
  }

  if ! run "1. Clean release" "" DEPLOYED; then
    printf '\n\033[1;33mThe first clean release did not deploy – stopping here.\033[0m\n'
    echo "  Reports for build #${n:-?} are in demo-evidence/${n:-?}/ (gate.json, console.txt)."
    exit 1
  fi
  [ "${DEMO_ONLY_FIRST:-0}" = 1 ] && { say "DEMO_ONLY_FIRST=1 – stopping after the first release"; cat "$sum"; return 0; }
  run "1b. Clean release (second, gives rollback a target)" "" DEPLOYED || true
  run "5. Chaos: backend crashes on start → automatic rollback" "CHAOS_MODE=crash" ROLLED_BACK || true
  run "5b. Chaos: /health lies → automatic rollback" "CHAOS_MODE=unhealthy" ROLLED_BACK || true

  say "Creating the demo branches in ShopPilot"
  # DEMO_BRANCHES=existing: the demo/* branches are already on GitHub (e.g. a CI run without push rights)
  if [ "${DEMO_BRANCHES:-push}" = existing ] || cmd_branches "$repo"; then
    run "2. Vulnerable dependency (Jinja2 2.10)" "APP_BRANCH=demo/vulnerable-dep" BLOCKED_BY_GATE || true
    run "3. Failing unit test" "APP_BRANCH=demo/failing-test" BLOCKED_BY_GATE || true
    run "4. Hard-coded (fake) GitHub token" "APP_BRANCH=demo/leaked-secret" BLOCKED_BY_GATE || true
  else
    echo "| 2–4. Demo branches | – | could not push the branches | | | | ❌ |" >> "$sum"; all_ok=0
  fi
  run "Final clean release (leave the good version running)" "" DEPLOYED || true

  say "Scenario 6: tampering with the release ledger"
  cmd_tamper 2>&1 | tee "$ROOT/demo-evidence/tamper.txt" || true
  cmd_append_only 2>&1 | tee "$ROOT/demo-evidence/append-only.txt" || true
  sed -i 's/\x1b\[[0-9;]*m//g' "$ROOT/demo-evidence/tamper.txt" "$ROOT/demo-evidence/append-only.txt" 2>/dev/null || true
  {
    echo
    echo "Ledger tampering demo: see [tamper.txt](tamper.txt) and [append-only.txt](append-only.txt)."
    echo "Each build's \`evidence.html\` is in its numbered folder."
  } >> "$sum"

  say "Done"
  cat "$sum"
  echo "Open http://localhost:8088 (ShopPilot) and Jenkins' SecureShip page for the screenshots."
  if [ "$all_ok" = 1 ]; then printf '\n\033[32mAll scenarios behaved as expected.\033[0m\n'; else printf '\n\033[33mSome scenarios did not match – see above.\033[0m\n'; return 1; fi
}

case "${1:-}" in
  branches)    shift; cmd_branches "$@" ;;
  tamper)      cmd_tamper ;;
  append-only) cmd_append_only ;;
  evidence)    shift; cmd_evidence "$@" ;;
  build)       shift; jenkins_build "${1:-}" ;;
  all)         shift; cmd_all "$@" ;;
  *) sed -n '2,14p' "$0"; exit 1 ;;
esac
