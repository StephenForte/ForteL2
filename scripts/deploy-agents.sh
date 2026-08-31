#!/usr/bin/env bash
# Deploy the pinned agent execution tree (D-0113 Finding 2).
#
# Launchd jobs must not execute out of the mutable ~/ForteL2 checkout — parallel
# workers check branches out there at will. This script maintains a standalone
# clone at /Users/steveforte/fortel2-agents, on main, fast-forward-only from
# origin/main. Secrets stay in the dev checkout; the pinned tree gets symlinks.
#
# A worktree was considered and rejected: worktrees share .git with the checkout
# a worker can `git worktree remove` / prune. A sibling clone survives that.
#
# The pinned tree changes only when the operator runs this script. Agent
# entrypoints do not self-update or refuse-if-not-main (a fail-closed guard
# there can take the 03:00 wake down).
#
# Never resets, never force-updates. Dirty / diverged / not-main is an operator
# decision point (nonzero + a distinct message).
#
# Test-only overrides (never set in env files):
#   FORTEL2_AGENTS_DIR  FORTEL2_DEV_DIR  FORTEL2_AGENTS_REMOTE
set -euo pipefail

PINNED="${FORTEL2_AGENTS_DIR:-/Users/steveforte/fortel2-agents}"
DEV="${FORTEL2_DEV_DIR:-/Users/steveforte/ForteL2}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# Distinct refusal strings — test-helpers greps each; do not reword without
# updating those assertions.
die_dirty() { die "pinned tree is dirty — refuse to update (operator decision)"; }
die_diverged() { die "pinned tree has diverged from origin/main — refuse to update (operator decision)"; }
die_not_main() {
  die "pinned tree is not on branch main (on ${1:-unknown}) — refuse to update (operator decision)"
}
die_regular_env() {
  die "refusing to overwrite existing file with a symlink ($1) — operator must move it aside"
}

in_git() {
  git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

branch_of() {
  git -C "$1" rev-parse --abbrev-ref HEAD
}

is_dirty() {
  [[ -n "$(git -C "$1" status --porcelain)" ]]
}

resolve_remote() {
  if [[ -n "${FORTEL2_AGENTS_REMOTE:-}" ]]; then
    printf '%s' "$FORTEL2_AGENTS_REMOTE"
    return
  fi
  if in_git "$DEV"; then
    git -C "$DEV" remote get-url origin 2>/dev/null && return
  fi
  printf '%s' "https://github.com/StephenForte/ForteL2.git"
}

# $1 = name (.env.sepolia / .env). Missing source: required for .env.sepolia,
# optional for .env. Existing regular file in the pinned tree → refuse (never
# silently replace a real file with a symlink). Existing correct symlink → ok.
ensure_env_symlink() {
  local name="$1"
  local required="${2:-0}"
  local src="$DEV/$name"
  local dst="$PINNED/$name"

  if [[ ! -e "$src" && ! -L "$src" ]]; then
    if [[ "$required" -eq 1 ]]; then
      die "$name is missing in the dev checkout ($src) — agents need one source of secrets"
    fi
    return 0
  fi

  if [[ -L "$dst" ]]; then
    local target
    target="$(readlink "$dst")"
    if [[ "$target" == "$src" ]]; then
      echo "symlink $name → $src (already)"
      return 0
    fi
    die "symlink $dst points at $target, expected $src — refuse to retarget (operator decision)"
  fi

  if [[ -e "$dst" ]]; then
    die_regular_env "$dst"
  fi

  ln -s "$src" "$dst"
  echo "symlink $name → $src (created)"
}

REMOTE="$(resolve_remote)"

if [[ -e "$PINNED" && ! -d "$PINNED" ]]; then
  die "pinned path exists and is not a directory: $PINNED"
fi

if [[ -d "$PINNED" ]]; then
  in_git "$PINNED" || die "path exists but is not a git checkout: $PINNED"

  local_branch="$(branch_of "$PINNED")"
  if [[ "$local_branch" != "main" ]]; then
    die_not_main "$local_branch"
  fi
  if is_dirty "$PINNED"; then
    die_dirty
  fi

  git -C "$PINNED" fetch origin
  if ! git -C "$PINNED" rev-parse --verify -q origin/main >/dev/null; then
    die "origin/main is missing after fetch"
  fi
  if ! git -C "$PINNED" merge-base --is-ancestor HEAD origin/main; then
    die_diverged
  fi
  if ! git -C "$PINNED" merge --ff-only origin/main; then
    die_diverged
  fi
else
  parent="$(dirname "$PINNED")"
  mkdir -p "$parent"
  git clone --branch main "$REMOTE" "$PINNED"
  in_git "$PINNED" || die "clone succeeded but $PINNED is not a git checkout"
  local_branch="$(branch_of "$PINNED")"
  if [[ "$local_branch" != "main" ]]; then
    die_not_main "$local_branch"
  fi
fi

ensure_env_symlink ".env.sepolia" 1
ensure_env_symlink ".env" 0

echo
echo "agents now run:"
git -C "$PINNED" log -1 --format='%H%n%h %s%n%ci%n%an'
echo "tree: $PINNED"
echo "branch: $(branch_of "$PINNED")"
echo "remote: $REMOTE"
