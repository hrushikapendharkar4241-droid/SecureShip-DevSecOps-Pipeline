#!/usr/bin/env bash
# Push $RESULTS to the results branch ($RESULTS_BRANCH, default lab-results) of the repository
# checked out in the current directory, as runs/<run number>/, and update its index.
set -euo pipefail
R="${RESULTS:?}"; N="${GITHUB_RUN_NUMBER:?}"; dir="${RUNNER_TEMP:-/tmp}/lab-results"
status="${DEMOS_OUTCOME:-unknown}"; B="${RESULTS_BRANCH:-lab-results}"
git config --global user.name "github-actions[bot]"
git config --global user.email "41898282+github-actions[bot]@users.noreply.github.com"
if git fetch -q --depth 1 origin +refs/heads/$B:refs/remotes/origin/$B 2>/dev/null; then
  git worktree add -q -B "$B" "$dir" "origin/$B"
else
  git worktree add -q --orphan -b "$B" "$dir"
fi
rm -rf "${dir:?}/runs/$N"; mkdir -p "$dir/runs/$N"; cp -r "$R"/. "$dir/runs/$N/"
[ -f "$dir/runs.tsv" ] || : > "$dir/runs.tsv"
grep -v "^$N	" "$dir/runs.tsv" > "$dir/runs.tsv.new" || true
printf '%s\t%s\t%s\t%s\n' "$N" "$(date -u '+%Y-%m-%d %H:%M UTC')" "${GITHUB_SHA:0:7}" "$status" >> "$dir/runs.tsv.new"
sort -n "$dir/runs.tsv.new" > "$dir/runs.tsv"; rm "$dir/runs.tsv.new"
{
  echo "# SecureShip lab runs"
  echo
  echo "Results of the end-to-end lab run (\`.github/workflows/lab-e2e.yml\`) on a GitHub-hosted runner:"
  echo "real Jenkins, SonarQube, Trivy, Gitleaks, OWASP ZAP and the lab deployment target, driven by \`ci/demo.sh all\`."
  echo
  echo "| Run | When | Pipeline commit | Scenarios | Results |"
  echo "|---|---|---|---|---|"
  sort -rn "$dir/runs.tsv" | while IFS=$'\t' read -r n when sha st; do
    icon="❌"; [ "$st" = success ] && icon="✅"
    echo "| #$n | $when | \`$sha\` | $icon $st | [runs/$n](runs/$n/SUMMARY.md) |"
  done
} > "$dir/README.md"
git -C "$dir" add -A
git -C "$dir" commit -q -m "Lab run #$N on ${GITHUB_SHA:0:7}: $status" || { echo "nothing to publish"; exit 0; }
git -C "$dir" push -q origin "$B"
echo "Published runs/$N to the $B branch"
