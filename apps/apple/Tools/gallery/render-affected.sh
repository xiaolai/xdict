#!/bin/bash
# **`make render-affected`: exactly the pictures `make render-pending` names, and nothing else** (owner, 2026-10-18:
# renders run only as permitted, otherwise go without). From an agent's shell it needs XDICT_RENDER_REQUESTED=1, which
# only the orchestrator sets once the owner has said yes for the batch (Tools/render-requested.sh); nothing calls this
# on its own, `make land` included.
#
#   Tools/gallery/render-affected.sh [--base REF | --range A..B | --paths P...] [--full]
#
# Entries go to Tools/gallery/hot.sh, one call per group of views (XDICT_LAB_MODES); routes to Tools/ui-tour/run.sh
# --only. Refuses when the lab installed on the E2E Mac is not of this tree's lab inputs (its render-lab-id): the
# pictures would be of another lab; Tools/gallery/lab.sh installs this one.
set -u
. "$(dirname "$0")/../render-requested.sh"
apple=$(cd "$(dirname "$0")/../.." && pwd)
tool="$apple/Tools/gallery/render_affected.py"
plan=$(/usr/bin/python3 -I "$tool" plan "$@") || exit 1
[ -n "$plan" ] || { echo "render-affected: nothing pending"; exit 0; }

if grep -q '^views' <<<"$plan"; then
    # The main checkout, where local.mk lives (Tools/main-checkout.sh).
    main=$("$apple/Tools/main-checkout.sh" "$apple") || exit 2
    host=${E2E_HOST:-$(awk -F'=' '{ n = $1; gsub(/[ \t]/, "", n) } n == "E2E_HOST_MACOS" { sub(/^[^=]*=[ \t]*/, ""); print; exit }' "$main/local.mk" 2>/dev/null)}
    [ -n "$host" ] || { echo "render-affected: no E2E_HOST and no E2E_HOST_MACOS in local.mk" >&2; exit 2; }
    want=$(/usr/bin/python3 -I "$tool" lab-id) || exit 1
    have=$(ssh "$host" 'cat XDictE2E/gallery-run-lab/render-lab-id 2>/dev/null')
    [ "$have" = "$want" ] || {
        echo "render-affected: the lab on $host is ${have:-unstamped}, this tree's is $want: install it with Tools/gallery/lab.sh" >&2
        exit 2
    }
fi

status=0
group="" entries=()
flush() {
    [ ${#entries[@]} -eq 0 ] && return 0
    XDICT_LAB_MODES=$group "$apple/Tools/gallery/hot.sh" "${entries[@]}" || status=1
    entries=()
}
while IFS=$'\t' read -r what views entry; do
    case $what in
        views) [ "$views" = "$group" ] || { flush; group=$views; }; entries+=("$entry") ;;
        routes) flush; if "$apple/Tools/ui-tour/run.sh" --only "$views"; then /usr/bin/python3 -I "$tool" record-routes "$views" || status=1; else status=1; fi ;;
    esac
done <<<"$plan"
flush
exit $status
