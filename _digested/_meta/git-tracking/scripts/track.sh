#!/usr/bin/env bash
# track.sh — OpenWiki upstream sync 辅助脚本
#
# 用法:
#   ./_digested/_meta/git-tracking/scripts/track.sh status     # 分支/remote/基线 + 最新正式发布
#   ./_digested/_meta/git-tracking/scripts/track.sh releases   # 列出所有 stable 发布，标出积压
#   ./_digested/_meta/git-tracking/scripts/track.sh triage     # 上游变更 → 受影响文档（TODO）
#   ./_digested/_meta/git-tracking/scripts/track.sh new-sync   # 创建预填充的 sync log（TODO）
#   ./_digested/_meta/git-tracking/scripts/track.sh validate   # 一致性检查（TODO）
#
# 口径（见 ../git-branch-and-upstream-tracking.md §同步口径）：
#   只跟 stable tag vX.Y.Z；不跟 upstream/main HEAD。
#
# TODO: triage / new-sync / validate 待实现

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
TRACKING_DOC="$REPO_ROOT/_digested/_meta/git-tracking/git-branch-and-upstream-tracking.md"

cmd="${1:-status}"

# stable tag 判定：vX.Y.Z，排除 -rc/-beta/-next 等预发布
is_stable_tag() {
  [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# 按创建时间倒序列出 stable tag，输出 "tag date commit"
stable_tags() {
  git -C "$REPO_ROOT" for-each-ref --sort=-creatordate \
    --format='%(refname:short) %(creatordate:short) %(objectname:short)' refs/tags \
    | while read -r tag date commit; do
        if is_stable_tag "$tag"; then echo "$tag $date $commit"; fi
      done || true
}

# 从追踪文档 frontmatter 读取基线字段
read_baseline() {
  local key="$1"
  [ -f "$TRACKING_DOC" ] || return 0
  sed -n "s/^${key}:[[:space:]]*\"\{0,1\}\([^\"]*\)\"\{0,1\}[[:space:]]*$/\1/p" "$TRACKING_DOC" | head -1 || true
}

case "$cmd" in
  status)
    echo "=== Git Status ==="
    echo "Branch:            $(git -C "$REPO_ROOT" branch --show-current)"
    echo "main HEAD:         $(git -C "$REPO_ROOT" log --oneline -1 main)"
    echo "ethan HEAD:        $(git -C "$REPO_ROOT" log --oneline -1 ethan)"
    echo "upstream/main:     $(git -C "$REPO_ROOT" log --oneline -1 upstream/main 2>/dev/null || echo '<no upstream/main ref>')"
    echo ""

    echo "=== Remotes ==="
    git -C "$REPO_ROOT" remote -v
    echo ""

    baseline_tag="$(read_baseline baseline_tag)"
    baseline_commit="$(read_baseline baseline_commit)"
    latest="$(stable_tags | head -1)"

    echo "=== Release Tracking (release-only) ==="
    echo "Latest upstream:   ${latest:-<no stable tag fetched>}"
    echo "Recorded baseline: ${baseline_tag:-<unset>} (${baseline_commit:-<unset>})"

    if [ -n "$baseline_commit" ] && git -C "$REPO_ROOT" rev-parse -q --verify "$baseline_commit^{commit}" >/dev/null 2>&1; then
      # baseline 之后发布的 stable tag：包含 baseline commit 的 tag 集合里去掉 baseline 自身
      backlog="$(git -C "$REPO_ROOT" tag --contains "$baseline_commit" --sort=creatordate \
        | while read -r t; do
            if is_stable_tag "$t" && [ "$t" != "$baseline_tag" ]; then echo "$t"; fi
          done || true)"
      if [ -n "$backlog" ]; then
        echo "Backlog:           $(printf '%s\n' "$backlog" | wc -l | tr -d ' ') release(s) not yet baselined"
        printf '%s\n' "$backlog" | sed 's/^/  - /'
      else
        echo "Backlog:           none (baseline is current)"
      fi
      ahead="$(git -C "$REPO_ROOT" rev-list --count "${baseline_tag:-$baseline_commit}..upstream/main" 2>/dev/null || echo '?')"
      echo "upstream/main:     ${ahead} commit(s) ahead of baseline (NOT tracked until next tag)"
    fi
    ;;

  releases)
    baseline_tag="$(read_baseline baseline_tag)"
    baseline_commit="$(read_baseline baseline_commit)"
    printf "%-9s %-12s %-9s %s\n" "TAG" "DATE" "COMMIT" "STATE"
    stable_tags | while read -r tag date commit; do
      state="released"
      if [ -n "$baseline_commit" ] && git -C "$REPO_ROOT" merge-base --is-ancestor "$tag" "$baseline_commit" 2>/dev/null; then
        state="baselined"
      fi
      if [ "$tag" = "$baseline_tag" ]; then state="BASELINE"; fi
      printf "%-9s %-12s %-9s %s\n" "$tag" "$date" "$commit" "$state"
    done
    ;;

  triage)
    echo "TODO: triage — compare baseline_commit..<latest tag> and map changed paths to coverage-map.md"
    ;;

  new-sync)
    echo "TODO: new-sync — create pre-filled sync log from TEMPLATE.md"
    ;;

  validate)
    echo "TODO: validate — check sync_event consistency, path validity, coverage-map stats"
    ;;

  *)
    echo "Usage: track.sh {status|releases|triage|new-sync|validate}"
    exit 1
    ;;
esac
