#!/bin/bash
# Tools/release-tag.sh writes `v<macOS>` on HEAD with the three versions read from the tree, refuses what would make a
# wrong tag, and never pushes (AGENTS.md: every release is tagged, three version numbers, a tag pushed only with its
# branch). And `make release` without BUILD_NUMBER is refused with a sentence before anything is built (2026-11-05).
# Runs in a scratch repository with the script copied in; git is wrapped on PATH to log every call.
set -uo pipefail
cd "$(dirname "$0")/../.."
apple=$PWD
fail=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

real_git=$(command -v git)
mkdir -p "$scratch/bin"
cat >"$scratch/bin/git" <<WRAP
#!/bin/bash
printf '%s\n' "\$*" >>"$scratch/git.log"
exec "$real_git" "\$@"
WRAP
chmod +x "$scratch/bin/git"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@localhost GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@localhost
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

plist() { # file, version
    cat >"$1" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>$2</string></dict></plist>
P
}
fresh() { # repo, core, macOS, service, Windows
    local r=$1
    mkdir -p "$r/core" "$r/apps/apple/Tools" "$r/apps/apple/Resources" "$r/apps/windows"
    printf '[workspace]\nmembers = []\n\n[workspace.package]\nversion = "%s"\n' "$2" >"$r/core/Cargo.toml"
    plist "$r/apps/apple/Resources/Info.plist" "$3"
    plist "$r/apps/apple/Resources/DictionaryService-Info.plist" "$4"
    printf '<Project>\n  <PropertyGroup>\n    <Version>%s</Version>\n  </PropertyGroup>\n</Project>\n' "$5" \
        >"$r/apps/windows/Directory.Build.props"
    cp "$apple/Tools/release-tag.sh" "$r/apps/apple/Tools/"
    git -C "$r" init -q && git -C "$r" add -A && git -C "$r" commit -qm base
}
tag_run() { # repo, line...: runs the copied script with the wrapped git
    local r=$1; shift
    PATH=$scratch/bin:$PATH bash "$r/apps/apple/Tools/release-tag.sh" "$@" 2>&1
}

r=$scratch/good
fresh "$r" 0.4.1 0.6.13 0.6.13 0.2.0
out=$(tag_run "$r" "Lookup is faster"); got=$?
if [ "$got" = 0 ] && [ "$out" = v0.6.13 ]; then ok "a clean tree is tagged v<macOS>"; else bad "good run: exit $got: $out"; fi
want=$'XDict 0.6.13: Lookup is faster\n\nCore 0.4.1 · macOS 0.6.13 · Windows 0.2.0'
msg=$(git -C "$r" tag -l --format='%(contents)' v0.6.13)
if [ "$msg" = "$want" ]; then ok "the message names all three versions"; else bad "message: [$msg]"; fi
[ "$(git -C "$r" cat-file -t v0.6.13 2>/dev/null)" = tag ] && ok "the tag is annotated" || bad "the tag is not annotated"
[ "$(git -C "$r" rev-parse 'v0.6.13^{commit}')" = "$(git -C "$r" rev-parse HEAD)" ] && ok "the tag is on HEAD" \
    || bad "the tag is not on HEAD"
if grep -qE '(^| )(push|remote)( |$)' "$scratch/git.log"; then bad "git was asked to push: $(cat "$scratch/git.log")"
elif [ -s "$scratch/git.log" ]; then ok "nothing was pushed ($(wc -l <"$scratch/git.log" | tr -d ' ') git calls logged)"
else bad "the git wrapper logged nothing: the check cannot see a push"; fi

refused() { # name, repo, sentence, args...
    local name=$1 repo=$2 sentence=$3; shift 3
    local before; before=$(git -C "$repo" tag -l | sort)
    out=$(tag_run "$repo" "$@"); got=$?
    if [ "$got" != 0 ] && grep -q "$sentence" <<<"$out" && [ "$(git -C "$repo" tag -l | sort)" = "$before" ]; then
        ok "$name is refused"
    else bad "$name: exit $got, tags $(git -C "$repo" tag -l | tr '\n' ' '): $out"; fi
}
refused "an existing tag" "$r" "already exists" "Again"
r=$scratch/dirty
fresh "$r" 0.4.1 0.6.13 0.6.13 0.2.0
echo change >>"$r/core/Cargo.toml"
refused "a dirty tree" "$r" "uncommitted changes" "Dirty"
r=$scratch/disagree
fresh "$r" 0.4.1 0.6.13 0.6.12 0.2.0
refused "plists that disagree" "$r" "one version, in both plists" "Split"
r=$scratch/notnumbers
fresh "$r" 0.4 0.6.13 0.6.13 0.2.0
refused "a core version that is not three numbers" "$r" "core version is not three numbers" "Short"
r=$scratch/empty
fresh "$r" 0.4.1 0.6.13 0.6.13 0.2.0
refused "an empty line" "$r" "is empty" ""
refused "a line of two lines" "$r" "more than one line" $'one\ntwo'

# make release without a number stops at the guard, with its sentence; with one, the guard passes.
first=$(make -n release BUILD_NUMBER= BUILD_HOST= 2>/dev/null | head -1)
grep -q 'no BUILD_NUMBER' <<<"$first" && ok "make release checks the number first" \
    || bad "make release does not start with the BUILD_NUMBER guard: $first"
first=$(make -n release-bootstrap BUILD_NUMBER= BUILD_HOST= 2>/dev/null | head -1)
grep -q 'no BUILD_NUMBER' <<<"$first" && ok "make release-bootstrap checks the number first" \
    || bad "make release-bootstrap does not start with the guard: $first"
out=$(make -s release-number BUILD_NUMBER= 2>&1); got=$?
if [ "$got" != 0 ] && grep -q 'nothing was built' <<<"$out"; then ok "no BUILD_NUMBER is refused with a sentence"
else bad "no BUILD_NUMBER: exit $got: $out"; fi
make -s release-number BUILD_NUMBER=7 >/dev/null 2>&1 && ok "a BUILD_NUMBER passes the guard" \
    || bad "BUILD_NUMBER=7 was refused"
exit $fail
