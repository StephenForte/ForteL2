DISPATCH · bound the runtime logs, date the launchd logs, stop the resolver temp leak
Runtime: ~2.5–4 h wall-clock. Three independent changes in one brief because all three
         append to scripts/test-helpers.sh, and two workers in that file will conflict.
         Safe to dispatch at any hour. No spend.
Model: strong tier. One call site is the live L1 bond-recovery agent (money path), one is
       the 03:00 launchd entrypoint (a syntax error there leaves the chain down overnight),
       and the logging change touches files a running chain holds open.
Surface: Claude Code or Cursor.
Repository: StephenForte/ForteL2
            NOT fortel2-replica. Everything here lives in ForteL2.
Baseline: origin/main @ 72b4e21 (verify yourself: git fetch && git rev-parse origin/main —
          trust the repo over this brief)
Branch: fix/log-hygiene-and-resolver-temp
Host: any with bash, zsh and python3
Working directory: a fresh clone in a scratch dir. NEVER /Users/steveforte/ForteL2.
Teardown: delete the clone after the PR is pushed.
Landing: PR to main. Do not allocate a decision id; the planner writes the record at review.
Silent-failure class: a rotation that looks like it works, frees no disk, and loses lines —
      because `mv` on a file a live process holds open does not reclaim space.

This file is the dispatch brief for the change set on this branch. The implementing
worker cloned to a scratch directory, did not write to the operator checkout except a
read-only `git fetch` of refs, and landed the three halves: copy-then-truncate rotation
at start, ISO-8601 timestamps on launchd wrappers, and per-path resolver temp cleanup.

See the pull request body and scripts/rotate-logs.sh for the mechanism, tests, and
deployment reality (merge is not deploy; already-running processes need a restart;
the existing 3.9 GB is not swept).

/goal keep this PR merge-ready: fix failing CI checks and bot review comments until everything passes.
