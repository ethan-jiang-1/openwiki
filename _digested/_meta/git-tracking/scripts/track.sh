#!/usr/bin/env bash
# track.sh — OpenWiki upstream sync 辅助脚本
#
# 用法:
#   ./_digested/_meta/git-tracking/scripts/track.sh status     # 分支/remote/baseline 快照
#   ./_digested/_meta/git-tracking/scripts/track.sh triage     # 上游变更 → 受影响文档
#   ./_digested/_meta/git-tracking/scripts/track.sh new-sync   # 创建预填充的 sync log
#   ./_digested/_meta/git-tracking/scripts/track.sh validate   # 一致性检查
#
# TODO: triage / new-sync / validate 待实现

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
TRACKING_DIR="$REPO_ROOT/_digested/_meta/git-tracking"

cmd="${1:-status}"

case "$cmd" in
  status)
    echo "=== Git Status ==="
    echo "Branch:       $(git -C "$REPO_ROOT" branch --show-current)"
    echo "Main HEAD:    $(git -C "$REPO_ROOT" log --oneline -1 main)"
    echo "Ethan HEAD:   $(git -C "$REPO_ROOT" log --oneline -1 ethan)"
    echo ""
    echo "=== Remotes ==="
    git -C "$REPO_ROOT" remote -v
    ;;

  triage)
    echo "TODO: triage — compare baseline_commit..HEAD and map changed paths to coverage-map.md"
    ;;

  new-sync)
    echo "TODO: new-sync — create pre-filled sync log from TEMPLATE.md"
    ;;

  validate)
    echo "TODO: validate — check sync_event consistency, path validity, coverage-map stats"
    ;;

  *)
    echo "Usage: track.sh {status|triage|new-sync|validate}"
    exit 1
    ;;
esac
