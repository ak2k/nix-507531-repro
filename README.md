# nix-507531-repro

A one-command reproducer + fix-validator for [nixpkgs#507531](https://github.com/NixOS/nixpkgs/issues/507531) / [NixOS/nix#15638](https://github.com/NixOS/nix/pull/15638) — the darwin Mach-O page-hash bug that causes `fish-4.2.1` (and other multi-output darwin packages) to fail kernel page-in validation with `cs_invalid_page` SIGKILL.

## What this is

Three flake apps targeting `aarch64-darwin`:

- **`ab-test`** (default) — runs both halves of the A/B in one command and prints a side-by-side comparison. Runs the unpatched rebuild **3 times** to show the bug fires deterministically (bit-identical NAR hashes across iterations), then runs the patched rebuild once to show the fix. The output ends with a structured comparison table and a final PASS/FAIL line. **This is the cleanest single-command demonstration.**

- **`unpatched-test`** — demonstrates the bug only. Sets up the trigger state (sibling output present, target output absent, substitution disabled), rebuilds via the system `nix-daemon`, and asserts the result is `1/2526` page-hash mismatches + `codesign --verify` failure + SIGKILL.

- **`patched-test`** — demonstrates the fix only. Same trigger setup, but rebuilds via a daemon built from [NixOS/nix#15638's patch](https://github.com/ak2k/nix/tree/darwin-mach-o-page-hash-fixup), and asserts the result is `0/2526` mismatches + valid `codesign` + clean runtime.

All three tests target the exact same `nixpkgs` revision (`d96b37bbeb9840f1c0ebfe90585ef5067b69bbb3`) and the exact same store path (`/nix/store/gngn7y9mn510mf1hkmr0l69qbpvxfbfh-fish-4.2.1`). The only variable between them is the daemon doing the rebuild.

## Usage

```sh
# Default: runs the full A/B comparison (3 unpatched iterations + 1 patched).
# Wall time ~5-7 min, one sudo prompt for the patched daemon spawn.
nix run github:ak2k/nix-507531-repro

# Equivalent:
nix run github:ak2k/nix-507531-repro#ab-test

# Just the bug (no sudo, ~3 min):
nix run github:ak2k/nix-507531-repro#unpatched-test

# Just the fix (one sudo prompt, ~5 min):
nix run github:ak2k/nix-507531-repro#patched-test
```

All apps target `aarch64-darwin` only. Linux and `x86_64-darwin` will refuse to evaluate.

## Wall time

- **First `ab-test`** (or `patched-test`): ~10–15 minutes the first time, because the patched `nix-cli` has to build from source via the `patched-nix` flake input. After that the patched nix is cached.
- **Subsequent `ab-test`**: ~5–7 minutes (3 unpatched fish rebuilds at ~55 sec each + 1 patched rebuild at ~55 sec + setup + comparison rendering).
- **Subsequent `unpatched-test`**: ~3 minutes (one rebuild + verification).
- **Subsequent `patched-test`**: ~3 minutes (one rebuild + verification + daemon spawn/teardown).

Each fish rebuild is forced to be local (`--option substitute false`) because the entire point of the test is to exercise the `RewritingSink → registerOutputs` code path on the rebuild. Substituting the cached fish from `cache.nixos.org` would skip that path entirely.

## What the tests do (in order)

### `ab-test` (default)

1. **Setup 1/3**: `nix develop github:nixos/nixpkgs/d96b37b#fish --command true` — populates fish's build-time closure from `cache.nixos.org`.
2. **Setup 2/3**: `nix build --no-link github:nixos/nixpkgs/d96b37b#fish` — substitutes `fish-4.2.1` and `fish-doc-4.2.1` from cache.
3. **Setup 3/3**: spawns the patched `nix-daemon` on a private socket (`/private/tmp/507531-ab-test-$$/socket`), via `sudo`. Cleanup runs on exit.
4. **A/B step 1**: runs the unpatched rebuild **3 times**. Each iteration: `nix-store --delete <fish-bin>`, then `nix build --option substitute false` via the system `nix-daemon`, then capture the NAR hash. After all 3 iterations, verify they're bit-identical and capture the full verification (codesign, fish runtime, check.py) on the last one.
5. **A/B step 2**: deletes fish bin once more, runs the patched rebuild via the private daemon (`NIX_REMOTE=unix://...`), captures the NAR hash and full verification.
6. **Comparison output**: prints a structured table comparing the two daemons' results, lists all 4 NAR hashes (3 unpatched + 1 patched), and ends with a final PASS/FAIL line.

The script asserts both halves of the A/B match expectations and exits 0 on PASS, non-zero on FAIL. The verdict explicitly says whether the bug reproduced deterministically and whether the patched daemon resolved it.

### `unpatched-test`

1. `nix develop github:nixos/nixpkgs/d96b37b#fish --command true` — populates fish's build-time closure from `cache.nixos.org`.
2. `nix build --no-link github:nixos/nixpkgs/d96b37b#fish` — substitutes `fish-4.2.1` and `fish-doc-4.2.1` from cache.
3. `nix-store --delete /nix/store/gngn7y9m...-fish-4.2.1` — removes fish bin only, leaving `fish-doc` as the sibling trigger.
4. `nix build --option substitute false github:nixos/nixpkgs/d96b37b#fish` — rebuilds fish locally via the system `nix-daemon`. Because `fish-doc` is in the store, `outputRewrites` gets populated; because the daemon is unpatched, `RewritingSink` corrupts a single page hash slot in the `linker-signed` `CodeDirectory`.
5. Verifies: codesign fails, fish SIGKILLs at page-in, `check.py` reports `1/2526 mismatches at page 1872 @ 0x00750000`.

The script asserts the bug is reproduced and exits 0 on `PASS`, non-zero on `FAIL`.

### `patched-test`

Steps 1, 2, 4 are identical. Steps 3 and 5 use a private `nix-daemon` instance built from [NixOS/nix#15638](https://github.com/NixOS/nix/pull/15638)'s patch:

3. **(sudo)** Spawns the patched `nix-daemon` on `/private/tmp/507531-patched-test-$$/socket`, listening as root (cleanup on exit).
5. Rebuilds via the patched daemon (`NIX_REMOTE=unix://...`). The patched daemon runs the same `RewritingSink` rewrite, then invokes `fixupMachoPageHashes` to recompute the page hashes that the rewrite invalidated.

The script asserts the binary is now clean and exits 0 on `PASS`, non-zero on `FAIL`.

The system `nix-daemon` is not touched. The patched daemon runs as a separate process on a private socket and is killed on exit.

## Recorded sample output

If you don't want to run the test yourself, [`examples/ab-test-output.txt`](examples/ab-test-output.txt) contains a real captured transcript of a passing `ab-test` run on `aarch64-darwin` (macOS 26.2) — same store path, same nixpkgs revision, same trigger sequence, same `1qplch87...` NAR hash across all 3 unpatched iterations and a different `0k4r1qv5...` for the patched rebuild.

<details>
<summary>Click to expand the recorded transcript inline</summary>

```
===================================================================
  nixpkgs#507531 / NixOS/nix#15638 — A/B reproduction
  Runs the same trigger sequence twice on the same store path:
  once via the system nix-daemon (unpatched), once via a private
  daemon built from this PR. Prints a side-by-side comparison.

  Spawns a private nix-daemon as root (one sudo prompt). The
  system nix-daemon is not touched. Cleanup runs on exit.
  Wall time: ~5-7 min.
===================================================================

[setup steps elided — see examples/ab-test-output.txt for the full transcript]

==> A/B step 1: rebuild via UNPATCHED system daemon (3 iterations to show determinism)

    --- iteration 1/3 ---
      [build output]
      NAR:    sha256:1qplch87dy4242vxwi3s5h62m6gnywn0f8z9wf659vkrh6hm4a0g
      result: 1/2526 mismatches

    --- iteration 2/3 ---
      [build output]
      NAR:    sha256:1qplch87dy4242vxwi3s5h62m6gnywn0f8z9wf659vkrh6hm4a0g
      result: 1/2526 mismatches

    --- iteration 3/3 ---
      [build output]
      NAR:    sha256:1qplch87dy4242vxwi3s5h62m6gnywn0f8z9wf659vkrh6hm4a0g
      result: 1/2526 mismatches

==> A/B step 2: rebuild via PATCHED daemon (NixOS/nix#15638)
    [build output]


===================================================================
  A/B COMPARISON
===================================================================

  Held constant across both runs:
    Store path:    /nix/store/gngn7y9mn510mf1hkmr0l69qbpvxfbfh-fish-4.2.1
    Drv path:      /nix/store/s8swwl2iva8bw1yzcpdbifskbpw8cwhl-fish-4.2.1.drv
    nixpkgs rev:   d96b37bbeb9840f1c0ebfe90585ef5067b69bbb3
    Trigger:       fish-doc in store, fish bin absent at build start,
                   --option substitute false (forces local rebuild)

  Variable (the daemon doing the build):
    UNPATCHED:     system nix-daemon (2.24.10)
    PATCHED:       patched nix-daemon (2.35.0pre20260408_883e433, NixOS/nix#15638)

  +----------------------+--------------------------------------+--------------------------------------+
  |                      | UNPATCHED                            | PATCHED                              |
  +----------------------+--------------------------------------+--------------------------------------+
  | iterations           | bit-identical (3/3 iterations)       | 1 (single rebuild)                   |
  | codesign --verify    | FAIL (exit 1)                        | PASS (exit 0)                        |
  | fish --version       | SIGKILL (rc=137)                     | rc=0 (runs cleanly)                  |
  | check.py             | 1/2526 mismatches                    | 0/2526 mismatches                    |
  | mismatched page      | page 1872 @ 0x00750000               | (none)                               |
  | CodeDirectory        | flags=0x20002(adhoc,linker-signed)   | flags=0x20002(adhoc,linker-signed)   |
  | hash count           | hashes=2526+0                        | hashes=2526+0                        |
  +----------------------+--------------------------------------+--------------------------------------+

  NAR hashes:
    UNPATCHED iter 1:  sha256:1qplch87dy4242vxwi3s5h62m6gnywn0f8z9wf659vkrh6hm4a0g
    UNPATCHED iter 2:  sha256:1qplch87dy4242vxwi3s5h62m6gnywn0f8z9wf659vkrh6hm4a0g  (bit-identical to iter 1)
    UNPATCHED iter 3:  sha256:1qplch87dy4242vxwi3s5h62m6gnywn0f8z9wf659vkrh6hm4a0g  (bit-identical to iter 1)
    PATCHED:           sha256:0k4r1qv58cvvmalikfmwxw73gd63vg9k07wvi6gcv6427l7mbnkc

    → unpatched: bit-identical across 3 iterations
                 (the bug fires deterministically under the trigger setup)
    → patched:   different bytes from unpatched, same store path
                 (the helper recomputed the affected page hash slots in place)

  ===================================================================
    RESULT
  ===================================================================

  [PASS] UNPATCHED  bug reproduced deterministically
                    (3 iterations, all bit-identical, all 1/2526 mismatch,
                     all codesign FAIL, all kernel SIGKILL)

  [PASS] PATCHED    fix applied as expected
                    (0/2526 mismatches, codesign PASS, fish runs)

  Interpretation:

  The bug fires deterministically on the unpatched daemon under this
  trigger: 3 independent rebuilds produced bit-identical corrupted
  binaries (same NAR hash, same single page-hash mismatch at slot 1872,
  same codesign failure, same SIGKILL).

  Same store path, same nixpkgs revision, same trigger sequence;
  only the daemon was varied. The unpatched daemon's RewritingSink
  invalidated one page hash slot during scratch->final substitution,
  and the macOS kernel rejected the binary at first page-in. The
  patched daemon's RewritingSink performed the same substitution
  then ran fixupMachoPageHashes to recompute the affected page hash
  slots in place; the kernel accepted the result.

  The CodeDirectory structure (flags including the linker-signed
  bit, hash count, page size) is identical between the two runs:
  the helper updates only the page hash slots that the rewrite
  invalidated, leaving every other byte of the signature alone.
```

</details>

## What `check.py` does

Standalone Python (stdlib only) that parses `LC_CODE_SIGNATURE`, walks the embedded `CodeDirectory`, SHA-256-hashes each code page in the binary, and reports any slot whose stored hash doesn't match the actual page bytes. Output format:

```
nCodeSlots=2526 pageSize=4096 codeLimit=0x9dd790
1/2526 mismatches
  page 1872 @ 0x00750000
```

A clean binary reports `0/N mismatches`. A corrupted binary reports `M/N mismatches` with the offending page indices and file offsets.

## Why a flake app instead of a shell script

- **Pinned inputs**: the `nixpkgs` rev and the patched-nix branch are flake inputs, not URLs in a copy-paste block.
- **Pinned target**: refuses to run on anything other than `aarch64-darwin`.
- **No copy-paste errors**: store paths and flags are baked into the script via Nix string interpolation.
- **shellcheck**: `writeShellApplication` runs shellcheck on every build, so the script can't have hidden bugs.
- **One-command repro**: `nix run github:ak2k/nix-507531-repro#<test>` is the entire user-facing command.
- **Self-contained**: the patched nix is built from the contributor fork via flake input; no manual setup beyond having Nix installed.

## Files

- `flake.nix` — the two test apps + their wrapping derivations
- `check.py` — the page-hash verification script (Python stdlib only)
- `README.md` — this file

## Related

- [NixOS/nix#15638](https://github.com/NixOS/nix/pull/15638) — the upstream PR with the fix
- [NixOS/nixpkgs#507531](https://github.com/NixOS/nixpkgs/issues/507531) — the original `fish-4.2.1` bug report
- [NixOS/nixpkgs#208951](https://github.com/NixOS/nixpkgs/issues/208951) — the long-running umbrella issue for darwin code-signature corruption
- [NixOS/nix#6065](https://github.com/NixOS/nix/issues/6065) — the CA-derivations counterpart issue
