#!/usr/bin/env python3
"""Refuse a build whose compiler wrote a warning down, whatever the compiler exited with.

    Tools/compiler-warnings.py <intermediates> [--whole-module] [--targets A,B,... | --no-test-targets]

Carried from XiaolaiDict (its ADR-0052), where it was measured; the reasoning below is theirs and holds here.

`<intermediates>` is one configuration of this package's build. Two builds pass one:
- `make test-swift` passes `.build/out/Intermediates.noindex/XDict.build/Debug`, which `swift test` has just built;
- `Tools/build-bundle.sh` passes `…/Release` with `--whole-module --no-test-targets`, after the `swift build` the
  bundle is made of.
With no `--targets`, the targets are `swift package dump-package`'s, so a target added later is read unasked (a binary
target compiles nothing and is left out); `--no-test-targets` leaves out the test targets, which `swift build` does
not compile.

**Why it exists.** A warning is an error in this package, and `-warnings-as-errors` does not make every warning one: a
stored property whose type is inferred from a module its file does not import is reported as a warning, carries no
diagnostic group, and exits 0 — measured on Swift 6.4 in XiaolaiDict, while an unused variable in the same build fails
it.

**Why files, not a log.** Each compile of a source writes its diagnostics to `<source>.dia` beside its object, and a
build that does not recompile the source leaves that file alone. A build log holds only what that build compiled: a
no-op rebuild printed no warning while the warning stood (measured). So this reads the files, through the toolchain's
own reader (`libclang`'s `clang_loadDiagnostics`) rather than a parser of its own, and fails loud on anything it cannot
read — a missing reader, an unreadable file, a target with no module directory, a source with no diagnostics file.
Nothing found is never a pass.

What it reads, per module, and refuses the build without: the diagnostics of every source its `.SwiftFileList` names,
and of the module job (`<module>-primary-emit-module.dia`), where a declaration's diagnostics are written as well. A
release build compiles each module **whole**, in one job: it writes one file, `<module>-primary.dia`, for every source
the list names, and none per source — so `--whole-module` requires and reads that file instead. The kind of build is
said, never guessed. A list that names no source is refused too. A `.dia` whose source the module no longer compiles —
a file moved or removed — is stale, counted and skipped.

**A warning belongs to the source it is about, not to the file that holds it.** Swift compiles sources in batches,
and a batch can write a warning located in one of its sources into another source's `.dia`: measured 2026-10-18, the
`#expect` expansions of `DictionaryTableDropTests.swift` landed in `AnywhereSentencesTests.dia`. Fix the first source
and its own `.dia` is rewritten clean, while the holder, not recompiled, keeps the warning until it happens to be. So
a warning is attributed by its location — a `.swift` file by its name, a macro expansion buffer by the file its
mangled name encodes — and, when that source's own `.dia` in the module is newer than the holder, it is stale:
counted and skipped. A holder at least as new, an attributed source with no `.dia` of its own, or a buffer name this
cannot decode keeps the warning: a real warning is never dropped.
"""
from __future__ import annotations

import argparse
import ctypes
import dataclasses
import json
import os
import pathlib
import re
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parents[1]
WARNING = 2  # CXDiagnostic_Warning; Error is 3 and Fatal 4. Notes (1) belong to the diagnostic they follow.


class CXString(ctypes.Structure):
    _fields_ = [("data", ctypes.c_void_p), ("private_flags", ctypes.c_uint)]


class Refusal(Exception):
    """Something this gate could not read, which is never a pass."""


def libclang() -> ctypes.CDLL:
    """The active toolchain's libclang, beside its clang, unless `XDICT_LIBCLANG` names another."""
    path = os.environ.get("XDICT_LIBCLANG")
    if path is None:
        found = subprocess.run(["xcrun", "--find", "clang"], capture_output=True, text=True)
        if found.returncode != 0:
            raise Refusal(f"xcrun cannot find clang, so not libclang either: {found.stderr.strip()}")
        path = str(pathlib.Path(found.stdout.strip()).parent.parent / "lib" / "libclang.dylib")
    try:
        library = ctypes.CDLL(path)
    except OSError as error:
        raise Refusal(f"cannot load libclang, the toolchain's reader of diagnostics files: {error}") from None
    library.clang_loadDiagnostics.restype = ctypes.c_void_p
    library.clang_loadDiagnostics.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_int),
                                              ctypes.POINTER(CXString)]
    library.clang_getNumDiagnosticsInSet.restype = ctypes.c_uint
    library.clang_getNumDiagnosticsInSet.argtypes = [ctypes.c_void_p]
    library.clang_getDiagnosticInSet.restype = ctypes.c_void_p
    library.clang_getDiagnosticInSet.argtypes = [ctypes.c_void_p, ctypes.c_uint]
    library.clang_getDiagnosticSeverity.restype = ctypes.c_int
    library.clang_getDiagnosticSeverity.argtypes = [ctypes.c_void_p]
    library.clang_formatDiagnostic.restype = CXString
    library.clang_formatDiagnostic.argtypes = [ctypes.c_void_p, ctypes.c_uint]
    library.clang_getCString.restype = ctypes.c_char_p
    library.clang_getCString.argtypes = [CXString]
    library.clang_disposeString.argtypes = [CXString]
    library.clang_disposeDiagnostic.argtypes = [ctypes.c_void_p]
    library.clang_disposeDiagnosticSet.argtypes = [ctypes.c_void_p]
    return library


def text(library: ctypes.CDLL, value: CXString) -> str:
    try:
        return (library.clang_getCString(value) or b"").decode("utf-8", "replace")
    finally:
        library.clang_disposeString(value)


def warnings_in(library: ctypes.CDLL, path: pathlib.Path) -> list[str]:
    """Every diagnostic of warning severity or worse in one file, formatted with its place."""
    error, message = ctypes.c_int(0), CXString()
    diagnostics = library.clang_loadDiagnostics(str(path).encode(), ctypes.byref(error), ctypes.byref(message))
    if not diagnostics:
        raise Refusal(f"{path}: libclang cannot read it (error {error.value}: {text(library, message)})")
    found = []
    try:
        for index in range(library.clang_getNumDiagnosticsInSet(diagnostics)):
            diagnostic = library.clang_getDiagnosticInSet(diagnostics, index)
            try:
                if library.clang_getDiagnosticSeverity(diagnostic) >= WARNING:
                    # Source location and column, as the compiler prints them.
                    found.append(text(library, library.clang_formatDiagnostic(diagnostic, 0x1 | 0x2)))
            finally:
                library.clang_disposeDiagnostic(diagnostic)
    finally:
        library.clang_disposeDiagnosticSet(diagnostics)
    return found


LOCATION = re.compile(r"^(?P<file>.+?):\d+:\d+: ")
MACRO_BUFFER = "@__swiftmacro_"


def swift_punycode(encoded: str) -> str | None:
    """Swift's Punycode (`lib/Basic/Punycode.cpp`): RFC 3492 with `_` as the delimiter and digits `a`-`z`, `A`-`J`;
    an ASCII character an identifier cannot hold (a file name's dot) is encoded as U+D800 plus its value."""
    basic, _, extended = encoded.rpartition("_")
    output = [ord(c) for c in basic]
    n, bias, i, index = 128, 72, 0, 0
    while index < len(extended):
        old, weight, k = i, 1, 36
        while True:
            if index >= len(extended):
                return None
            c = extended[index]
            index += 1
            digit = ord(c) - ord("a") if "a" <= c <= "z" else ord(c) - ord("A") + 26 if "A" <= c <= "J" else None
            if digit is None:
                return None
            i += digit * weight
            t = 1 if k <= bias else 26 if k >= bias + 26 else k - bias
            if digit < t:
                break
            weight *= 36 - t
            k += 36
        delta = (i - old) // (700 if old == 0 else 2)
        delta += delta // (len(output) + 1)
        k = 0
        while delta > (36 - 1) * 26 // 2:
            delta //= 36 - 1
            k += 36
        bias = k + (36 * delta) // (delta + 38)
        n += i // (len(output) + 1)
        i %= len(output) + 1
        output.insert(i, n)
        i += 1
    decoded = [point - 0xD800 if 0xD800 <= point < 0xD880 else point for point in output]
    return "".join(map(chr, decoded)) if all(0 <= point < 0x110000 for point in decoded) else None


def macro_source(buffer: str) -> tuple[str, str] | None:
    """The module and the source file a macro expansion buffer's name encodes, or None when the name does not decode.

    The name is `@__swiftmacro_` and the expansion's mangled context: the module, then the file, each an identifier —
    `<length><name>`, or `00<length><Swift Punycode>` when the name holds a character an identifier cannot, as a file
    name's dot."""
    name = pathlib.PurePath(buffer).name
    if not name.startswith(MACRO_BUFFER):
        return None
    rest = name[len(MACRO_BUFFER):]
    length = re.match(r"[1-9]\d*", rest)
    if not length or len(rest) < length.end() + int(length.group()):
        return None
    module = rest[length.end():length.end() + int(length.group())]
    rest = rest[length.end() + int(length.group()):]
    file = re.match(r"(00)?([1-9]\d*)", rest)
    if not file or len(rest) < file.end() + int(file.group(2)):
        return None
    identifier = rest[file.end():file.end() + int(file.group(2))]
    source = swift_punycode(identifier) if file.group(1) else identifier
    return (module, source) if source and source.endswith(".swift") and "/" not in source else None


def attributed_stem(warning: str, module: str, sources: set[str]) -> str | None:
    """The stem of the module's source a warning is about, by its location: a file the module's list names, or a
    macro expansion buffer whose name decodes to this module and one of its sources. None otherwise."""
    located = LOCATION.match(warning)
    if not located:
        return None
    file = located.group("file")
    if pathlib.PurePath(file).name.startswith(MACRO_BUFFER):
        decoded = macro_source(file)
        if decoded is None or decoded[0] != module:
            return None
        stem = pathlib.PurePath(decoded[1]).stem
        return stem if stem in {pathlib.PurePath(source).stem for source in sources} else None
    return pathlib.PurePath(file).stem if file in sources else None


def package_targets(tests: bool) -> list[str]:
    dumped = subprocess.run(["swift", "package", "dump-package", "--package-path", str(REPO)],
                            capture_output=True, text=True)
    if dumped.returncode != 0:
        raise Refusal(f"swift package dump-package failed: {dumped.stderr.strip()}")
    # A binary target (the core's XCFramework) compiles nothing and writes no diagnostics.
    targets = [target["name"] for target in json.loads(dumped.stdout)["targets"]
               if target["type"] != "binary" and (tests or target["type"] != "test")]
    if not targets:
        raise Refusal("swift package dump-package listed no target")
    return targets


def modules(build: pathlib.Path, target: str) -> list[pathlib.Path]:
    """Every module directory compiled for one target: the module itself (`-t` for a library, `-p` for a
    product) and, for an executable, the copy built for testing (`<target>-<hash>-testable`)."""
    own = re.compile(rf"{re.escape(target)}(-[0-9A-F]+-testable)?")
    return sorted(listed.parent for listed in build.glob("*.build/Objects-normal/*/*.SwiftFileList")
                  if own.fullmatch(listed.stem))


@dataclasses.dataclass
class Reading:
    """What one build's diagnostics said, and what it should have written and did not."""
    modules: int = 0
    read: int = 0
    stale: int = 0
    # Warnings a batch wrote into another source's `.dia`, older than that source's own.
    stale_warnings: int = 0
    unbuilt: list[str] = dataclasses.field(default_factory=list)
    empty: list[str] = dataclasses.field(default_factory=list)
    missing: list[str] = dataclasses.field(default_factory=list)
    # Ordered and each once: the same warning is written by a source's job and by its module's.
    warnings: dict[str, None] = dataclasses.field(default_factory=dict)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("intermediates", type=pathlib.Path)
    parser.add_argument("--whole-module", action="store_true",
                        help="each module was compiled in one job, as a release build compiles it")
    which = parser.add_mutually_exclusive_group()
    which.add_argument("--targets", help="comma-separated; this package's targets if absent")
    which.add_argument("--no-test-targets", action="store_true",
                       help="this package's targets but its test targets, which `swift build` does not compile")
    return parser.parse_args()


def expected_files(listed: pathlib.Path, stems: set[str], whole_module: bool) -> dict[str, str]:
    """Each diagnostics file the build writes for one module, and how a refusal names it when it is not there."""
    if whole_module:
        whole = f"{listed.stem}-primary.dia"
        return {whole: f"{listed.stem}'s whole-module job ({whole})"}
    module_job = f"{listed.stem}-primary-emit-module.dia"
    expected = {f"{stem}.dia": f"{listed.stem}/{stem}.swift" for stem in sorted(stems)}
    expected[module_job] = f"{listed.stem}'s module job ({module_job})"
    return expected


def read_module(library: ctypes.CDLL, directory: pathlib.Path, whole_module: bool, reading: Reading) -> None:
    """One module directory: note every diagnostics file its build should have written and did not, and read
    the ones it did."""
    reading.modules += 1
    listed = next(directory.glob("*.SwiftFileList"))
    sources = {line.strip() for line in listed.read_text().splitlines() if line.strip()}
    stems = {pathlib.Path(source).stem for source in sources}
    if not stems:
        reading.empty.append(listed.name)
    expected = expected_files(listed, stems, whole_module)
    reading.missing += [named for name, named in expected.items() if not (directory / name).is_file()]
    # The dependency scan's file is named after the list — or, in a testable copy (`App-<hash>-testable`), after
    # the module, which is the list's name up to its first hyphen: a module name holds none.
    scans = {f"{listed.stem}-dependency-scan.dia", f"{listed.stem.split('-', 1)[0]}-dependency-scan.dia"}
    for dia in sorted(directory.glob("*.dia")):
        if dia.name not in expected:
            # A source the module no longer compiles, or the dependency scan's (which fails the build itself
            # when it finds anything).
            reading.stale += dia.name not in scans
            continue
        reading.read += 1
        for warning in warnings_in(library, dia):
            if stale_elsewhere(directory, dia, warning, listed.stem.split("-", 1)[0], sources):
                reading.stale_warnings += 1
                continue
            reading.warnings.setdefault(warning.replace(f"{REPO}/", ""), None)


def stale_elsewhere(directory: pathlib.Path, holder: pathlib.Path, warning: str, module: str,
                    sources: set[str]) -> bool:
    """A warning about another source of the module, held by a `.dia` older than that source's own: written by a
    batch before that source was last compiled."""
    stem = attributed_stem(warning, module, sources)
    if stem is None or stem == holder.stem:
        return False
    own = directory / f"{stem}.dia"
    return own.is_file() and own.stat().st_mtime_ns > holder.stat().st_mtime_ns


def read_build(library: ctypes.CDLL, build: pathlib.Path, targets: list[str], whole_module: bool) -> Reading:
    reading = Reading()
    for target in targets:
        directories = modules(build, target)
        if not directories:
            reading.unbuilt.append(target)
        for directory in directories:
            read_module(library, directory, whole_module, reading)
    return reading


def refuse_incomplete(build: pathlib.Path, reading: Reading) -> None:
    """Nothing found is never a pass: a target, a module or a job the build should have written for."""
    if reading.unbuilt:
        raise Refusal(f"no module directory under {build} for {', '.join(reading.unbuilt)}: not built in this "
                      "configuration, so nothing says what the compiler made of it")
    if reading.empty:
        raise Refusal(f"{', '.join(reading.empty)} lists no source: a module whose build compiled nothing says "
                      "nothing about what the compiler made of it")
    if reading.missing:
        raise Refusal("the compiler left no diagnostics for " + ", ".join(reading.missing)
                      + " — a build writes one for each, and a job with nothing written is not a clean one")


def report(reading: Reading) -> int:
    if reading.warnings:
        count = len(reading.warnings)
        print(f"compiler-warnings: {count} warning{'s' if count != 1 else ''} the compiler wrote down and "
              "did not fail the build on. A warning is an error in this package:", file=sys.stderr)
        for warning in reading.warnings:
            print(f"  {warning}", file=sys.stderr)
        return 1
    note = f"; {reading.stale} left by a source the module no longer compiles, not read" if reading.stale else ""
    if reading.stale_warnings:
        note += (f"; {reading.stale_warnings} warning{'s' if reading.stale_warnings != 1 else ''} about another "
                 "source, held by a diagnostics file older than that source's own, not counted")
    print(f"compiler-warnings: no warning in {reading.read} file{'s' if reading.read != 1 else ''} of "
          f"{reading.modules} module{'s' if reading.modules != 1 else ''}{note}")
    return 0


def main() -> int:
    options = arguments()
    build = options.intermediates
    try:
        if not build.is_dir():
            raise Refusal(f"{build} is not a directory: nothing was built there, or the layout changed")
        library = libclang()
        targets = options.targets.split(",") if options.targets else package_targets(not options.no_test_targets)
        reading = read_build(library, build, targets, options.whole_module)
        refuse_incomplete(build, reading)
    except Refusal as refusal:
        print(f"compiler-warnings: {refusal}", file=sys.stderr)
        return 1
    return report(reading)


if __name__ == "__main__":
    sys.exit(main())
