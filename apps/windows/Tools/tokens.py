#!/usr/bin/env python3
"""XDict's Windows design tokens: generate them, check the generated files, and find literals that should be tokens.

    python -I Tools/tokens.py gen                 write XDict.App/Tokens.g.cs and XDict.App/Tokens.xaml
    python -I Tools/tokens.py gen --check         fail when either generated file is stale
    python -I Tools/tokens.py check               fail on a literal a token should have replaced
    python -I Tools/tokens.py check --report      print the debt and every finding; exit 0
    python -I Tools/tokens.py check --write-baseline   record the current debt (a deliberate, reviewed act)

**The source** is `Tokens/tokens.toml`: every token carries `system` (Fluent's own value: a text style, a 4-pixel
step or a theme brush) or `why` (XDict's own choice, in a sentence); the generator refuses one without. The generated
files are byte-for-byte from the source and its SHA-256; never edit them.

**What `check` finds** (XAML under XDict.App, C# under XDict.App; the generated files and build output are skipped):
  XAML: a numeric length or size in a layout, size, type, colour or motion position — Width, Height, Min/MaxWidth,
  Min/MaxHeight, FontSize, Padding, Margin, Spacing, Row/ColumnSpacing, CornerRadius, StrokeThickness,
  BorderThickness, Opacity, Duration — and a literal colour (`#hex` or a named colour) or FontFamily.
  C#: a numeric argument of Thickness, CornerRadius or GridLength; a numeric Width/Height/Min/Max/FontSize/Opacity;
  `Interval = TimeSpan.FromMilliseconds(...)`; `Colors.<name>` or `Color.FromArgb(...)`; `new FontFamily("...")`.
  ALLOWED: 0 (none), 1 as an Opacity (unchanged), any `{ThemeResource}`/`{StaticResource}` value, `Auto` and `*`,
  a `*` star length, `Transparent`, and a line tagged `// token-exempt: <reason>` (the tag is counted; a tag without
  a reason is a finding). The generated files and Tokens.xaml are not scanned.

**The debt**: every existing finding is recorded in `Tokens/literal-debt.tsv` as `path<TAB>count`. A file whose
count rises, or a new file with a finding, fails; the debt is bounded, never silently inherited. `--write-baseline`
rewrites it and must be a reviewed commit.
"""
import argparse
import hashlib
import os
import re
import sys
import tomllib

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.normpath(os.path.join(HERE, ".."))
TOML = os.path.join(APP, "Tokens", "tokens.toml")
BASELINE = os.path.join(APP, "Tokens", "literal-debt.tsv")
CS_OUT = os.path.join(APP, "XDict.App", "Tokens.g.cs")
XAML_OUT = os.path.join(APP, "XDict.App", "Tokens.xaml")
SCAN_ROOTS = [os.path.join(APP, "XDict.App")]
SKIP_NAMES = {"Tokens.g.cs", "Tokens.xaml"}
SKIP_PARTS = {"obj", "bin", "target", ".git"}

NUMERIC_XAML = {
    "Width", "Height", "MinWidth", "MinHeight", "MaxWidth", "MaxHeight", "FontSize", "Padding", "Margin",
    "Spacing", "RowSpacing", "ColumnSpacing", "CornerRadius", "StrokeThickness", "BorderThickness", "Opacity",
    "Duration", "IconSize", "ItemHeight", "TranslateX", "TranslateY",
}
COLOUR_XAML = {"Foreground", "Background", "BorderBrush", "Fill", "Stroke", "Color"}
NAMED_COLOURS = {
    "Red", "Green", "Blue", "White", "Black", "Gray", "Grey", "Yellow", "Orange", "Purple", "Pink", "Brown",
    "Cyan", "Magenta",
}
ATTRIBUTE = re.compile(r'([A-Za-z_][\w:.]*)\s*=\s*"([^"]*)"')
XDOUBLE = re.compile(r'<\s*(?:x:)?Double\b[^>]*>([^<]+)<')
NUMBER = re.compile(r'[-+]?\d+(?:\.\d+)?')
# An assignment to a token-owned property anywhere it occurs, not only after a dot: an object initializer
# (`new Button { Width = 42 }`) escaped the gate when the dot was required. \b keeps `SomeWidth` out.
CS_ASSIGN = re.compile(r'\b(Width|Height|MinWidth|MaxWidth|MinHeight|MaxHeight|FontSize|Opacity)\s*=\s*(\d+(?:\.\d+)?)')
CS_THICKNESS = re.compile(r'new\s+(Thickness|CornerRadius|GridLength)\s*\(([^)]*)\)')
CS_INTERVAL = re.compile(r'Interval\s*=\s*TimeSpan\.FromMilliseconds\s*\(\s*(\d+(?:\.\d+)?)\s*\)')
CS_COLOUR = re.compile(r'\b(?:Colors\.[A-Za-z]+|Color\.FromArgb\s*\()')
CS_FONT = re.compile(r'new\s+FontFamily\s*\(\s*"[^"]*"')
# The marker is matched on its own so a bare `// token-exempt:` is diagnosed as the missing reason it is, rather than
# silently ignored by a pattern that requires one.
EXEMPT = re.compile(r'//\s*token-exempt:?(.*)$')
# One numeric literal: the whole argument, not a digit inside an identifier (`Tokens.Space.Size2`).
CS_LITERAL = re.compile(r'[-+]?\d+(?:\.\d+)?')


class Refused(Exception):
    pass


def load():
    with open(TOML, "rb") as handle:
        raw = handle.read()
    data = tomllib.loads(raw.decode("utf-8"))
    groups = data.get("groups")
    if not isinstance(groups, dict):
        raise Refused("tokens.toml has no [groups]")
    seen = set()
    tokens = []
    for group, spec in groups.items():
        if not isinstance(spec, dict) or "kind" not in spec or "cs" not in spec or "xaml" not in spec:
            raise Refused(f"group {group} needs kind, cs and xaml")
        kind = spec["kind"]
        if kind not in {"length", "number", "colour"}:
            raise Refused(f"group {group}: unknown kind {kind}")
        values = data.get(group, {})
        if not isinstance(values, dict):
            raise Refused(f"{group} must be a table")
        for name, fields in values.items():
            if name == "groups":
                continue
            if not isinstance(fields, dict):
                raise Refused(f"{group}.{name} must be a table")
            if "system" not in fields and "why" not in fields:
                raise Refused(f"{group}.{name}: needs system or why")
            if kind == "colour":
                if "system" not in fields:
                    raise Refused(f"{group}.{name}: a colour needs system (a Fluent theme-resource key)")
            elif "value" not in fields:
                raise Refused(f"{group}.{name}: needs value")
            key = (group, name)
            if key in seen:
                raise Refused(f"{group}.{name} is declared twice")
            seen.add(key)
            tokens.append((group, name, kind, fields, spec["cs"], spec["xaml"]))
    return raw, groups, tokens


def pascal(name):
    return name[:1].upper() + name[1:]


def generate(raw, groups, tokens):
    digest = hashlib.sha256(raw).hexdigest()
    cs = ["// Generated from Tokens/tokens.toml by Tools/tokens.py; do not edit.", f"// source sha256: {digest}",
          "namespace XDict.App;", "", "internal static class Tokens", "{"]
    for group, spec in groups.items():
        cs.append(f"    internal static class {spec['cs']}")
        cs.append("    {")
        for g, name, kind, fields, _, _ in tokens:
            if g != group:
                continue
            member = pascal(name)
            if kind == "colour":
                cs.append(f'        internal const string {member} = "{fields["system"]}";')
            elif group == "motion":
                cs.append(f"        internal const int {member} = {int(fields['value'])};")
            else:
                value = fields["value"]
                rendered = str(int(value)) if isinstance(value, int) else repr(float(value))
                cs.append(f"        internal const double {member} = {rendered};")
        cs.append("    }")
        cs.append("")
    cs.append("}")
    xaml = ["<?xml version=\"1.0\" encoding=\"utf-8\"?>",
            f"<!-- Generated from Tokens/tokens.toml by Tools/tokens.py; source sha256: {digest} -->",
            "<ResourceDictionary",
            "    xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\"",
            "    xmlns:x=\"http://schemas.microsoft.com/winfx/2006/xaml\">"]
    for group, spec in groups.items():
        for g, name, kind, fields, _, prefix in tokens:
            if g != group:
                continue
            key = prefix + pascal(name)
            if kind == "colour":
                xaml.append(f'    <x:String x:Key="{key}">{fields["system"]}</x:String>')
            else:
                value = fields["value"]
                rendered = str(int(value)) if isinstance(value, int) else repr(float(value))
                xaml.append(f'    <x:Double x:Key="{key}">{rendered}</x:Double>')
                # A padding or a radius is a Thickness/CornerRadius, not a Double: the XAML resource must carry the
                # type the control assigns, or the page parses and the window fails at load.
                if group == "space":
                    xaml.append(f'    <Thickness x:Key="{key}Thickness">{rendered}</Thickness>')
                if group == "radius":
                    xaml.append(f'    <CornerRadius x:Key="{key}Corner">{rendered}</CornerRadius>')
    xaml.append("</ResourceDictionary>")
    return ("\n".join(cs) + "\n").encode("utf-8"), ("\n".join(xaml) + "\n").encode("utf-8")


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as handle:
        handle.write(data)


def gen(check):
    raw, groups, tokens = load()
    cs, xaml = generate(raw, groups, tokens)
    stale = []
    for path, data in ((CS_OUT, cs), (XAML_OUT, xaml)):
        try:
            with open(path, "rb") as handle:
                current = handle.read()
        except FileNotFoundError:
            current = None
        if current != data:
            stale.append(path)
    if check:
        if stale:
            for path in stale:
                print(f"stale: {os.path.relpath(path, APP)} (run python -I Tools/tokens.py gen)")
            return 1
        print("tokens: fresh")
        return 0
    for path, data in ((CS_OUT, cs), (XAML_OUT, xaml)):
        write(path, data)
        print(f"wrote {os.path.relpath(path, APP)}")
    return 0


def scan_xaml(path):
    findings = []
    with open(path, encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            for attribute, value in ATTRIBUTE.findall(line):
                value = value.strip()
                if value.startswith("{") or value in {"", "Auto", "*", "Transparent"}:
                    continue
                if attribute in NUMERIC_XAML:
                    if "*" in value:
                        continue
                    for item in NUMBER.findall(value):
                        amount = float(item)
                        if amount == 0:
                            continue
                        if attribute == "Opacity" and amount == 1:
                            continue
                        findings.append((number, line.strip(), f"{attribute}={value}"))
                        break
                elif attribute in COLOUR_XAML:
                    if value.startswith("#") or value.split()[0].split(".")[0] in NAMED_COLOURS:
                        findings.append((number, line.strip(), f"{attribute}={value}"))
                elif attribute == "FontFamily":
                    findings.append((number, line.strip(), f"{attribute}={value}"))
            for item in XDOUBLE.findall(line):
                if NUMBER.search(item) and float(NUMBER.search(item).group()) != 0:
                    findings.append((number, line.strip(), "x:Double literal"))
    return findings


def scan_cs(path):
    findings = []
    with open(path, encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            code = line.split("//", 1)[0]
            exempt = EXEMPT.search(line)
            if exempt and not exempt.group(1).strip():
                findings.append((number, line.strip(), "token-exempt without a reason"))
                continue
            if exempt:
                continue
            for match in CS_ASSIGN.finditer(code):
                attribute, value = match.group(1), float(match.group(2))
                if value == 0 or (attribute == "Opacity" and value == 1):
                    continue
                # A declaration of a token's own field (`public const int Width = 1200`) is where the literal belongs;
                # an assignment to one is a use. The keyword before the identifier is what tells them apart.
                if re.search(r'\b(?:const|readonly|static)\b[^=;{})]*$', code[:match.start()]):
                    continue
                findings.append((number, line.strip(), match.group(0)))
            for match in CS_THICKNESS.finditer(code):
                text = match.group(2)
                if "Star" in text or "Auto" in text:
                    continue
                # Only an argument that is a literal is a literal: a token expression (`Tokens.Space.Size2`) or a
                # named argument is not.
                values = []
                for item in text.split(","):
                    item = re.sub(r'^[A-Za-z_]\w*\s*:\s*', '', item.strip())
                    literal = CS_LITERAL.fullmatch(item)
                    if literal:
                        values.append(float(literal.group(0)))
                if any(value != 0 for value in values):
                    findings.append((number, line.strip(), match.group(0)))
            if CS_INTERVAL.search(code):
                findings.append((number, line.strip(), CS_INTERVAL.search(code).group(0)))
            if CS_COLOUR.search(code):
                findings.append((number, line.strip(), CS_COLOUR.search(code).group(0)))
            if CS_FONT.search(code):
                findings.append((number, line.strip(), CS_FONT.search(code).group(0)))
    return findings


def scan():
    found = {}
    scanned = 0
    for root in SCAN_ROOTS:
        # A missing root must be a refusal, never an empty scan that matches an old baseline and passes: the gate
        # would then be a check that cannot fail.
        if not os.path.isdir(root):
            raise Refused(f"the scan root {os.path.relpath(root, APP)} does not exist")
        for directory, folders, files in os.walk(root):
            folders[:] = [name for name in folders if name not in SKIP_PARTS]
            for name in sorted(files):
                if name in SKIP_NAMES or name.endswith(".g.cs"):
                    continue
                path = os.path.join(directory, name)
                if name.endswith(".xaml"):
                    scanned += 1
                    result = scan_xaml(path)
                elif name.endswith(".cs"):
                    scanned += 1
                    result = scan_cs(path)
                else:
                    continue
                if result:
                    found[os.path.relpath(path, APP).replace(os.sep, "/")] = result
    if scanned == 0:
        raise Refused("the scan found no .cs or .xaml files under " + ", ".join(SCAN_ROOTS))
    return found


def read_baseline():
    counts = {}
    try:
        with open(BASELINE, encoding="utf-8") as handle:
            for line in handle:
                line = line.rstrip("\n")
                if not line or line.startswith("#"):
                    continue
                path, count = line.split("\t")
                counts[path] = int(count)
    except FileNotFoundError:
        return None
    return counts


def check(report, write_baseline_flag):
    found = scan()
    counts = {path: len(items) for path, items in found.items()}
    if write_baseline_flag:
        with open(BASELINE, "w", encoding="utf-8", newline="\n") as handle:
            handle.write("# The literals the Windows shell carried before the token catalogue; a rise fails the check.\n")
            for path in sorted(counts):
                handle.write(f"{path}\t{counts[path]}\n")
        print(f"tokens: baseline written ({sum(counts.values())} findings in {len(counts)} files)")
        return 0
    baseline = read_baseline()
    if baseline is None:
        print("tokens: no Tokens/literal-debt.tsv; run check --write-baseline once, reviewed")
        return 1
    if report:
        for path in sorted(counts):
            print(f"{path}\t{counts[path]} (allowed {baseline.get(path, 0)})")
            for number, line, why in found[path]:
                print(f"    {number}: {why} | {line[:160]}")
        return 0
    failed = False
    for path in sorted(counts):
        allowed = baseline.get(path, 0)
        if counts[path] <= allowed:
            continue
        failed = True
        print(f"{path}: {counts[path]} findings, {allowed} allowed")
        for number, line, why in found[path][allowed:]:
            print(f"    {number}: {why} | {line[:160]}")
    if failed:
        print("tokens: a literal needs a token, or the debt file is stale")
        return 1
    print(f"tokens: pass ({sum(counts.values())} baselined findings in {len(counts)} files)")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", help="run against another copy of apps/windows")
    sub = parser.add_subparsers(dest="command", required=True)
    gen_parser = sub.add_parser("gen")
    gen_parser.add_argument("--check", action="store_true")
    check_parser = sub.add_parser("check")
    check_parser.add_argument("--report", action="store_true")
    check_parser.add_argument("--write-baseline", action="store_true")
    args = parser.parse_args()
    if args.root:
        global APP, TOML, BASELINE, CS_OUT, XAML_OUT, SCAN_ROOTS
        APP = os.path.abspath(args.root)
        TOML = os.path.join(APP, "Tokens", "tokens.toml")
        BASELINE = os.path.join(APP, "Tokens", "literal-debt.tsv")
        CS_OUT = os.path.join(APP, "XDict.App", "Tokens.g.cs")
        XAML_OUT = os.path.join(APP, "XDict.App", "Tokens.xaml")
        SCAN_ROOTS = [os.path.join(APP, "XDict.App")]
    try:
        if args.command == "gen":
            return gen(args.check)
        return check(args.report, args.write_baseline)
    except Refused as error:
        print(f"tokens: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
