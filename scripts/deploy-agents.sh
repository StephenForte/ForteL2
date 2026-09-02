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
die_wrong_origin() {
  die "pinned tree origin is not this repo (pinned=${1:-unknown} expected=${2:-unknown}) — refuse to update (operator decision)"
}

normalize_git_url() {
  local u="$1"
  u="${u%.git}"
  u="${u%/}"
  u="${u#git@}"
  u="${u#https://}"
  u="${u#http://}"
  u="${u/://}"
  printf '%s' "$u"
}

in_git() {
  git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

branch_of() {
  git -C "$1" rev-parse --abbrev-ref HEAD
}

is_dirty() {
  # .env / .env.sepolia / data are gitignored as files-or-dirs in the real repo
  # for `data/` (trailing slash = directory only). A symlink named data is not
  # a directory, so it would otherwise show as untracked and block every update.
  local leftover
  leftover="$(git -C "$1" status --porcelain | grep -v -E '^\?\? (\.env|\.env\.sepolia|data|deployments/sepolia/\.deployer)$' || true)"
  [[ -n "$leftover" ]]
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

# $1 = name (.env.sepolia / .env / data). Missing source: required when $2=1,
# optional otherwise. Existing regular file/dir in the pinned tree → refuse
# (never silently replace a real path with a symlink). Existing correct
# symlink → ok. $3=1 → mkdir -p the source first (data/).
ensure_env_symlink() {
  local name="$1"
  local required="${2:-0}"
  local mkdir_src="${3:-0}"
  local src="$DEV/$name"
  local dst="$PINNED/$name"

  if [[ "$mkdir_src" -eq 1 ]]; then
    mkdir -p "$src"
  fi

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

# gitignore "data/" matches directories only — a symlink named data is untracked
# and would make every later deploy refuse dirty. Local exclude, not a
# .gitignore edit (the pinned tree is a clone; this file is not committed).
ensure_git_exclude() {
  local line="$1"
  local exclude="$PINNED/.git/info/exclude"
  mkdir -p "$PINNED/.git/info"
  touch "$exclude"
  if grep -Fqx "$line" "$exclude"; then
    return 0
  fi
  printf '%s\n' "$line" >> "$exclude"
}

# refresh_health.sh writes repo-relative data/; alert-watch.sh reads
# $FORTEL2_ROOT/data. lib.sh now pins FORTEL2_ROOT to this tree, so data/
# must still be a symlink — the two paths are one file.
ensure_data_symlink() {
  local src="$DEV/data"
  local dst="$PINNED/data"
  mkdir -p "$src"
  if [[ -L "$dst" ]]; then
    local target
    target="$(readlink "$dst")"
    if [[ "$target" == "$src" ]]; then
      echo "symlink data → $src (already)"
      ensure_git_exclude "data"
      return 0
    fi
    die "symlink $dst points at $target, expected $src — refuse to retarget (operator decision)"
  fi
  if [[ -e "$dst" ]]; then
    die_regular_env "$dst"
  fi
  ln -s "$src" "$dst"
  ensure_git_exclude "data"
  echo "symlink data → $src (created)"
}

# Nested untracked runtime path (e.g. deployments/sepolia/.deployer).
# Same refuse-to-overwrite / refuse-to-retarget rules as ensure_env_symlink.
# $2=1 required when the source is missing (after optional mkdir). $3=1
# mkdir -p the source first. Always gitignores the symlink via local exclude
# (trailing-slash gitignore matches directories only — a symlink is dirty).
ensure_runtime_symlink() {
  local rel="$1"
  local required="${2:-0}"
  local mkdir_src="${3:-0}"
  local src="$DEV/$rel"
  local dst="$PINNED/$rel"

  if [[ "$mkdir_src" -eq 1 ]]; then
    mkdir -p "$src"
  fi

  if [[ ! -e "$src" && ! -L "$src" ]]; then
    if [[ "$required" -eq 1 ]]; then
      die "$rel is missing in the dev checkout ($src) — agents need the untracked runtime artifact"
    fi
    return 0
  fi

  mkdir -p "$(dirname "$dst")"

  if [[ -L "$dst" ]]; then
    local target
    target="$(readlink "$dst")"
    if [[ "$target" == "$src" ]]; then
      echo "symlink $rel → $src (already)"
      ensure_git_exclude "$rel"
      return 0
    fi
    die "symlink $dst points at $target, expected $src — refuse to retarget (operator decision)"
  fi

  if [[ -e "$dst" ]]; then
    die_regular_env "$dst"
  fi

  ln -s "$src" "$dst"
  ensure_git_exclude "$rel"
  echo "symlink $rel → $src (created)"
}

REMOTE="$(resolve_remote)"

if [[ -e "$PINNED" && ! -d "$PINNED" ]]; then
  die "pinned path exists and is not a directory: $PINNED"
fi

if [[ -d "$PINNED" ]]; then
  in_git "$PINNED" || die "path exists but is not a git checkout: $PINNED"

  pinned_origin="$(git -C "$PINNED" remote get-url origin 2>/dev/null || true)"
  if [[ -z "$pinned_origin" ]]; then
    die_wrong_origin "(none)" "$REMOTE"
  fi
  if [[ "$(normalize_git_url "$pinned_origin")" != "$(normalize_git_url "$REMOTE")" ]]; then
    die_wrong_origin "$pinned_origin" "$REMOTE"
  fi

  local_branch="$(branch_of "$PINNED")"
  if [[ "$local_branch" != "main" ]]; then
    die_not_main "$local_branch"
  fi
  if is_dirty "$PINNED"; then
    die_dirty
  fi

  pinned_origin="$(git -C "$PINNED" remote get-url origin 2>/dev/null || true)"
  if [[ -z "$pinned_origin" ]]; then
    die "pinned tree has no origin remote"
  fi
  if [[ "$(normalize_git_url "$pinned_origin")" != "$(normalize_git_url "$REMOTE")" ]]; then
    die_wrong_origin "$pinned_origin" "$REMOTE"
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
ensure_data_symlink
# Untracked challenger artifacts (rollup.json / genesis.json). Symlink the
# subdirectory only — never deployments/sepolia (that would shadow the
# pinned tracked deployments.json / rollup.json). required=1, mkdir_src=0:
# a missing dest .deployer must refuse (do not mkdir an empty stand-in).
ensure_runtime_symlink "deployments/sepolia/.deployer" 1 0

echo
echo "agents now run:"
git -C "$PINNED" log -1 --format='%H%n%h %s%n%ci%n%an'
echo "tree: $PINNED"
echo "branch: $(branch_of "$PINNED")"
echo "remote: $REMOTE"
