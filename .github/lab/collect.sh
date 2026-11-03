#!/usr/bin/env bash
# Gather what the lab run produced into $RESULTS (runs on the GitHub runner, after the demos).
set -uo pipefail
R="${RESULTS:?}"; W="${GITHUB_WORKSPACE:-$PWD}"; E="$W/demo-evidence"
mkdir -p "$R/builds"
for f in SUMMARY.md scenarios.tsv tamper.txt append-only.txt; do
  [ -f "$E/$f" ] && sed 's/\x1b\[[0-9;]*m//g' "$E/$f" > "$R/$f"
done

# Per build: reports + the end of the Jenkins console (straight from Jenkins, so builds that
# demo.sh never saw are included too)
builds="$(docker exec secureship-jenkins sh -c 'ls /var/jenkins_home/jobs/SecureShip/builds 2>/dev/null' | grep -E '^[0-9]+$' || true)"
for n in $builds; do
  d="$R/builds/$n"; mkdir -p "$d"
  src="/var/jenkins_home/jobs/SecureShip/builds/$n"
  for f in evidence.html evidence.json gate.json deploy.json ledger-verify.json anchor-status.json dast/zap.html; do
    docker cp "secureship-jenkins:$src/archive/reports/$f" "$d/$(basename "$f")" >/dev/null 2>&1 || true
  done
  docker exec secureship-jenkins sh -c "tail -n 500 '$src/log' 2>/dev/null" \
    | sed -e 's/\x1b\[[0-9;]*m//g' -e 's/\x1b\[8m.*\x1b\[0m//g' > "$d/console-tail.txt" || true
done

{
  echo "== $(date -u) =="
  docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Image}}'
  echo; df -h / /mnt 2>/dev/null; echo; free -m
  echo; docker system df 2>/dev/null
} > "$R/diagnostics.txt" 2>&1
for c in secureship-jenkins secureship-sonarqube secureship-lab-target; do
  docker logs --tail 200 "$c" > "$R/logs-$c.txt" 2>&1 || true
done

# Annotations: readable through the checks API, so problems can be diagnosed without the raw log
annotate() {  # annotate <level> <title> <file> <lines>
  local body; body="$(tail -n "$4" "$3" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | sed -e 's/%/%25/g' | sed -e ':a;N;$!ba;s/\n/%0A/g')"
  [ -n "$body" ] && echo "::$1 title=$2::$body"
}
if [ -f "$R/bootstrap.log" ] && ! grep -q "SecureShip lab is running" "$R/bootstrap.log"; then
  annotate error "bootstrap failed" "$R/bootstrap.log" 40
  annotate warning "jenkins log" "$R/logs-secureship-jenkins.txt" 30
fi
for d in "$R"/builds/*/; do
  [ -d "$d" ] || continue
  n="$(basename "$d")"
  if [ -f "$d/gate.json" ] && [ "$(jq -r .decision "$d/gate.json" 2>/dev/null)" = FAIL ]; then
    echo "::warning title=Build $n gate FAIL::$(jq -r '[.blocking_reasons[]? | tostring] | join(" | ")' "$d/gate.json" | cut -c1-3000)"
  fi
  if ! [ -f "$d/evidence.json" ] || [ "$(jq -r .deployment.status "$d/evidence.json" 2>/dev/null)" = NOT_REACHED ]; then
    annotate warning "Build $n console (end)" "$d/console-tail.txt" 45
  elif [ "$(jq -r .deployment.status "$d/evidence.json")" = ROLLED_BACK ] || [ "$(jq -r .deployment.status "$d/evidence.json")" = FAILED ]; then
    annotate notice "Build $n console (end)" "$d/console-tail.txt" 30
  fi
done

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  if [ -f "$R/SUMMARY.md" ]; then cat "$R/SUMMARY.md" >> "$GITHUB_STEP_SUMMARY"
  else echo "No demo summary – the lab did not get that far. See diagnostics on the lab-results branch." >> "$GITHUB_STEP_SUMMARY"; fi
fi
ls -R "$R" | head -80
