# Sourced, not run: **one XDict run against a host at a time** — builds, gates, E2E, the gallery, the lab and the UI tour.
# XDict builds and tests on one Mac (owner, 2026-10-17), so a gate and an E2E run share it as much as two E2E runs do.
#
#   . Tools/host-lock.sh; host_lock <host> <who>     waits for the lock, saying who holds it; fails after the wait
#
# The lock is a shlock pid file on this Mac (macOS has no flock(1)), named by the host: every XDict run is started here.
# A lock whose holder died is taken over by shlock. The holder exports XDICT_HOST_LOCK_HELD, so a run it starts (a gate
# that builds the lab, an E2E run that builds) does not wait for itself. XDICT_HOST_LOCK_WAIT: seconds to wait (3600).
host_lock_file() { printf '%s/xdict-e2e-%s.lock' "${TMPDIR:-/tmp}" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')"; }

host_lock() {
    _hl_host=$1 _hl_who=$2
    _hl_file=$(host_lock_file "$_hl_host")
    case " ${XDICT_HOST_LOCK_HELD:-} " in *" $_hl_file "*) return 0 ;; esac
    _hl_waited=0 _hl_said=""
    until /usr/bin/shlock -f "$_hl_file" -p $$; do
        _hl_pid=$(cat "$_hl_file" 2>/dev/null)
        _hl_holder="pid $_hl_pid: $(ps -o command= -p "$_hl_pid" 2>/dev/null | cut -c1-120)"
        if [ "$_hl_waited" -ge "${XDICT_HOST_LOCK_WAIT:-3600}" ]; then
            echo "$_hl_who: $_hl_host is held by another XDict run ($_hl_holder; lock: $_hl_file)" >&2
            return 3
        fi
        [ "$_hl_said" = "$_hl_holder" ] || echo "$_hl_who: waiting for $_hl_host, held by $_hl_holder" >&2
        _hl_said=$_hl_holder
        sleep 5
        _hl_waited=$((_hl_waited + 5))
    done
    XDICT_HOST_LOCK_HELD="${XDICT_HOST_LOCK_HELD:-} $_hl_file"
    export XDICT_HOST_LOCK_HELD
}

# host_unlock <host>: removes the lock this process took (for an EXIT trap).
host_unlock() {
    _hl_file=$(host_lock_file "$1")
    [ "$(cat "$_hl_file" 2>/dev/null)" != $$ ] || rm -f "$_hl_file"
}
