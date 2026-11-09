"""Build a private screenshot fixture from the real app, using synthetic data only.

Native source in the repository is never edited. The copied app has a distinct
bundle id, disabled workspace persistence, a dedicated command store, and fixed
terminal transcripts that cannot execute input. No user sessions are loaded.
"""
from pathlib import Path
import json
import plistlib
import shutil
import subprocess
import textwrap

ROOT = Path(__file__).resolve().parents[2]
DEMO = Path('/tmp/vsux-marketing-demo')
PROJECT = DEMO / 'project'
APP = DEMO / 'vsux Demo.app'
FIXTURES = DEMO / 'Orbit Studio'
PROJECT.mkdir(parents=True, exist_ok=True)
for folder in ('Sources',):
    shutil.copytree(ROOT / folder, PROJECT / folder, dirs_exist_ok=True)
for folder in ('Vendor', 'Tests'):
    if not (PROJECT / folder).exists():
        (PROJECT / folder).symlink_to(ROOT / folder, target_is_directory=True)
shutil.copy2(ROOT / 'Package.resolved', PROJECT / 'Package.resolved')
package = (ROOT / 'Package.swift').read_text()
package = package.replace('.package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.7.3")', f'.package(path: "{DEMO}/swift-markdown")')
(PROJECT / 'Package.swift').write_text(package)
if not (DEMO / 'swift-markdown').exists():
    shutil.copytree(ROOT / '.build/checkouts/swift-markdown', DEMO / 'swift-markdown', ignore=shutil.ignore_patterns('.git'))
if not (DEMO / 'cmark').exists():
    (DEMO / 'cmark').symlink_to(ROOT / '.build/checkouts/swift-cmark', target_is_directory=True)

FIXTURES.mkdir(exist_ok=True)
(FIXTURES / 'src').mkdir(exist_ok=True)
(FIXTURES / 'docs').mkdir(exist_ok=True)
(FIXTURES / 'tests').mkdir(exist_ok=True)
(FIXTURES / 'package.json').write_text(json.dumps({'name': 'orbit-studio', 'private': True, 'scripts': {'dev': 'vite', 'test': 'vitest', 'build': 'vite build'}}, indent=2))
(FIXTURES / 'src/workspace.ts').write_text('''// Orbit Studio — fictional sample project
// Keep every project in its own flow.

export interface Workspace {
  name: string;
  directory: string;
  commands: Command[];
}

interface Command {
  label: string;
  run: string;
}

export const studio: Workspace = {
  name: "Orbit Studio",
  directory: "./projects/orbit-studio",
  commands: [
    { label: "Start development", run: "npm run dev" },
    { label: "Run tests", run: "npm test" },
    { label: "Build project", run: "npm run build" },
  ],
};

export function findCommand(label: string) {
  return studio.commands.find(command =>
    command.label === label
  );
}
''')
(FIXTURES / 'README.md').write_text('# Orbit Studio\n\nA fictional project for the vsux product showcase.\n\n## Getting started\n\n```sh\nnpm install\nnpm run dev\n```\n\n## Workflow\n\n- Open a workspace\n- Split your terminal\n- Keep commands close\n')
(FIXTURES / 'docs/workflow.md').write_text('# A little more flow\n\nYour terminal. Your files. One workspace.\n')
(FIXTURES / 'tests/workspace.test.ts').write_text('import { studio } from "../src/workspace";\n\n// Fictional fixture for product photography.\nconsole.assert(studio.name === "Orbit Studio");\n')

# The transcripts are illustrative fixtures, never real command output or metrics.
(DEMO / 'terminal.py').write_text(r'''import sys, time
blue = '\x1b[38;2;89;186;255m'
green = '\x1b[38;2;141;206;146m'
gray = '\x1b[38;2;130;139;151m'
white = '\x1b[38;2;223;228;234m'
reset = '\x1b[0m'
print('\x1b[2J\x1b[H', end='')
right = len(sys.argv) > 1 and sys.argv[1] == 'tests'
if right:
    print(blue + 'orbit-studio ' + gray + 'on ' + green + 'main' + reset)
    print(blue + '❯ ' + white + 'npm test' + reset + '\n')
    print(gray + '> orbit-studio / test' + reset)
    print(gray + '> vitest' + reset + '\n')
    print(blue + ' RUN ' + white + ' Orbit Studio' + reset + '\n')
    for label in ['workspace', 'commands', 'layout']:
        print(green + ' ✓ ' + white + f'tests/{label}.test.ts' + reset)
    print('\n' + gray + ' Test Files  ' + green + '3 passed' + reset)
    print(gray + '      Tests  ' + green + '12 passed' + reset)
    print('\n' + green + ' PASS ' + gray + ' Watching for file changes…' + reset)
    print('\n' + gray + ' Fictional demo output' + reset)
else:
    print(blue + 'orbit-studio ' + gray + 'on ' + green + 'main' + reset)
    print(blue + '❯ ' + white + 'npm run dev' + reset + '\n')
    print(gray + '> orbit-studio / dev' + reset)
    print(gray + '> vite' + reset + '\n')
    print(green + '  VITE ' + gray + ' development server' + reset + '\n')
    print(green + '  ➜ ' + white + ' Local:   ' + blue + 'http://localhost:5173/' + reset)
    print(gray + '  ➜  press h to show help' + reset + '\n')
    print(gray + '  ready — waiting for changes' + reset + '\n')
    print(blue + '  [vite] ' + white + 'hmr update /src/workspace.ts' + reset)
    print(blue + '  [vite] ' + white + 'hmr update /src/styles.css' + reset)
    print('\n' + gray + '  Fictional demo output' + reset)
sys.stdout.flush()
while True: time.sleep(30)
''')

sources = PROJECT / 'Sources/CmuxClone'
app_file = sources / 'Application.swift'
app_source = app_file.read_text()
app_source = app_source.replace('let app = NSApplication.shared', '''UserDefaults.standard.set(ProcessInfo.processInfo.environment["VSUX_DEMO_LANGUAGE"] == "en" ? "en" : "zh-Hans", forKey: "appLanguage")
        UserDefaults.standard.set("dark", forKey: "appAppearance")
        var demoSettings = TerminalSettings()
        demoSettings.theme = "dark"
        demoSettings.fontSize = 13
        demoSettings.cursorBlink = false
        UserDefaults.standard.set(try? JSONEncoder().encode(demoSettings), forKey: "terminalSettings")
        let app = NSApplication.shared''', 1)
app_source = app_source.replace('WorkspaceSession()', f'WorkspaceSession(directory: URL(fileURLWithPath: "{DEMO}/session"))')
app_source = app_source.replace('''workspacePersistenceEnabled = true
        newWindow(nil)''', '''workspacePersistenceEnabled = false
        presentMarketingDemo()''', 1)
app_source = app_source.replace('    @objc func newWindow', r'''    private func presentMarketingDemo() {
        var studio = Workspace(name: "Orbit Studio", directory: "/tmp/vsux-marketing-demo/Orbit Studio")
        studio.description = "Website & design system"
        studio.isPinned = true
        let left = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let right = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        var development = TerminalTab(title: "Development", pane: left)
        development.customTitle = true
        development.layout = .split(id: UUID(), axis: .horizontal, fraction: 0.53, first: .leaf(left), second: .leaf(right))
        studio.tabs = [development, TerminalTab(title: "Git", pane: UUID())]
        studio.tabs[1].customTitle = true
        studio.selectedTabID = development.id
        var api = Workspace(name: "Orbit API", directory: studio.directory)
        api.description = "Local services"
        api.color = "green"
        var docs = Workspace(name: "Documentation", directory: studio.directory)
        docs.description = "Guides & notes"
        docs.color = "orange"
        let model = WindowModel(workspaces: [studio, api, docs], shellCommand: "/usr/bin/python3 /tmp/vsux-marketing-demo/terminal.py dev")
        model.paneTabs[left] = [PaneTerminalTab(id: left, title: "Dev server", customTitle: true)]
        model.paneTabs[right] = [PaneTerminalTab(id: right, title: "Tests", customTitle: true)]
        for (name, command) in [
            ("Start development", "npm run dev"),
            ("Run tests", "npm test"),
            ("Build project", "npm run build"),
            ("Review changes", "git diff"),
            ("Check workspace", "git status --short")
        ] { _ = CommandLibrary.shared.put(SavedCommand(name: name, command: command), in: studio.id) }
        let docsPreview = WorkspaceService(
            name: "Docs preview",
            command: "/usr/bin/python3 -m http.server 43281 --bind 127.0.0.1",
            workingDirectory: "docs"
        )
        model.addService(docsPreview, to: studio.id)
        model.startService(docsPreview.id)
        if ProcessInfo.processInfo.environment["VSUX_DEMO_SCENE"] == "editor" {
            model.tools.sidebar = .files
            let files = model.tools.files(studio)
            files.expandedPaths.insert(studio.directory + "/src")
            files.refresh()
            files.open(URL(fileURLWithPath: studio.directory + "/README.md"), preview: false)
            files.open(URL(fileURLWithPath: studio.directory + "/src/workspace.ts"), preview: false)
            model.tools.content = .editor
        }
        let controller = TerminalWindowController(model: model)
        presentWindow(controller, save: false)
        controller.window?.setContentSize(NSSize(width: 1440, height: 820))
        controller.window?.center()
    }
    @objc func newWindow''', 1)
app_file.write_text(app_source)
library_file = sources / 'CommandLibrary.swift'
library_file.write_text(library_file.read_text().replace('static let shared = CommandLibrary()', f'static let shared = CommandLibrary(directory: URL(fileURLWithPath: "{DEMO}/commands"))'))
terminal_file = sources / 'GhosttyBridge.swift'
terminal_file.write_text(terminal_file.read_text().replace('self.command = command', 'self.command = paneID.uuidString == "22222222-2222-2222-2222-222222222222" ? "/usr/bin/python3 /tmp/vsux-marketing-demo/terminal.py tests" : command'))

import os
build_env = dict(os.environ, SWIFTCI_USE_LOCAL_DEPS='1')
subprocess.run(['swift', 'build', '--package-path', str(PROJECT), '-c', 'debug'], env=build_env, check=True)
bin_path = subprocess.check_output(['swift', 'build', '--package-path', str(PROJECT), '-c', 'debug', '--show-bin-path'], env=build_env, text=True).strip()
shutil.copytree(ROOT / 'dist/vsux.app', APP, dirs_exist_ok=True)
shutil.copy2(Path(bin_path) / 'CmuxClone', APP / 'Contents/MacOS/vsux')
shutil.copytree(Path(bin_path) / 'CmuxClone_CmuxClone.bundle', APP / 'Contents/Resources/CmuxClone_CmuxClone.bundle', dirs_exist_ok=True)
plist_file = APP / 'Contents/Info.plist'
plist = plistlib.loads(plist_file.read_bytes())
plist.update(CFBundleIdentifier='local.vsux.marketing-demo', CFBundleName='vsux Demo', CFBundleDisplayName='vsux Demo')
plist_file.write_bytes(plistlib.dumps(plist))
subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(APP)], check=True)
print(APP)
