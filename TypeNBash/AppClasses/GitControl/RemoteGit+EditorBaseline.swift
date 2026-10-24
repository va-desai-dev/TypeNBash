import Foundation

extension RemoteGit {
    /// One bounded SSH request; Git reads only the selected HEAD blob. Arguments
    /// remain literal, including filenames containing quotes, newlines or colons.
    nonisolated static let editorBaselineScript = #"""
    import json, os, subprocess, sys

    def baseline():
        path = os.path.abspath(sys.argv[1])
        directory = os.path.dirname(path)
        environment = dict(os.environ, GIT_TERMINAL_PROMPT="0", GIT_OPTIONAL_LOCKS="0", GIT_NO_LAZY_FETCH="1")
        def git(*arguments):
            return subprocess.run(
                ["git", "--literal-pathspecs", "-C", directory, *arguments],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=environment, timeout=5)

        prefix = git("rev-parse", "--show-prefix")
        if prefix.returncode != 0:
            return None
        relative = prefix.stdout[:-1].decode("utf-8") + os.path.basename(path)
        head = git("rev-parse", "--verify", "-q", "HEAD^{tree}")
        if head.returncode != 0:
            # An unborn branch has no baseline. Other HEAD failures use saved text.
            branch = git("symbolic-ref", "-q", "HEAD")
            if branch.returncode == 0 and git("show-ref", "--verify", "--quiet", branch.stdout.decode().strip()).returncode == 1:
                return ""
            return None
        tree = head.stdout.decode().strip()
        entry = git("ls-tree", "--full-tree", "-z", tree, "--", relative)
        if entry.returncode != 0:
            return None
        if not entry.stdout:
            return ""
        metadata, name = entry.stdout.split(b"\t", 1)
        mode, kind, oid = metadata.split()
        if kind != b"blob" or mode == b"120000":
            return None
        object_id = oid.decode("ascii")
        size = git("cat-file", "-s", object_id)
        if size.returncode != 0 or int(size.stdout) > 2 * 1024 * 1024:
            return None
        contents = git("cat-file", "blob", object_id)
        if contents.returncode != 0 or b"\0" in contents.stdout:
            return None
        return contents.stdout.decode("utf-8")

    try:
        result = baseline()
    except (OSError, ValueError, subprocess.SubprocessError):
        result = None
    print(json.dumps(result))
    """#
}
