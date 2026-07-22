# Codebase audit follow-up tasks (2026-07-22)

This audit sampled the operator scripts, the one-shot pipeline snapshot, the
viewer/dApp helper libraries and tests, and the current README/runbook. The
items below are deliberately small and independently actionable.

## 1. Typo: remove the duplicated “from” in the viewer test name

**Finding:** `viewer/lib.test.js` names a `contiguousScanTip` case “returns last
contiguous success from from”. The duplicate word makes test output harder to
scan and appears to be an editing typo.

**Task:** Rename the case to “returns last contiguous success from the starting
block”. This should be a description-only change with no production behavior
change.

**Acceptance criteria:**

- `node --test viewer/lib.test.js` still passes.
- The test report no longer contains “from from”.

## 2. Bug: always redact non-root RPC URL paths

**Finding:** Both `scripts/lib.sh::redact_rpc_url` and
`scripts/pipeline-snapshot.py::redact_rpc_url` preserve a URL path when its
length is eight characters or fewer. RPC providers can use short path API keys,
so a URL such as `https://rpc.example/secret` is emitted unchanged even though
the helpers promise redacted output. This can leak a credential into terminal
logs or snapshot JSON.

**Task:** Reduce every non-root RPC path to `/…`, regardless of length, while
continuing to remove userinfo, query strings, and fragments. Keep the shell and
Python implementations aligned.

**Acceptance criteria:**

- Root URLs still render as `scheme://host[:port]`.
- Short and long paths both render only as `/…`.
- Userinfo, query strings, and fragments never appear in output.
- Existing callers continue to receive display-only URLs; raw RPC calls are
  unaffected.

## 3. Documentation discrepancy: replace the obsolete “future Phase 2 script” note

**Finding:** The Phase 2a README example says `FORTEL2_ENV=.env.sepolia` should
prefix “any future Phase 2 script”, but the roadmap immediately above marks
Phases 2a–2d done and the repository now contains the Sepolia scripts. The word
“future” makes the live operator instruction read like an uncompleted plan.

**Task:** Change the inline note to say that the variable prefixes Sepolia
commands, and check the surrounding Phase 2a wording for historical-vs-current
tense without changing the recorded phase history.

**Acceptance criteria:**

- The example clearly tells operators how to run the existing Sepolia scripts.
- The Phase 2a section still records that the scaffold itself did not broadcast.
- The roadmap remains the source of truth for current completion status.

## 4. Test improvement: add unit coverage for the pipeline snapshot helpers

**Finding:** `scripts/pipeline-snapshot.py` contains pure parsing, redaction,
path-selection, age, and scan-window helpers, but the CI suite invokes the
script only indirectly (if at all) and has no focused Python tests. In
particular, no test protects the redaction contract described above.

**Task:** Add a standard-library `unittest` module for the pure helpers and run
it from `.github/workflows/ci.yml`. At minimum, cover root/short-path/long-path
RPC redaction, userinfo/query/fragment removal, hexadecimal and invalid
quantities, inclusive scan boundaries, and local-vs-Sepolia deployment paths.

**Acceptance criteria:**

- Tests require no live chain, funded key, third-party package, or network.
- A regression that exposes a short RPC path fails the suite.
- The new Python test command runs in CI alongside the existing shell, Node,
  Solidity, and bridge suites.
