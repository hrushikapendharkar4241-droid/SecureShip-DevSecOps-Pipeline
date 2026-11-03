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

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  if [ -f "$R/SUMMARY.md" ]; then cat "$R/SUMMARY.md" >> "$GITHUB_STEP_SUMMARY"
  else echo "No demo summary – the lab did not get that far. See diagnostics on the lab-results branch." >> "$GITHUB_STEP_SUMMARY"; fi
fi
ls -R "$R" | head -80
