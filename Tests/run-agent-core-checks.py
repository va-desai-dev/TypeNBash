#!/usr/bin/env python3
"""Compile and exercise the production BYOK core without app packages or API keys."""
import pathlib
import platform
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
store = '--app-store' in sys.argv
sources = ['AgentTypes', 'AgentConnection', 'AgentChatCompletionStream', 'AgentHTTPProvider', 'AgentRunner', 'AgentWorkspaceTools', 'AgentLocalCommand']
with tempfile.TemporaryDirectory(prefix='typenbash-byok-', dir='/tmp') as directory:
    temporary = pathlib.Path(directory)
    executable = temporary / 'AgentChecks'
    command = ['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
               '-default-isolation', 'MainActor', '-enable-upcoming-feature', 'NonisolatedNonsendingByDefault', '-target', f'{platform.machine()}-apple-macos26.0',
               '-module-cache-path', str(temporary / 'ModuleCache'),
               '-D', 'HARNESS_CORE', '-D', 'APP_STORE' if store else 'DIRECT_DISTRIBUTION']
    command += [str(root / 'TypeNBash/AppClasses/AgentsControl' / (name + '.swift')) for name in sources]
    command += [str(root / 'Tests/AgentIntegrationChecks.swift'), '-o', str(executable)]
    subprocess.run(command, check=True)
    subprocess.run([str(executable)], check=True)
    if store:
        symbols = subprocess.check_output(['nm', str(executable)], text=True)
        assert 'AgentLocalCommand' not in symbols, 'App Store executable contains local command implementation'
        print('PASS: App Store executable excludes the local command implementation')
