#!/usr/bin/env python3
"""Read-only inventory of outer NeAntik bundles and archives; never deletes."""
from __future__ import annotations

import argparse
import json
import os
import plistlib
from pathlib import Path


def inventory(roots: list[Path]) -> tuple[list[dict], list[str]]:
    items: dict[str, dict] = {}
    errors: list[str] = []
    for root in roots:
        if not root.exists():
            continue
        for directory, folders, files in os.walk(root, followlinks=False,
                                               onerror=lambda e: errors.append(str(e))):
            for name in list(folders):
                path = Path(directory) / name
                try:
                    linked = path.is_symlink()
                except OSError as error:
                    errors.append(str(error))
                    folders.remove(name)
                    continue
                if name in {".git", "node_modules"} or linked:
                    folders.remove(name)
                elif name.endswith(".app"):
                    # Chromium helper apps are components, not extra installations.
                    folders.remove(name)
                    if "neantik" not in name.casefold():
                        continue
                    row = {"path": str(path), "kind": "app", "version": "unknown"}
                    try:
                        with (path / "Contents/Info.plist").open("rb") as stream:
                            info = plistlib.load(stream)
                        row["version"] = f'{info.get("CFBundleShortVersionString", "?")} ({info.get("CFBundleVersion", "?")})'
                    except (OSError, ValueError, plistlib.InvalidFileException) as error:
                        errors.append(f"{path}: {error}")
                    items[str(path)] = row
            for name in files:
                path = Path(directory) / name
                if ("neantik" in name.casefold() and path.suffix.lower() in {".zip", ".dmg"}
                        and not path.is_symlink()):
                    items[str(path)] = {"path": str(path), "kind": "archive", "version": "see filename"}
    return sorted(items.values(), key=lambda row: row["path"]), errors


def render(items: list[dict], errors: list[str], roots: list[Path], history: list[dict]) -> str:
    def exists(path: Path) -> str:
        try:
            return str(path.exists())
        except OSError:
            return "нет доступа для проверки"
    apps = [item for item in items if item["kind"] == "app"]
    archives = [item for item in items if item["kind"] == "archive"]
    lines = ["# NeAntik: локальные копии", "", "Это инвентаризация, НЕ список разрешённых удалений.",
             "Вложенные Chromium/helper .app не считаются отдельными версиями.",
             "Корзина не очищается; перенос туда сам по себе не освобождает место.", "",
             "## Область поиска", ""]
    lines += [f"- `{root}`" for root in roots]
    for title, rows in [(f"Найденные приложения: {len(apps)}", apps),
                        (f"Найденные ZIP/DMG: {len(archives)}", archives)]:
        lines += ["", f"## {title}", ""]
        for row in rows:
            lines += [f'- `{row["path"]}` — {row["version"]}']
    lines += ["", "## Предыдущая уборка: исходный путь → Корзина", ""]
    for row in history:
        original = Path(row["original"])
        destination = Path(row["trash"])
        lines += [f"- Было: `{original}`", f"  Корзина: `{destination}`",
                  f"  Сейчас исходный путь существует: {exists(original)}; путь в Корзине: {exists(destination)}"]
    lines += ["", "## Ограничения и ошибки чтения", ""]
    lines += [f"- {error}" for error in errors] or ["Ошибок чтения не зарегистрировано."]
    lines += ["", "Поиск ограничен перечисленными папками; это не сканирование всех дисков.", ""]
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--history", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    workspace = args.workspace.resolve()
    roots = sorted(path for path in workspace.iterdir() if path.is_dir() and not path.is_symlink()
                   and ("neantik" in path.name.casefold() or path.name == "nevision"))
    roots += [Path("/Applications"), *(Path.home() / name for name in ("Applications", "Downloads", "Desktop"))]
    items, errors = inventory(roots)
    history = json.loads(args.history.read_text()) if args.history else []
    report = render(items, errors, roots, history)
    if args.output:
        args.output.write_text(report, encoding="utf-8")
        print(f"Report: {args.output}\nApps: {sum(row['kind'] == 'app' for row in items)}; archives: {sum(row['kind'] == 'archive' for row in items)}; read errors: {len(errors)}")
    else:
        print(report)


if __name__ == "__main__":
    main()
