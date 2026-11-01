#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# 从上游同步代码（本项目采用「main 镜像上游 / 改动全在 dev」的分支约定）
#
# 用法:  scripts/sync-upstream.sh
# 例:    scripts/sync-upstream.sh
#
# 它按顺序做四件事:
#   1. 拉取上游 hartgerinktarcila-design/7kimisu 的全部提交和标签
#   2. 把本地 main 快进到上游（只允许快进，有分叉就报错停下）
#   3. 把 main 镜像推到自己 fork（FIOIU8/7kimisu）
#   4. 把 main 合进 dev，让开发分支跟上基线
#
# 前置要求: 工作区没有未提交的改动（否则会带着脏文件切分支，容易出事）
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
ORIGIN_REMOTE="${ORIGIN_REMOTE:-origin}"
MAIN_BRANCH="${MAIN_BRANCH:-main}"
DEV_BRANCH="${DEV_BRANCH:-dev}"

cd "$(git rev-parse --show-toplevel)"

if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "✗ 有已跟踪文件被修改或已暂存，先 commit 或 stash 再来:" >&2
    git status --short >&2
    exit 1
fi

UNTRACKED="$(git -c core.quotepath=false ls-files --others --exclude-standard)"
if [ -n "$UNTRACKED" ]; then
    echo "! 注意：工作区有未跟踪的新文件，切分支时会一起带过去（不影响同步）:"
    echo "$UNTRACKED" | sed 's/^/    /'
    echo
fi

START_BRANCH="$(git rev-parse --abbrev-ref HEAD)"

echo "==> 1/4 拉取上游 $UPSTREAM_REMOTE"
git fetch "$UPSTREAM_REMOTE" --tags --prune

echo "==> 2/4 快进 $MAIN_BRANCH 到上游"
git switch "$MAIN_BRANCH"
if ! git merge --ff-only "$UPSTREAM_REMOTE/$MAIN_BRANCH"; then
    echo "✗ 本地 $MAIN_BRANCH 与上游已经分叉，无法快进。" >&2
    echo "  这说明有人直接往 main 提交了东西。检查方式:" >&2
    echo "    git log --oneline $MAIN_BRANCH --not $UPSTREAM_REMOTE/$MAIN_BRANCH" >&2
    exit 1
fi

echo "==> 3/4 把 $MAIN_BRANCH 镜像推送到 $ORIGIN_REMOTE"
git push "$ORIGIN_REMOTE" "$MAIN_BRANCH"

echo "==> 4/4 把 $MAIN_BRANCH 合进 $DEV_BRANCH"
git switch "$DEV_BRANCH"
if ! git merge "$MAIN_BRANCH"; then
    echo "!" >&2
    echo "! 合并到 $DEV_BRANCH 时有冲突，解决后执行:" >&2
    echo "!   git add -A && git commit" >&2
    echo "!" >&2
    exit 1
fi

if [ "$START_BRANCH" != "$DEV_BRANCH" ] && [ "$START_BRANCH" != "$MAIN_BRANCH" ]; then
    echo "==> 回到原来的分支 $START_BRANCH"
    git switch "$START_BRANCH"
fi

echo
echo "✓ 同步完成。最近提交:"
git log --oneline --graph --decorate -8
