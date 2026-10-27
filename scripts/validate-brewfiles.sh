#!/usr/bin/env bash
# Check every shared Brewfile against real Homebrew metadata. This syncs declared
# taps but never installs formulae/casks. It is networked, not part of just check.

main() (
    set -euo pipefail
    if [[ $# -gt 1 ]]; then
        echo "Usage: $0 [brewfile-directory]" >&2
        exit 2
    fi
    root="${1:-system_files/shared/usr/share/ublue-os/homebrew}"
    if [[ ! -d "${root}" ]]; then
        printf 'Brewfile directory does not exist: %s\n' "${root}" >&2
        exit 2
    fi
    if ! command -v brew >/dev/null; then
        echo "Homebrew is required to validate Brewfiles." >&2
        exit 2
    fi

    workdir=$(mktemp -d)
    trap 'rm -rf -- "${workdir}"' EXIT
    # Materialize discovery so find/sort failures cannot become an empty success.
    find "${root}" -type f -iname '*.Brewfile' -print0 | sort -z > "${workdir}/files"
    mapfile -d '' -t brewfiles < "${workdir}/files"
    if [[ ${#brewfiles[@]} -eq 0 ]]; then
        printf 'No Brewfiles found in %s\n' "${root}" >&2
        exit 2
    fi

    # Sync the complete tap set first: otherwise bare-name ambiguity depends on
    # which Brewfile find happens to visit first. Preserve declared trust flags.
    #
    # Only literal tap declarations are collected: the taps file IS evaluated as
    # Ruby by `brew bundle` (Homebrew::Bundle::Dsl#process instance_evals it), so
    # a computed tap line — string interpolation (#{...}, #$var, #@var),
    # trailing code after a ';', or a modifier like `if system(...)` — would
    # execute in CI on a PR-controlled Brewfile. Reject anything that is not a
    # quoted literal and fail closed before `brew bundle` ever sees it. The only
    # accepted option is the documented trust flag.
    # Backslashes are rejected inside both quote styles: an escaped quote (\" or
    # \') ends the string later for Ruby than for these patterns, so a trailing
    # "# comment" would be parsed as code.
    tap_entry='^[[:space:]]*tap[[:space:]]+"[^#{}"\]+"([[:space:]]*,[[:space:]]*trusted:[[:space:]]*(true|false))?[[:space:]]*(#.*)?$'
    tap_single="^[[:space:]]*tap[[:space:]]+'[^'\\]+'([[:space:]]*,[[:space:]]*trusted:[[:space:]]*(true|false))?[[:space:]]*(#.*)?$"
    tap_name_double='^[[:space:]]*tap[[:space:]]+"([^#{}"\]+)"([[:space:]]*,[[:space:]]*trusted:[[:space:]]*(true|false))?'
    tap_name_single="^[[:space:]]*tap[[:space:]]+'([^'\\]+)'([[:space:]]*,[[:space:]]*trusted:[[:space:]]*(true|false))?"
    tap_declaration='^[[:space:]]*tap([^[:alnum:]_]|$)'
    : > "${workdir}/taps.Brewfile"
    declare -A trusted_taps=()
    for brewfile in "${brewfiles[@]}"; do
        line_number=0
        while IFS= read -r line || [[ -n "${line}" ]]; do
            line_number=$((line_number + 1))
            if [[ "${line}" =~ ${tap_declaration} ]]; then
                if [[ "${line}" =~ ${tap_entry} || "${line}" =~ ${tap_single} ]]; then
                    printf '%s\n' "${line}" >> "${workdir}/taps.Brewfile"
                    if [[ "${line}" =~ ${tap_name_double} || "${line}" =~ ${tap_name_single} ]]; then
                        tap_name="${BASH_REMATCH[1]}"
                        tap_trust="${BASH_REMATCH[3]:-}"
                        if [[ "${tap_trust}" == "true" ]]; then
                            trusted_taps["${tap_name}"]=1
                        fi
                    fi
                else
                    printf 'FAIL: %s:%s: expected a quoted literal tap declaration: %s\n' "${brewfile}" "${line_number}" "${line}" >&2
                    printf 'Validation complete: refusing to evaluate non-literal tap lines.\n' >&2
                    exit 1
                fi
            fi
        done < "${brewfile}"
    done
    sort -u "${workdir}/taps.Brewfile" -o "${workdir}/taps.Brewfile"
    if [[ -s "${workdir}/taps.Brewfile" ]]; then
        echo "Syncing declared taps from:"
        printf '  %s\n' "${brewfiles[@]}"
        sed 's/^/  /' "${workdir}/taps.Brewfile"
        if brew bundle --file="${workdir}/taps.Brewfile" > "${workdir}/output" 2>&1; then
            echo "Tap setup passed."
        else
            rc=$?
            printf 'FAIL: tap setup (exit %s). Package checks were not run.\n' "${rc}" >&2
            printf 'Command: brew bundle --file=%q\n' "${workdir}/taps.Brewfile" >&2
            sed 's/^/  /' "${workdir}/output" >&2
            exit 1
        fi
    fi

    # The repository uses literal brew/cask declarations, not computed Ruby.
    # Reject malformed declarations rather than silently skipping them.
    #
    # Optional trailing options are restricted: only literal trusted: true|false
    # or args: { ... } are accepted. Non-literal trusted: values fail closed.
    double_entry='^[[:space:]]*(brew|cask)[[:space:]]+"([^"]+)"([[:space:]]*,[[:space:]]*(trusted:[[:space:]]*(true|false)|args:[[:space:]]*\{[^}]*\}))?[[:space:]]*(#.*)?$'
    single_entry="^[[:space:]]*(brew|cask)[[:space:]]+'([^']+)'([[:space:]]*,[[:space:]]*(trusted:[[:space:]]*(true|false)|args:[[:space:]]*\{[^}]*\}))?[[:space:]]*(#.*)?$"
    declaration='^[[:space:]]*(brew|cask)([^[:alnum:]_]|$)'
    checked=0
    failed=0
    for brewfile in "${brewfiles[@]}"; do
        printf '\nBrewfile: %s\n' "${brewfile}"
        line_number=0
        while IFS= read -r line || [[ -n "${line}" ]]; do
            line_number=$((line_number + 1))
            if [[ "${line}" =~ ${double_entry} || "${line}" =~ ${single_entry} ]]; then
                type="${BASH_REMATCH[1]}"
                name="${BASH_REMATCH[2]}"
                item_trust="${BASH_REMATCH[5]:-}"
                [[ "${type}" != brew ]] || type=formula
                checked=$((checked + 1))

                # Check third-party trust requirement
                tap_of_pkg=""
                if [[ "${name}" =~ ^([a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+)/[a-zA-Z0-9_@.-]+$ ]]; then
                    tap_of_pkg="${BASH_REMATCH[1]}"
                fi

                is_third_party=0
                if [[ -n "${tap_of_pkg}" && ! "${tap_of_pkg}" =~ ^homebrew/ ]]; then
                    is_third_party=1
                fi

                tap_is_trusted=0
                if [[ -n "${tap_of_pkg}" && "${trusted_taps[${tap_of_pkg}]:-0}" -eq 1 ]]; then
                    tap_is_trusted=1
                fi

                if [[ "${is_third_party}" -eq 1 && "${item_trust}" != "true" && "${tap_is_trusted}" -ne 1 ]]; then
                    failed=$((failed + 1))
                    printf 'FAIL: %s:%s: third-party %s %s needs trusted: true\n' "${brewfile}" "${line_number}" "${type}" "${name}" >&2
                    continue
                fi

                if [[ "${item_trust}" == "true" ]]; then
                    if ! brew trust "--${type}" -- "${name}" > "${workdir}/output" 2>&1; then
                        rc=$?
                        failed=$((failed + 1))
                        printf 'FAIL: %s:%s: brew trust --%s -- %s (exit %s)\n' "${brewfile}" "${line_number}" "${type}" "${name}" "${rc}" >&2
                        printf 'Command: brew trust --%s -- %q\n' "${type}" "${name}" >&2
                        sed 's/^/  /' "${workdir}/output" >&2
                        continue
                    fi
                fi

                # Pass names as data, never interpolate them into bash -c.
                # Serial checks keep each error adjacent to its source location.
                if brew info "--${type}" -- "${name}" > "${workdir}/output" 2>&1; then
                    printf 'PASS: %s:%s: %s %s\n' "${brewfile}" "${line_number}" "${type}" "${name}"
                else
                    rc=$?
                    failed=$((failed + 1))
                    printf 'FAIL: %s:%s: %s %s (exit %s)\n' "${brewfile}" "${line_number}" "${type}" "${name}" "${rc}" >&2
                    printf 'Command: brew info --%s -- %q\n' "${type}" "${name}" >&2
                    sed 's/^/  /' "${workdir}/output" >&2
                fi
            elif [[ "${line}" =~ ${declaration} ]]; then
                failed=$((failed + 1))
                printf 'FAIL: %s:%s: expected a quoted literal brew/cask name: %s\n' "${brewfile}" "${line_number}" "${line}" >&2
            fi
        done < "${brewfile}"
    done
    printf '\nValidation complete: %s Brewfiles, %s package checks, %s failures.\n' "${#brewfiles[@]}" "${checked}" "${failed}"
    [[ "${failed}" -eq 0 ]]
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
