# Runs only inside the disposable fixture selected in SandboxTerminalProbe.
# Every potentially unsupported command runs in a subshell, preserving the session.
function probe() {
  local label="$1"
  shift
  print -r -- "BEGIN $label"
  ( eval "$1" )
  local result=$?
  print -r -- "END $label status=$result"
}
[[ -t 0 && -t 1 ]]
print -r -- "isattyStatus=$?" > pty-basic.txt
{
  print -r -- "shellPid=$$"
  probe 'workspace-cwd' 'pwd -P'
  probe 'pty' '/bin/stty size < /dev/tty'
  probe 'workspace-read' '/bin/cat input.txt'
  probe 'workspace-write' 'printf "written\n" > created.txt && /bin/cat created.txt'
  probe 'pipe' 'printf "beta\nalpha\n" | /usr/bin/sort'
  probe 'child-shell' '/bin/sh -c "cat input.txt"'
  probe 'outside-read' '/bin/cat ../outside/control.txt'
  probe 'outside-write' 'printf "forbidden\n" > ../outside/written.txt'
  probe 'symlink-outside-read' '/bin/cat outside-link/control.txt'
  probe 'system-read' '/bin/cat /etc/hosts'
  probe 'app-home-write' 'printf "private\n" > "$HOME/probe.txt" && /bin/cat "$HOME/probe.txt"'
  probe 'shell-script-interpreted' '/bin/sh ./hello.sh'
  probe 'shell-script-exec' './hello.sh'
  probe 'workspace-binary' './hello'
  probe 'git-version' '/usr/bin/git --version'
  probe 'git-status' '/usr/bin/git status --short'
  probe 'git-commit' '/usr/bin/git add created.txt && /usr/bin/git -c user.name="Sandbox Fixture" -c user.email="fixture@example.invalid" -c commit.gpgsign=false commit -m "Sandbox fixture"'
  probe 'python-system' '/usr/bin/python3 -c "print(123)"'
  probe 'python-homebrew' '/opt/homebrew/bin/python3 -c "print(123)"'
  probe 'node-homebrew' '/opt/homebrew/bin/node -e "console.log(123)"'
  probe 'swift-version' '/usr/bin/swift --version'
  probe 'compiler' '/usr/bin/clang hello.c -o compiled-hello && ./compiled-hello'
  probe 'clean-environment' 'print -r -- "PATH=$PATH" "HOME=$HOME" "ZDOTDIR=$ZDOTDIR"'
  print 'PROBE_COMPLETE'
} 2>&1 | /usr/bin/tee terminal-probe.log
