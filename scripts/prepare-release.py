#!/usr/bin/env python3
"""检查发版 tag，并生成带安装说明的 Release 更新日志。"""

import argparse
from pathlib import Path
import plistlib
import re


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag", help="版本 tag，例如 v1.7.0")
    parser.add_argument("output", type=Path, help="Release 说明输出路径")
    args = parser.parse_args()
    if not re.fullmatch(r"v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", args.tag):
        parser.error("发版 tag 必须为 vx.y.z，例如 v1.7.0")

    root = Path(__file__).resolve().parent.parent
    version = args.tag[1:]
    with (root / "Support/Info.plist").open("rb") as source:
        app_version = plistlib.load(source)["CFBundleShortVersionString"]
    if version != app_version:
        parser.error(f"tag 版本 {version} 与应用版本 {app_version} 不一致，请先更新 Info.plist")

    changelog = (root / "CHANGELOG.md").read_text(encoding="utf-8")
    section = re.search(
        rf"^## \[{re.escape(version)}\] - \d{{4}}-\d{{2}}-\d{{2}}\s*\n"
        r"(.*?)(?=^## \[|^\[未发布\]:|\Z)",
        changelog,
        re.MULTILINE | re.DOTALL,
    )
    if section is None or not section.group(1).strip():
        parser.error(f"CHANGELOG.md 缺少 {version} 的更新内容，请先整理该版本的更新日志")

    notes = f"""{section.group(1).strip()}

### 下载与安装

要求 macOS 14 或更新版本。在「关于本机」查看芯片类型，选择对应安装包：

| Mac 芯片 | 安装包 |
|---|---|
| Apple Silicon（M 系列） | `iTimer-{version}-macos-arm64.dmg` |
| Intel | `iTimer-{version}-macos-x86_64.dmg` |

打开 DMG，将 iTimer 拖到 Applications。`SHA256SUMS` 提供两个安装包的 SHA-256 校验值。

当前安装包使用临时签名，尚未经过 Apple Developer ID 签名和公证。首次打开如被 macOS 拦截，请在「系统设置 › 隐私与安全性」中选择「仍要打开」。
"""
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(notes, encoding="utf-8")
    print(f"已验证 {args.tag}，Release 说明写入 {args.output}")


if __name__ == "__main__":
    main()
