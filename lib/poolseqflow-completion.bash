#!/usr/bin/env bash
#
# Tab completion for PoolSeqFlow, in bash and in zsh.
#
# SOURCED, never run. `PoolSeqFlow install` puts it in the user's bash-completion directory,
# where bash finds it by the command's name. zsh does not read that directory, so it needs two
# lines in ~/.zshrc, and install prints them:
#
#     autoload -U +X bashcompinit && bashcompinit
#     . ~/.local/share/bash-completion/completions/PoolSeqFlow
#
# NOTHING HERE RUNS THE WRAPPER. It evaluates `conda shell.bash hook` before it dispatches, which
# costs about 0.4s, and a keystroke cannot. Every list below is a literal or comes from the
# filesystem.

# The installation directory the command word resolves to. $bindir/PoolSeqFlow is a symlink into
# $prefix/opt/PoolSeqFlow-<version>/, so the resolved file's directory is the installation.
#
# Symlinks are followed a hop at a time with plain `readlink`, not `readlink -f`: the `-f` is a
# GNU extension that BSD and macOS do not carry. A relative target resolves against the
# directory of the link that named it.
_poolseqflow_install_dir() {
    local exe dir hops=0
    exe=$(command -v "$1" 2>/dev/null) || return 1
    while [ -L "$exe" ]; do
        hops=$((hops + 1))
        [ "$hops" -gt 20 ] && return 1
        dir=$(cd "$(dirname "$exe")" 2>/dev/null && pwd -P) || return 1
        exe=$(readlink "$exe") || return 1
        case $exe in
            /*) ;;
            *) exe="$dir/$exe" ;;
        esac
    done
    dir=$(cd "$(dirname "$exe")" 2>/dev/null && pwd -P) || return 1
    printf '%s' "$dir"
}

# The modules installed into that installation, one per line. `lib` holds the shared libraries
# and is never named by a user, so it is not offered.
_poolseqflow_modules() {
    local dir entry
    dir=$(_poolseqflow_install_dir "$1") || return 0
    [ -d "$dir/analysis/modules" ] || return 0
    for entry in "$dir"/analysis/modules/*/; do
        [ -d "$entry" ] || continue
        entry=${entry%/}
        entry=${entry##*/}
        [ "$entry" = "lib" ] && continue
        printf '%s\n' "$entry"
    done
}

# Fill COMPREPLY with the words of $1 that start with $2, one array element each.
#
# A read loop rather than `mapfile`, which is a bash builtin zsh does not have. It also keeps
# each match one element without relying on word splitting, which differs between the two shells
# outside the `emulate -L sh` that zsh's bashcompinit wraps this call in.
_poolseqflow_reply() {
    local line
    COMPREPLY=()
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        COMPREPLY+=("$line")
    done < <(compgen -W "$1" -- "$2")
}

_poolseqflow() {
    local cur cmd top modules
    cur=${COMP_WORDS[COMP_CWORD]}
    cmd=${COMP_WORDS[0]}
    # Every verb the wrapper dispatches, which 00_static checks against its `case`.
    top="install init init_multi check run dryrun dryclean migrate_config clean reset"
    top="$top analysis version cite list uninstall uninstall_all"

    if [ "$COMP_CWORD" -eq 1 ]; then
        _poolseqflow_reply "$top" "$cur"
        return
    fi

    case ${COMP_WORDS[1]} in
        check)
            [ "$COMP_CWORD" -eq 2 ] && _poolseqflow_reply "install project" "$cur"
            ;;
        analysis)
            modules=$(_poolseqflow_modules "$cmd" | tr '\n' ' ')
            case $COMP_CWORD in
                2)
                    _poolseqflow_reply \
                        "install check modules complete version cite uninstall $modules" "$cur"
                    ;;
                3)
                    if [ "${COMP_WORDS[2]}" = modules ]; then
                        _poolseqflow_reply "list available install uninstall" "$cur"
                    else
                        _poolseqflow_reply "nocpp" "$cur"
                    fi
                    ;;
                4)
                    # `modules install <module>` offers nothing: the names come from the
                    # catalogue, which is read over the network.
                    [ "${COMP_WORDS[2]}" = modules ] && [ "${COMP_WORDS[3]}" = uninstall ] &&
                        _poolseqflow_reply "$modules" "$cur"
                    ;;
            esac
            ;;
    esac
}

# Both names the installer creates: the plain symlink and every versioned one on PATH.
# shellcheck disable=SC2046
complete -F _poolseqflow PoolSeqFlow $(compgen -c PoolSeqFlow- 2>/dev/null)
