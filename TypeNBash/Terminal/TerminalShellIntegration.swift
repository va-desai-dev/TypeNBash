import Foundation

/// Installs prompt reporting without modifying the user's shell configuration.
/// All interactive SSH connections are created by the profile flow, which also
/// owns the filesystem, telemetry, and remote shell's lifetime.
enum TerminalShellIntegration {
    static func makeZDOTDIR() -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TypeNBash-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try zshHook.write(to: directory.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
            return directory
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
    }

    /// OpenSSH executes commands through the account's shell. Explicitly invoke
    /// sh so setup also works when the account's default shell is fish or csh.
    /// Never fall back to a shell without integration: that silently desyncs the
    /// sidebar. Prefer the account's bash/zsh, otherwise use an available bash.
    static func remoteLaunchCommand(workingDirectory: String) -> String {
        let script = """
        cd \(posixQuote(workingDirectory)) || exit 1
        case "${SHELL:-}" in
          */zsh|*/bash) __TypeNBash_shell="$SHELL" ;;
          *) __TypeNBash_shell=$(command -v bash) || {
            printf '%s\\n' 'TypeNBash requires bash or zsh for a managed SSH terminal.' >&2
            exit 1
          } ;;
        esac
        __TypeNBash_dir=$(mktemp -d) || exit 1
        export TypeNBash_RC_DIR="$__TypeNBash_dir"
        export TypeNBash_START_DIRECTORY=\(posixQuote(workingDirectory))
        case "$__TypeNBash_shell" in
          *zsh)
            cat > "$__TypeNBash_dir/.zshrc" <<'__TypeNBash_RC__'
        \(zshHook)
        __TypeNBash_RC__
            export ZDOTDIR="$__TypeNBash_dir"
            exec "$__TypeNBash_shell" -i
            ;;
          *bash)
            cat > "$__TypeNBash_dir/rc" <<'__TypeNBash_RC__'
        \(bashHook)
        __TypeNBash_RC__
            exec "$__TypeNBash_shell" --rcfile "$__TypeNBash_dir/rc" -i
            ;;
        esac
        """
        return "exec /bin/sh -c " + posixQuote(script)
    }

    private static let commonHook = #"""
    # Encode bytes, including %, #, ?, spaces and UTF-8, before building OSC 7.
    # A raw filesystem path is not a URI and can be truncated by URL parsing.
    __TypeNBash_osc7() {
      local LC_ALL=C
      local value="$PWD" encoded='' char escaped ordinal i
      for ((i=0; i<${#value}; i++)); do
        char="${value:$i:1}"
        case "$char" in
          [a-zA-Z0-9/._~-]) encoded="$encoded$char" ;;
          *) printf -v ordinal '%d' "'$char"
             printf -v escaped '%%%02X' "$((ordinal & 255))"
             encoded="$encoded$escaped" ;;
        esac
      done
      printf '\033]7;file://%s%s\007' "${HOST:-${HOSTNAME:-localhost}}" "$encoded"
    }
    # Guard the ordinary interactive command. This is an app workflow guard,
    # not a security sandbox; explicit binary invocations can bypass functions.
    unalias ssh 2>/dev/null
    ssh() {
      printf '%s\n' 'TypeNBash: Connect using the SSH button and a host profile so the terminal, files, and telemetry share one connection.' >&2
      return 126
    }
    if [ -n "${TypeNBash_START_DIRECTORY:-}" ]; then
      cd -- "$TypeNBash_START_DIRECTORY"
      unset TypeNBash_START_DIRECTORY
    fi
    """#

    private static let cleanupRemoteRC = #"""
    # Remove only the generated files after the shell has opened this rc.
    if [ -n "${TypeNBash_RC_DIR:-}" ]; then
      rm -f -- "$TypeNBash_RC_DIR/.zshrc" "$TypeNBash_RC_DIR/rc"
      rmdir -- "$TypeNBash_RC_DIR" 2>/dev/null
      unset TypeNBash_RC_DIR
    fi
    """#

    private static var zshHook: String {
        #"""
        # TypeNBash shell integration (auto-generated)
        """# + "\n" + cleanupRemoteRC + "\n" + #"""
        # Restore normal rc lookup for nested shells before loading user config.
        unset ZDOTDIR
        [ -f "$HOME/.zprofile" ] && source "$HOME/.zprofile"
        [ -f "$HOME/.zshrc" ] && source "$HOME/.zshrc"
        """# + "\n" + commonHook + "\n" + #"""
        autoload -Uz add-zsh-hook 2>/dev/null
        __TypeNBash_preexec() { printf '\033]133;C\007'; }
        __TypeNBash_precmd() {
          local exit_code=$?
          printf '\033]133;D;%s\007' "$exit_code"
          __TypeNBash_osc7
          printf '\033]133;A\007'
        }
        if (( $+functions[add-zsh-hook] )); then
          add-zsh-hook precmd __TypeNBash_precmd
          add-zsh-hook preexec __TypeNBash_preexec
        else
          precmd_functions+=(__TypeNBash_precmd)
          preexec_functions+=(__TypeNBash_preexec)
        fi
        zle_bracketed_paste=($'\e[?2004h' $'\e[?2004l')
        """#
    }

    private static var bashHook: String {
        cleanupRemoteRC + "\n" + #"""
        if [ -f "$HOME/.bash_profile" ]; then . "$HOME/.bash_profile"
        elif [ -f "$HOME/.bash_login" ]; then . "$HOME/.bash_login"
        elif [ -f "$HOME/.profile" ]; then . "$HOME/.profile"
        else [ ! -f "$HOME/.bashrc" ] || . "$HOME/.bashrc"
        fi
        """# + "\n" + commonHook + "\n" + #"""
        __TypeNBash_precmd() {
          local exit_code=$?
          printf '\033]133;D;%s\007' "$exit_code"
          __TypeNBash_osc7
          printf '\033]133;A\007'
        }
        # Preserve both scalar and array PROMPT_COMMAND configurations. Appending
        # by string concatenation turns the first array entry into invalid shell
        # syntax on newer bash prompt frameworks.
        if [[ "$(declare -p PROMPT_COMMAND 2>/dev/null)" == 'declare -a '* ]]; then
          PROMPT_COMMAND=(__TypeNBash_precmd "${PROMPT_COMMAND[@]}")
        else
          PROMPT_COMMAND="__TypeNBash_precmd${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
        fi
        """#
    }

    private static func posixQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
