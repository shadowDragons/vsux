#!/usr/bin/env python3
"""Export reviewed source without the private development Git history."""
import hashlib
import json
import argparse
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", default="dist/open-source/vsux", help="new export directory relative to the project root")
args = parser.parse_args()
destination = (root / args.output).resolve()
export_root = (root / "dist/open-source").resolve()
if export_root not in destination.parents:
    raise SystemExit("Export directory must be inside dist/open-source")
if destination.exists():
    raise SystemExit(f"Refusing to overwrite existing export: {destination}")

# Deliberately explicit: never copy the project root, all of Vendor, or all docs.
files = {
    ".gitignore", "Package.swift", "Package.resolved", "README.md", "README.zh-CN.md", "LICENSE",
    "SECURITY.md", "THIRD_PARTY_NOTICES.md", "Vendor/Ghostty-LICENSE",
    "Scripts/bootstrap-ghostty.sh", "Scripts/build.sh", "Scripts/release.sh",
    "Scripts/check-localizations.py", "Scripts/make-icon.swift",
    "Scripts/prepare-open-source.py", ".github/workflows/release.yml",
    "docs/RELEASING.md",
}
for folder in ["Sources", "Tests", "Resources", "web"]:
    tracked = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", folder], cwd=root
    ).decode().split("\0")
    files.update(p for p in tracked if p)

# Reject symlinks and unexpected generated/credential paths, even if tracked.
for name in files:
    relative = Path(name)
    if any(part in {".git", "node_modules", "dist", ".build", ".swiftpm", "__pycache__"}
           for part in relative.parts):
        raise SystemExit(f"Unexpected generated path: {name}")
    if relative.name.startswith(".env") or relative.suffix in {".p12", ".pfx", ".pem", ".key", ".mobileprovision"}:
        raise SystemExit(f"Unexpected credential path: {name}")
    source = root / relative
    if not source.is_file() or source.is_symlink() or root not in source.resolve().parents:
        raise SystemExit(f"Not a regular source file inside the project: {name}")

destination.mkdir(parents=True)
for name in sorted(files):
    target = destination / name
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(root / name, target)

# Research remains in the private repository; avoid broken public README links.
readme = destination / "README.md"
text = readme.read_text()
replacements = {
    "搜索范围、上限和 REA 证据见 [行为报告](analysis/vscode/search/behavior-and-implementation.md)。": "",
    "通知的来源、合并规则和验证见 [行为记录](analysis/vscode/notifications/behavior-and-implementation.md)。": "",
    "VS Code 调查证据与本项目行为对应表见 `analysis/vscode/markdown/behavior-and-implementation.md`。": "",
    "调查材料保留在 `analysis/cmux/` 和 `analysis/vscode/`。VS Code 文件树、Markdown 和语法高亮的行为依据与 REA 覆盖边界分别记录在对应调查报告中。": "",
    "Ghostty terminfo 通过本机原版 cmux 附带的条目以 `infocmp` 重建，遵循同一许可。": "Ghostty terminfo 通过 `infocmp` 从本机 terminfo 条目生成。",
}
for before, after in replacements.items():
    text = text.replace(before, after)
if "analysis/" in text:
    raise SystemExit("Unreviewed research reference remains in exported README")
readme.write_text(text)

manifest = {
    "source_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
    "includes_current_working_files": True,
    "files": [{"path": name, "sha256": hashlib.sha256((destination / name).read_bytes()).hexdigest()}
              for name in sorted(files)],
}
(destination.parent / "export-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(f"Exported {len(files)} files to {destination}")
print("No Git history was copied. Review and scan before creating a public repository.")
