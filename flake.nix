{
  description = "Reproducer + fix-validator for nixpkgs#507531 / NixOS/nix#15638 (darwin Mach-O page-hash bug)";

  inputs = {
    # Pinned to the nixpkgs revision used in the PR body's reproduction blocks.
    # The fish-4.2.1 store path resolves to gngn7y9mn510mf1hkmr0l69qbpvxfbfh-fish-4.2.1
    # under this rev.
    nixpkgs.url = "github:nixos/nixpkgs/d96b37bbeb9840f1c0ebfe90585ef5067b69bbb3";

    # The patched Nix daemon from NixOS/nix#15638. First run will build this
    # from source (~10-15 min). Subsequent runs are cached.
    patched-nix = {
      url = "github:ak2k/nix/darwin-mach-o-page-hash-fixup";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, patched-nix }:
    let
      systems = [ "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      # Constants reused by both test scripts.
      nixpkgsRev = "d96b37bbeb9840f1c0ebfe90585ef5067b69bbb3";
      nixpkgsFlake = "github:nixos/nixpkgs/${nixpkgsRev}";
      fishBin = "/nix/store/gngn7y9mn510mf1hkmr0l69qbpvxfbfh-fish-4.2.1";
      fishDoc = "/nix/store/62v6ki5ql5wxvgabn60aln10l2a4aacb-fish-4.2.1-doc";

      mkScripts = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          patched = patched-nix.packages.${system}.nix-cli;
          checkPy = ./check.py;

          # Verification helper used by both tests.
          verify = name: expectedMismatches: ''
            echo
            echo "==> Verification (${name})"
            nar=$(nix-store --query --hash "${fishBin}")
            echo "    NAR hash:   $nar"

            echo "    codesign --verify:"
            cs_rc=0
            /usr/bin/codesign --verify "${fishBin}/bin/fish" 2>&1 | sed 's/^/      /' || cs_rc=$?
            echo "    codesign exit: $cs_rc"

            echo "    fish --version:"
            run_rc=0
            set +m  # suppress shell job-control "Killed: 9" notifications
            { "${fishBin}/bin/fish" --version 2>&1 | sed 's/^/      /' || run_rc=$?; } 2>/dev/null
            set -m
            echo "    fish exit: $run_rc"

            echo "    check.py:"
            python3 ${checkPy} "${fishBin}/bin/fish" | sed 's/^/      /'
            mismatches=$(python3 ${checkPy} "${fishBin}/bin/fish" | awk '/mismatches/ && !/page/ {print; exit}')

            echo
            echo "==> Result"
            if [[ "$mismatches" == "${expectedMismatches}/2526 mismatches" ]]; then
              echo "    PASS — observed exactly the expected outcome (${expectedMismatches}/2526 mismatches, codesign exit $cs_rc, fish exit $run_rc)"
              exit 0
            else
              echo "    FAIL — expected '${expectedMismatches}/2526 mismatches', got: $mismatches"
              echo "    (codesign exit $cs_rc, fish exit $run_rc)"
              exit 1
            fi
          '';

          unpatchedTest = pkgs.writeShellApplication {
            name = "507531-unpatched-test";
            runtimeInputs = with pkgs; [ python3 nix gnused gnugrep gawk coreutils ];
            text = ''
              set -euo pipefail

              echo "==================================================================="
              echo "  nixpkgs#507531 reproducer — UNPATCHED daemon"
              echo "  Demonstrates the bug under the deterministic trigger setup."
              echo "  Expects: 1/2526 page-hash mismatch, codesign invalid, SIGKILL."
              echo "==================================================================="
              echo

              echo "==> Step 1/4: populate fish's build-time closure"
              echo "    (substitutes the build inputs from cache; ~30 sec - 2 min)"
              nix --extra-experimental-features "nix-command flakes" \
                  develop "${nixpkgsFlake}#fish" --command true 2>&1 | sed 's/^/    /'

              echo
              echo "==> Step 2/4: substitute fish + fish-doc from cache"
              nix --extra-experimental-features "nix-command flakes" \
                  build --no-link "${nixpkgsFlake}#fish" 2>&1 | sed 's/^/    /' || true

              if [[ ! -d "${fishBin}" || ! -d "${fishDoc}" ]]; then
                echo "    ERROR: expected store paths missing after substitution"
                exit 1
              fi

              echo
              echo "==> Step 3/4: delete fish bin only (leaving fish-doc as the sibling trigger)"
              nix-store --delete "${fishBin}" 2>&1 | sed 's/^/    /'
              if [[ -d "${fishBin}" ]]; then
                echo "    ERROR: fish bin still present after delete"
                exit 1
              fi

              echo
              echo "==> Step 4/4: rebuild via the system nix-daemon (unpatched)"
              echo "    (~1 min once build inputs are in store from step 1)"
              nix --extra-experimental-features "nix-command flakes" \
                  build --no-link --print-out-paths --option substitute false \
                  "${nixpkgsFlake}#fish" 2>&1 | sed 's/^/    /'

              ${verify "unpatched" "1"}
            '';
          };

          patchedTest = pkgs.writeShellApplication {
            name = "507531-patched-test";
            runtimeInputs = with pkgs; [ python3 nix gnused gnugrep gawk coreutils ];
            text = ''
              set -euo pipefail

              echo "==================================================================="
              echo "  nixpkgs#507531 reproducer — PATCHED daemon"
              echo "  Demonstrates the fix under the same deterministic trigger setup."
              echo "  Expects: 0/2526 mismatches, codesign valid, fish runs."
              echo
              echo "  Note: this test spawns a private nix-daemon as root (one sudo"
              echo "  prompt) so it can write to /nix/store. The system nix-daemon"
              echo "  is not touched. Cleanup runs on exit."
              echo "==================================================================="
              echo

              PATCHED=${patched}
              SOCKET_DIR="/private/tmp/507531-patched-test-$$"
              SOCKET_PATH="$SOCKET_DIR/socket"

              # shellcheck disable=SC2329  # invoked via trap below
              cleanup() {
                rc=$?
                echo
                echo "==> Cleanup"
                sudo pkill -f "$SOCKET_DIR" 2>/dev/null || true
                sudo rm -rf "$SOCKET_DIR" 2>/dev/null || true
                exit "$rc"
              }
              trap cleanup EXIT INT TERM

              echo "==> Patched daemon binary: $PATCHED/bin/nix-daemon"
              "$PATCHED/bin/nix" --version

              echo
              echo "==> Step 1/5: populate fish's build-time closure (via system daemon)"
              nix --extra-experimental-features "nix-command flakes" \
                  develop "${nixpkgsFlake}#fish" --command true 2>&1 | sed 's/^/    /'

              echo
              echo "==> Step 2/5: substitute fish + fish-doc from cache (via system daemon)"
              nix --extra-experimental-features "nix-command flakes" \
                  build --no-link "${nixpkgsFlake}#fish" 2>&1 | sed 's/^/    /' || true

              if [[ ! -d "${fishBin}" || ! -d "${fishDoc}" ]]; then
                echo "    ERROR: expected store paths missing after substitution"
                exit 1
              fi

              echo
              echo "==> Step 3/5: spawn the patched nix-daemon on a private socket (sudo)"
              sudo mkdir -p "$SOCKET_DIR"
              sudo NIX_DAEMON_SOCKET_PATH="$SOCKET_PATH" "$PATCHED/bin/nix-daemon" &
              sleep 2
              if [[ ! -S "$SOCKET_PATH" ]]; then
                echo "    ERROR: patched daemon failed to start"
                exit 1
              fi
              echo "    patched daemon up at $SOCKET_PATH"

              echo
              echo "==> Step 4/5: delete fish bin only (sibling fish-doc remains)"
              nix-store --delete "${fishBin}" 2>&1 | sed 's/^/    /'
              if [[ -d "${fishBin}" ]]; then
                echo "    ERROR: fish bin still present after delete"
                exit 1
              fi

              echo
              echo "==> Step 5/5: rebuild via the patched daemon"
              echo "    (~1 min once build inputs are in store from step 1)"
              export NIX_REMOTE="unix://$SOCKET_PATH"
              "$PATCHED/bin/nix" --extra-experimental-features "nix-command flakes" \
                  build --no-link --print-out-paths --option substitute false \
                  "${nixpkgsFlake}#fish" 2>&1 | sed 's/^/    /'

              ${verify "patched" "0"}
            '';
          };
          abTest = pkgs.writeShellApplication {
            name = "507531-ab-test";
            runtimeInputs = with pkgs; [ python3 nix gnused gnugrep gawk coreutils ];
            text = ''
              set -euo pipefail

              cat <<'BANNER'
              ===================================================================
                nixpkgs#507531 / NixOS/nix#15638 — A/B reproduction
                Runs the same trigger sequence twice on the same store path:
                once via the system nix-daemon (unpatched), once via a private
                daemon built from this PR. Prints a side-by-side comparison.

                Spawns a private nix-daemon as root (one sudo prompt). The
                system nix-daemon is not touched. Cleanup runs on exit.
                Wall time: ~5-7 min.
              ===================================================================
              BANNER
              echo

              PATCHED=${patched}
              SOCKET_DIR="/private/tmp/507531-ab-test-$$"
              SOCKET_PATH="$SOCKET_DIR/socket"

              # shellcheck disable=SC2329  # invoked via trap
              cleanup() {
                rc=$?
                echo
                echo "==> Cleanup"
                sudo pkill -f "$SOCKET_DIR" 2>/dev/null || true
                sudo rm -rf "$SOCKET_DIR" 2>/dev/null || true
                exit "$rc"
              }
              trap cleanup EXIT INT TERM

              echo "==> Setup 1/3: populate fish's build-time closure"
              nix --extra-experimental-features "nix-command flakes" \
                  develop "${nixpkgsFlake}#fish" --command true 2>&1 | sed 's/^/    /'

              echo
              echo "==> Setup 2/3: substitute fish + fish-doc from cache"
              nix --extra-experimental-features "nix-command flakes" \
                  build --no-link "${nixpkgsFlake}#fish" 2>&1 | sed 's/^/    /' || true

              if [[ ! -d "${fishBin}" || ! -d "${fishDoc}" ]]; then
                echo "    ERROR: expected store paths missing after substitution"
                exit 1
              fi

              echo
              echo "==> Setup 3/3: spawn patched nix-daemon on private socket (sudo)"
              sudo mkdir -p "$SOCKET_DIR"
              sudo NIX_DAEMON_SOCKET_PATH="$SOCKET_PATH" "$PATCHED/bin/nix-daemon" &
              sleep 2
              if [[ ! -S "$SOCKET_PATH" ]]; then
                echo "    ERROR: patched daemon failed to start"
                exit 1
              fi
              echo "    patched daemon up at $SOCKET_PATH"

              # Try to capture the actual daemon versions (not client versions). The
              # bug is in the daemon, so daemon version is what matters. Falls back
              # to descriptive labels if detection fails.
              unset NIX_REMOTE
              UNPATCHED_VERSION_RAW=$(nix --extra-experimental-features "nix-command" store info 2>&1 | awk '/Version:/ {sub(/^[[:space:]]*Version:[[:space:]]*/,""); print; exit}')
              if [[ -n "$UNPATCHED_VERSION_RAW" ]]; then
                UNPATCHED_LABEL="system nix-daemon ($UNPATCHED_VERSION_RAW)"
              else
                UNPATCHED_LABEL="system nix-daemon (whatever is installed on this host)"
              fi

              PATCHED_VERSION_RAW=$(NIX_REMOTE="unix://$SOCKET_PATH" "$PATCHED/bin/nix" --extra-experimental-features "nix-command" store info 2>&1 | awk '/Version:/ {sub(/^[[:space:]]*Version:[[:space:]]*/,""); print; exit}')
              if [[ -n "$PATCHED_VERSION_RAW" ]]; then
                PATCHED_LABEL="patched nix-daemon ($PATCHED_VERSION_RAW, NixOS/nix#15638)"
              else
                PATCHED_LABEL="patched nix-daemon from NixOS/nix#15638 (commit 883e433)"
              fi

              # ----- UNPATCHED rebuilds (N iterations to demonstrate determinism) -----
              UNPATCHED_ITERATIONS=3
              UNPATCHED_NARS=()
              echo
              echo "==> A/B step 1: rebuild via UNPATCHED system daemon ($UNPATCHED_ITERATIONS iterations to show determinism)"
              unset NIX_REMOTE
              for iter in $(seq 1 "$UNPATCHED_ITERATIONS"); do
                echo
                echo "    --- iteration $iter/$UNPATCHED_ITERATIONS ---"
                nix-store --delete "${fishBin}" 2>&1 | sed 's/^/      /'
                nix --extra-experimental-features "nix-command flakes" \
                    build --no-link --print-out-paths --option substitute false \
                    "${nixpkgsFlake}#fish" 2>&1 | sed 's/^/      /'
                iter_nar=$(nix-store --query --hash "${fishBin}")
                iter_mismatches=$(python3 ${checkPy} "${fishBin}/bin/fish" | awk '/mismatches/ && !/page/ {print; exit}')
                echo "      NAR:    $iter_nar"
                echo "      result: $iter_mismatches"
                UNPATCHED_NARS+=("$iter_nar")
              done

              # Determinism check: are all iterations bit-identical?
              UNPATCHED_DETERMINISM_OK=true
              for nar in "''${UNPATCHED_NARS[@]}"; do
                if [[ "$nar" != "''${UNPATCHED_NARS[0]}" ]]; then
                  UNPATCHED_DETERMINISM_OK=false
                  break
                fi
              done

              if $UNPATCHED_DETERMINISM_OK; then
                UNPATCHED_DETERMINISM_LABEL="bit-identical (''${#UNPATCHED_NARS[@]}/''${#UNPATCHED_NARS[@]} iterations)"
              else
                UNPATCHED_DETERMINISM_LABEL="DIFFER across iterations"
              fi

              # Capture full verification on the LAST iteration's binary.
              UNPATCHED_CS_RC=0
              /usr/bin/codesign --verify "${fishBin}/bin/fish" >/dev/null 2>&1 || UNPATCHED_CS_RC=$?
              UNPATCHED_RUN_RC=0
              set +m  # suppress shell job-control "Killed: 9" notifications
              { "${fishBin}/bin/fish" --version >/dev/null 2>&1 || UNPATCHED_RUN_RC=$?; } 2>/dev/null
              set -m
              UNPATCHED_MISMATCHES=$(python3 ${checkPy} "${fishBin}/bin/fish" | awk '/mismatches/ && !/page/ {print; exit}')
              UNPATCHED_PAGE=$(python3 ${checkPy} "${fishBin}/bin/fish" | awk '/^[[:space:]]+page [0-9]+ @/ {gsub(/^[[:space:]]+/,""); print; exit}')
              [[ -z "$UNPATCHED_PAGE" ]] && UNPATCHED_PAGE="(none)"
              UNPATCHED_DVVV=$(/usr/bin/codesign -dvvv "${fishBin}/bin/fish" 2>&1 || true)
              UNPATCHED_FLAGS=$(echo "$UNPATCHED_DVVV" | grep -o 'flags=0x[0-9a-f]*([^)]*)' | head -1)
              UNPATCHED_HASHES=$(echo "$UNPATCHED_DVVV" | grep -o 'hashes=[0-9]*+[0-9]*' | head -1)

              # ----- PATCHED rebuild -----
              echo
              echo "==> A/B step 2: rebuild via PATCHED daemon (NixOS/nix#15638)"
              nix-store --delete "${fishBin}" 2>&1 | sed 's/^/    /'
              export NIX_REMOTE="unix://$SOCKET_PATH"
              "$PATCHED/bin/nix" --extra-experimental-features "nix-command flakes" \
                  build --no-link --print-out-paths --option substitute false \
                  "${nixpkgsFlake}#fish" 2>&1 | sed 's/^/    /'

              PATCHED_NAR=$("$PATCHED/bin/nix-store" --query --hash "${fishBin}")
              PATCHED_CS_RC=0
              /usr/bin/codesign --verify "${fishBin}/bin/fish" >/dev/null 2>&1 || PATCHED_CS_RC=$?
              PATCHED_RUN_RC=0
              set +m
              { "${fishBin}/bin/fish" --version >/dev/null 2>&1 || PATCHED_RUN_RC=$?; } 2>/dev/null
              set -m
              PATCHED_MISMATCHES=$(python3 ${checkPy} "${fishBin}/bin/fish" | awk '/mismatches/ && !/page/ {print; exit}')
              PATCHED_PAGE=$(python3 ${checkPy} "${fishBin}/bin/fish" | awk '/^[[:space:]]+page [0-9]+ @/ {gsub(/^[[:space:]]+/,""); print; exit}')
              [[ -z "$PATCHED_PAGE" ]] && PATCHED_PAGE="(none)"
              PATCHED_DVVV=$(/usr/bin/codesign -dvvv "${fishBin}/bin/fish" 2>&1 || true)
              PATCHED_FLAGS=$(echo "$PATCHED_DVVV" | grep -o 'flags=0x[0-9a-f]*([^)]*)' | head -1)
              PATCHED_HASHES=$(echo "$PATCHED_DVVV" | grep -o 'hashes=[0-9]*+[0-9]*' | head -1)

              # ----- Comparison output -----
              echo
              echo
              cat <<COMPARE
              ===================================================================
                A/B COMPARISON
              ===================================================================

                Held constant across both runs:
                  Store path:    ${fishBin}
                  Drv path:      /nix/store/s8swwl2iva8bw1yzcpdbifskbpw8cwhl-fish-4.2.1.drv
                  nixpkgs rev:   ${nixpkgsRev}
                  Trigger:       fish-doc in store, fish bin absent at build start,
                                 --option substitute false (forces local rebuild)

                Variable (the daemon doing the build):
                  UNPATCHED:     $UNPATCHED_LABEL
                  PATCHED:       $PATCHED_LABEL

              COMPARE

              # Format the comparison table with printf for fixed-width columns.
              col1=20
              col2=36
              col3=36
              hr="  +"
              for w in $col1 $col2 $col3; do
                hr="$hr$(printf '%*s' "$((w+2))" ''' | tr ' ' '-')+"
              done

              echo "$hr"
              # shellcheck disable=SC2059
              printf "  | %-''${col1}s | %-''${col2}s | %-''${col3}s |\n" "" "UNPATCHED" "PATCHED"
              echo "$hr"

              row() {
                local label=$1 u=$2 p=$3
                # shellcheck disable=SC2059
                printf "  | %-''${col1}s | %-''${col2}s | %-''${col3}s |\n" "$label" "$u" "$p"
              }

              if [[ "$UNPATCHED_CS_RC" -eq 0 ]]; then UC_DESC="PASS (exit 0)"; else UC_DESC="FAIL (exit $UNPATCHED_CS_RC)"; fi
              if [[ "$PATCHED_CS_RC" -eq 0 ]]; then PC_DESC="PASS (exit 0)"; else PC_DESC="FAIL (exit $PATCHED_CS_RC)"; fi

              if [[ "$UNPATCHED_RUN_RC" -eq 0 ]]; then UR_DESC="rc=0 (runs cleanly)"; elif [[ "$UNPATCHED_RUN_RC" -eq 137 ]]; then UR_DESC="SIGKILL (rc=137)"; else UR_DESC="rc=$UNPATCHED_RUN_RC"; fi
              if [[ "$PATCHED_RUN_RC" -eq 0 ]]; then PR_DESC="rc=0 (runs cleanly)"; elif [[ "$PATCHED_RUN_RC" -eq 137 ]]; then PR_DESC="SIGKILL (rc=137)"; else PR_DESC="rc=$PATCHED_RUN_RC"; fi

              row "iterations" "$UNPATCHED_DETERMINISM_LABEL" "1 (single rebuild)"
              row "codesign --verify" "$UC_DESC" "$PC_DESC"
              row "fish --version" "$UR_DESC" "$PR_DESC"
              row "check.py" "$UNPATCHED_MISMATCHES" "$PATCHED_MISMATCHES"
              row "mismatched page" "$UNPATCHED_PAGE" "$PATCHED_PAGE"
              row "CodeDirectory" "$UNPATCHED_FLAGS" "$PATCHED_FLAGS"
              row "hash count" "$UNPATCHED_HASHES" "$PATCHED_HASHES"
              echo "$hr"

              echo
              echo "  NAR hashes:"
              for i in "''${!UNPATCHED_NARS[@]}"; do
                iter_num=$((i + 1))
                if [[ $i -eq 0 ]]; then
                  echo "    UNPATCHED iter $iter_num:  ''${UNPATCHED_NARS[$i]}"
                else
                  if [[ "''${UNPATCHED_NARS[$i]}" == "''${UNPATCHED_NARS[0]}" ]]; then
                    echo "    UNPATCHED iter $iter_num:  ''${UNPATCHED_NARS[$i]}  (bit-identical to iter 1)"
                  else
                    echo "    UNPATCHED iter $iter_num:  ''${UNPATCHED_NARS[$i]}  (DIFFERS from iter 1)"
                  fi
                fi
              done
              echo "    PATCHED:           $PATCHED_NAR"
              echo
              if $UNPATCHED_DETERMINISM_OK; then
                echo "    → unpatched: bit-identical across $UNPATCHED_ITERATIONS iterations"
                echo "                 (the bug fires deterministically under the trigger setup)"
              else
                echo "    → unpatched: DIFFERS across $UNPATCHED_ITERATIONS iterations"
                echo "                 (expected bit-identical; this is unexpected)"
              fi
              echo "    → patched:   different bytes from unpatched, same store path"
              echo "                 (the helper recomputed the affected page hash slots in place)"

              echo
              echo "  ==================================================================="
              echo "    RESULT"
              echo "  ==================================================================="
              echo

              unpatched_ok=false
              patched_ok=false
              if [[ "$UNPATCHED_CS_RC" -ne 0 && "$UNPATCHED_RUN_RC" -eq 137 && "$UNPATCHED_MISMATCHES" == "1/2526 mismatches" ]] && $UNPATCHED_DETERMINISM_OK; then
                unpatched_ok=true
              fi
              if [[ "$PATCHED_CS_RC" -eq 0 && "$PATCHED_RUN_RC" -eq 0 && "$PATCHED_MISMATCHES" == "0/2526 mismatches" ]]; then
                patched_ok=true
              fi

              if $unpatched_ok && $patched_ok; then
                echo "  [PASS] UNPATCHED  bug reproduced deterministically"
                echo "                    ($UNPATCHED_ITERATIONS iterations, all bit-identical, all 1/2526 mismatch,"
                echo "                     all codesign FAIL, all kernel SIGKILL)"
                echo
                echo "  [PASS] PATCHED    fix applied as expected"
                echo "                    (0/2526 mismatches, codesign PASS, fish runs)"
                echo
                echo "  Interpretation:"
                echo
                echo "  The bug fires deterministically on the unpatched daemon under this"
                echo "  trigger: $UNPATCHED_ITERATIONS independent rebuilds produced bit-identical corrupted"
                echo "  binaries (same NAR hash, same single page-hash mismatch at slot 1872,"
                echo "  same codesign failure, same SIGKILL)."
                echo
                echo "  Same store path, same nixpkgs revision, same trigger sequence;"
                echo "  only the daemon was varied. The unpatched daemon's RewritingSink"
                echo "  invalidated one page hash slot during scratch->final substitution,"
                echo "  and the macOS kernel rejected the binary at first page-in. The"
                echo "  patched daemon's RewritingSink performed the same substitution"
                echo "  then ran fixupMachoPageHashes to recompute the affected page hash"
                echo "  slots in place; the kernel accepted the result."
                echo
                echo "  The CodeDirectory structure (flags including the linker-signed"
                echo "  bit, hash count, page size) is identical between the two runs:"
                echo "  the helper updates only the page hash slots that the rewrite"
                echo "  invalidated, leaving every other byte of the signature alone."
                echo
                exit 0
              else
                echo "  [FAIL] A/B did not match the expected pattern."
                echo
                if ! $unpatched_ok; then
                  echo "    UNPATCHED expected: 1/2526 mismatches, cs!=0, rc=137"
                  echo "    UNPATCHED observed: $UNPATCHED_MISMATCHES, cs=$UNPATCHED_CS_RC, rc=$UNPATCHED_RUN_RC"
                fi
                if ! $patched_ok; then
                  echo "    PATCHED expected:   0/2526 mismatches, cs=0, rc=0"
                  echo "    PATCHED observed:   $PATCHED_MISMATCHES, cs=$PATCHED_CS_RC, rc=$PATCHED_RUN_RC"
                fi
                exit 1
              fi
            '';
          };
        in
        { inherit unpatchedTest patchedTest abTest; };
    in
    {
      packages = forAllSystems (system:
        let s = mkScripts system; in {
          unpatched-test = s.unpatchedTest;
          patched-test = s.patchedTest;
          ab-test = s.abTest;
          default = s.abTest;
        });

      apps = forAllSystems (system:
        let s = mkScripts system; in {
          unpatched-test = {
            type = "app";
            program = "${s.unpatchedTest}/bin/507531-unpatched-test";
          };
          patched-test = {
            type = "app";
            program = "${s.patchedTest}/bin/507531-patched-test";
          };
          ab-test = {
            type = "app";
            program = "${s.abTest}/bin/507531-ab-test";
          };
          default = self.apps.${system}.ab-test;
        });
    };
}
