#!/usr/bin/env python3
"""Find packages in the pub cache that lost their files.

`flutter pub get` counts a package as installed when its directory and the
content hash it recorded are in the pub cache.  It never looks inside the
directory.  A package whose files were deleted afterwards (by a tool that was
told to reinstall it and was stopped half way, say) still gets "Got
dependencies!", and the build then fails with

    Error: Error when reading '.../.pub-cache/hosted/pub.dev/NAME-VERSION/lib/
    NAME.dart': No such file or directory

This script reads .dart_tool/package_config.json, which says where pub put
every package, and reports the hosted packages that are visibly incomplete:

  * no pubspec.yaml (every package on pub.dev has one),
  * a library directory (lib/) that exists but holds no file (a package has
    no use for one; none in a healthy cache of this project has it), or
  * a file the project imports (package:NAME/FILE) that is not there.

A package without a lib/ directory at all is fine: asset-only and
Android-only packages, such as cupertino_icons, ship none.  Other empty
directories (doc/api, test, ...) are fine too; published archives have them.

    check_pub_cache.py [PROJECT]

PROJECT is a Flutter or Dart project directory (default: the one holding this
tool/ directory).  Exit status: 0 when nothing is wrong, or nothing is cached
yet; 1 when a package is incomplete (it is listed on stdout); 2 when the
package configuration cannot be read.  `flutter pub cache repair`, run in the
project, reinstalls the packages in its pubspec.lock.
"""

from __future__ import annotations

import json
import os
import re
import sys
from urllib.parse import unquote, urlparse
from urllib.request import url2pathname

# Where the project's own Dart code lives.  These are the files a build or a
# test run compiles, so the packages they import must be complete.
SOURCE_DIRS = ("lib", "test")

# import 'package:NAME/FILE' ... ;  and  export ... ;  The rest of the
# directive can hold `if (dart.library.io) 'package:NAME/FILE'` alternatives.
DIRECTIVE = re.compile(
    r"""^[ \t]*(?:import|export)[ \t\r\n]+(?P<uri>'[^']*'|"[^"]*")(?P<rest>[^;]*);""",
    re.MULTILINE)
CONFIGURED_URI = re.compile(r"""\)\s*(?P<uri>'[^']*'|"[^"]*")""")


class CheckError(Exception):
    """The package configuration cannot be read."""


def package_directories(config_path: str) -> dict[str, tuple[str, str]]:
    """Return {package name: (root directory, library directory name)}."""
    try:
        with open(config_path, encoding="utf-8") as f:
            config = json.load(f)
        entries = config["packages"]
    except FileNotFoundError:
        return {}
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise CheckError(f"cannot read {config_path}: {error}") from error
    base = os.path.dirname(os.path.abspath(config_path))
    found = {}
    for entry in entries:
        try:
            name, root_uri = entry["name"], entry["rootUri"]
        except (KeyError, TypeError):
            continue
        parsed = urlparse(root_uri)
        if parsed.scheme == "file":
            root = url2pathname(parsed.path)
        elif parsed.scheme == "":
            # A relative reference is relative to the configuration file.
            root = os.path.normpath(os.path.join(base, unquote(parsed.path)))
        else:
            continue
        found[name] = (os.path.normpath(root), entry.get("packageUri") or "lib/")
    return found


def in_hosted_cache(root: str) -> bool:
    """Whether ROOT is <pub cache>/hosted/<host>/<name>-<version>."""
    return os.path.basename(os.path.dirname(os.path.dirname(root))) == "hosted"


def has_files(directory: str) -> bool:
    return any(files for _, _, files in os.walk(directory))


def imported_files(project: str) -> dict[str, set[str]]:
    """Return {package name: the files of it that the project imports}."""
    imported: dict[str, set[str]] = {}
    for source_dir in SOURCE_DIRS:
        for directory, _, files in os.walk(os.path.join(project, source_dir)):
            for name in files:
                if not name.endswith(".dart"):
                    continue
                try:
                    with open(os.path.join(directory, name), encoding="utf-8",
                              errors="replace") as f:
                        text = f.read()
                except OSError:
                    continue
                for directive in DIRECTIVE.finditer(text):
                    literals = [directive.group("uri")]
                    literals += [m.group("uri") for m in
                                 CONFIGURED_URI.finditer(directive.group("rest"))]
                    for literal in literals:
                        uri = literal[1:-1]
                        if not uri.startswith("package:"):
                            continue
                        package, _, path = uri[len("package:"):].partition("/")
                        if package and path:
                            imported.setdefault(package, set()).add(path)
    return imported


def incomplete_packages(project: str) -> list[tuple[str, str, str]]:
    """Return (package directory, name and version, what is wrong) per package."""
    config_path = os.path.join(project, ".dart_tool", "package_config.json")
    packages = package_directories(config_path)
    imports = imported_files(project)
    problems = []
    for name in sorted(packages):
        root, package_uri = packages[name]
        # A package that is not there at all is not damage: `pub get` downloads it.
        if not in_hosted_cache(root) or not os.path.isdir(root):
            continue
        library = os.path.join(root, package_uri)
        label = os.path.basename(root)
        if label.startswith(name + "-"):
            label = f"{name} {label[len(name) + 1:]}"
        if not os.path.isfile(os.path.join(root, "pubspec.yaml")):
            problems.append((root, label, "pubspec.yaml is missing"))
        elif os.path.isdir(library) and not has_files(library):
            problems.append((root, label, f"{package_uri} is empty"))
        else:
            for path in sorted(imports.get(name, ())):
                if not os.path.isfile(os.path.join(library, path)):
                    problems.append((root, label, f"{package_uri}{path} is missing"))
                    break
    return problems


def main(argv: list[str]) -> int:
    if any(arg in ("-h", "--help") for arg in argv):
        print(__doc__.strip())
        return 0
    args = [arg for arg in argv if not arg.startswith("-")]
    if len(argv) != len(args) or len(args) > 1:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    project = args[0] if args else os.path.dirname(
        os.path.dirname(os.path.abspath(__file__)))
    try:
        problems = incomplete_packages(project)
    except CheckError as error:
        print(f"check_pub_cache: {error}", file=sys.stderr)
        return 2
    if not problems:
        return 0
    print("These packages are incomplete in the pub cache, though `flutter pub get`"
          " counts them as installed:")
    for root, label, problem in problems:
        print(f"  {label}: {problem}")
        print(f"    {root}")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
