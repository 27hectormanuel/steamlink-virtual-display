#!/usr/bin/env bash
#
# steamlink-virtual-display.sh v2.0.0
#
# Gives a Steam Link (or any Steam Remote Play client) its own virtual display
# on SteamOS Desktop Mode — and makes that virtual display the host's ONLY
# output while the session is live, restoring the previous layout afterwards.
#
# Why solo-output: with two displays active, Steam's absolute mouse coordinates
# map against the wrong screen origin and clicks land shifted by a fixed amount
# ("same everywhere"). With a single virtual display the mapping is 1:1,
# exactly like streaming with no script at all. (This mirrors the approach of
# the remoteplay-display project.)
#
# Session detection: the PipeWire null sink "steam-streaming-playback" that
# Steam loads while streaming (re-queryable live state), with the old
# TCP 27036 port probe as fallback.
#
# Client resolution: Steam's streaming_log.txt "Maximum capture: WxH" line
# (written milliseconds before the session starts), then --match-link /
# LINK_RES, then VIRT_RES.
#
# Usage:
#   steamlink-virtual-display.sh --daemon          # watch sessions, switch automatically
#   steamlink-virtual-display.sh --once           # apply the correct state once, exit
#   steamlink-virtual-display.sh --on [WxH]       # switch to solo virtual display now
#   steamlink-virtual-display.sh --off            # restore the saved layout now
#   steamlink-virtual-display.sh --status         # show session/display state
#   steamlink-virtual-display.sh --teardown       # restore layout, remove virtual display
#   steamlink-virtual-display.sh --match-link [WxH]  # pin client resolution (implies --on)
#   steamlink-virtual-display.sh --install-service   # install user systemd service
#
# Env knobs:
#   DETECT_MODE=auto|pipewire|ports   session detection method (default auto)
#   VIRT_RES=1280x720                 fallback virtual resolution
#   LINK_RES=                         client resolution override, e.g. 1920x1080
#   VIRT_SCALE=1                      display scale for the virtual output
#                                     (forced: KScreen-saved 2x breaks mapping)
#   VIRT_POS=0,0                      position of the virtual output
#   MAKE_PRIMARY=1                     make the virtual output primary (1/0)
#   TEARDOWN_ON_EXIT=1                 restore layout when --daemon exits (1/0)
#
set -euo pipefail

VERSION="2.0.0"

# --- configuration ---------------------------------------------------------
DETECT_MODE="${DETECT_MODE:-auto}"   # auto | pipewire | ports
VIRT_RES="${VIRT_RES:-1280x720}"
LINK_RES="${LINK_RES:-}"
VIRT_SCALE="${VIRT_SCALE:-1}"
VIRT_POS="${VIRT_POS:-0,0}"
MAKE_PRIMARY="${MAKE_PRIMARY:-1}"
TEARDOWN_ON_EXIT="${TEARDOWN_ON_EXIT:-1}"

STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/steamlink-virtual-display"
ACTIVE_FLAG="$STATE_DIR/active"
LAYOUT_FILE="$STATE_DIR/layout"

TCP_PORT=27036
PIPEWIRE_SINK="steam-streaming-playback"
STREAMING_LOGS=(
    "$HOME/.steam/steam/logs/streaming_log.txt"
    "$HOME/.local/share/Steam/logs/streaming_log.txt"
)

# --- helpers ---------------------------------------------------------------
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

mkdir -p "$STATE_DIR"

usage() {
    sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

# --- session detection -----------------------------------------------------
pipewire_session() {
    if ! command -v pactl >/dev/null 2>&1; then return 1; fi
    if pactl list sinks short 2>/dev/null | grep -q -- "$PIPEWIRE_SINK"; then
        return 0
    fi
    return 1
}

ports_session() {
    if ! command -v ss >/dev/null 2>&1; then return 1; fi
    if ss -Htn state established "( sport = :${TCP_PORT} or dport = :${TCP_PORT} )" 2>/dev/null | grep -q .; then
        return 0
    fi
    return 1
}

session_active() {
    case "$DETECT_MODE" in
        pipewire) pipewire_session ;;
        ports)    ports_session ;;
        *)        if pipewire_session; then return 0; fi
                  ports_session ;;
    esac
}

# --- client resolution -----------------------------------------------------
# Explicit arg > streaming log "Maximum capture:" > LINK_RES > VIRT_RES.
client_res() {
    local explicit="${1:-}"
    if [[ -n "$explicit" ]]; then echo "$explicit"; return 0; fi
    local logf res
    for logf in "${STREAMING_LOGS[@]}"; do
        if [[ ! -f "$logf" ]]; then continue; fi
        res=$(grep -oE "Maximum capture: [0-9]+x[0-9]+" "$logf" 2>/dev/null | tail -1 | sed 's/.*: //' || true)
        if [[ -n "$res" ]]; then echo "$res"; return 0; fi
    done
    if [[ -n "$LINK_RES" ]]; then echo "$LINK_RES"; return 0; fi
    echo "$VIRT_RES"
}

# --- vkms ------------------------------------------------------------------
virt_sysfs_present() {
    if ls /sys/class/drm/ 2>/dev/null | grep -q -- '-Virtual-'; then
        return 0
    fi
    return 1
}

ensure_vkms() {
    if virt_sysfs_present; then return 0; fi
    log "Loading vkms kernel module…"
    if ! sudo -n modprobe vkms 2>/dev/null; then
        log "ERROR: passwordless 'sudo modprobe vkms' failed."
        log "Run once interactively:  sudo modprobe vkms   (set a password with 'passwd' first)"
        return 1
    fi
    sleep 1
    if ! virt_sysfs_present; then
        log "ERROR: vkms loaded but no -Virtual- connector in /sys/class/drm."
        return 1
    fi
    return 0
}

# Remove KScreen's remembered configs for virtual outputs BEFORE the hotplug,
# so KWin can't re-apply a stale setup (wrong mode / 2x scale / primary).
purge_kscreen_virtual_config() {
    local dir="$HOME/.local/share/kscreen"
    if [[ ! -d "$dir" ]]; then return 0; fi
    grep -l -- "Virtual-" "$dir"/* 2>/dev/null | xargs -r rm -f || true
    return 0
}

# --- kscreen helpers -------------------------------------------------------
# Current layout, one line per output:
#   name|enabled(0/1)|mode(WxH@R)|pos(x,y)|scale|priority
kscreen_layout() {
    kscreen-doctor -o 2>/dev/null | awk '
        /^Output: [0-9]+ / {
            if (name != "") print name "|" en "|" mode "|" pos "|" scale "|" prio;
            name=$3; en=0; mode=""; pos="0,0"; scale="1"; prio="99";
            next;
        }
        /^[ \t]+enabled$/  { en=1; next; }
        /^[ \t]+disabled$/ { en=0; next; }
        /Geometry:/        { pos=$2; next; }
        /^[ \t]+Scale:/    { scale=$2; next; }
        /^[ \t]+priority/  { prio=$2; next; }
        /Modes:/ {
            for (i=1;i<=NF;i++)
                if ($i ~ /^[0-9]+:[0-9]+x[0-9]+@[0-9.]+[*]$/) {
                    m=$i; sub(/^[0-9]+:/,"",m); sub(/[*]$/,"",m); mode=m;
                }
            next;
        }
        END { if (name != "") print name "|" en "|" mode "|" pos "|" scale "|" prio; }
    '
}

# First Virtual-* output name known to kscreen (empty if none).
virt_output_name() {
    kscreen_layout | awk -F'|' '$1 ~ /Virtual-/ { print $1; exit }'
}

# Wait for KWin/KScreen to notice the hot-plugged output (self-diagnosing).
wait_kscreen_for_virtual() {
    local waited=0 virt=""
    while (( waited < 12 )); do
        virt=$(virt_output_name) || true
        if [[ -n "${virt:-}" ]]; then return 0; fi
        sleep 2; waited=$((waited + 2))
    done
    log "ERROR: no Virtual-* output visible to kscreen after ${waited}s."
    log "--- diagnostics (paste everything below back to me) ---"
    if command -v kscreen-doctor >/dev/null 2>&1; then
        log "kscreen-doctor: present"
    else
        log "kscreen-doctor: MISSING"
    fi
    log "session type: ${XDG_SESSION_TYPE:-unset}"
    log "drm devices: $(ls /sys/class/drm/ 2>/dev/null | tr '\n' ' ')"
    local st
    for st in /sys/class/drm/card*-Virtual-*/status; do
        if [[ -e "$st" ]]; then
            log "$(basename "$(dirname "$st")") status: $(cat "$st" 2>/dev/null)"
        fi
    done
    if command -v kscreen-doctor >/dev/null 2>&1; then
        log "kscreen-doctor -o:"
        kscreen-doctor -o 2>&1 | head -40 >&2 || true
    fi
    return 1
}

save_layout() {
    if ! kscreen_layout > "$LAYOUT_FILE"; then return 1; fi
    if [[ ! -s "$LAYOUT_FILE" ]]; then return 1; fi
    log "Saved current layout ($(wc -l < "$LAYOUT_FILE" | tr -d ' ') outputs)."
    return 0
}

# Restore the saved layout + disable the virtual output, all atomically.
restore_layout() {
    if [[ ! -f "$LAYOUT_FILE" ]]; then
        log "No saved layout; nothing to restore."
        return 1
    fi
    local present name en mode pos scale prio
    present=$(kscreen_layout | cut -d'|' -f1)
    local args=()
    while IFS='|' read -r name en mode pos scale prio; do
        if [[ -z "$name" ]]; then continue; fi
        if ! grep -qx -- "$name" <<<"$present"; then
            log "Output $name no longer present; skipping."
            continue
        fi
        if [[ "$en" == "1" ]]; then
            args+=("output.${name}.enable")
            if [[ -n "$mode" ]]; then args+=("output.${name}.mode.${mode}"); fi
            args+=("output.${name}.position.${pos}"
                   "output.${name}.scale.${scale}"
                   "output.${name}.priority.${prio}")
        else
            args+=("output.${name}.disable")
        fi
    done < "$LAYOUT_FILE"
    local virt; virt=$(virt_output_name) || true
    if [[ -n "${virt:-}" ]]; then args+=("output.${virt}.disable"); fi
    if (( ${#args[@]} == 0 )); then
        log "Nothing to restore."
        return 1
    fi
    if ! kscreen-doctor "${args[@]}" >/dev/null 2>&1; then
        log "Full restore rejected; retrying without pinned modes…"
        args=()
        while IFS='|' read -r name en mode pos scale prio; do
            if [[ -z "$name" ]]; then continue; fi
            if ! grep -qx -- "$name" <<<"$present"; then continue; fi
            if [[ "$en" == "1" ]]; then
                args+=("output.${name}.enable"
                       "output.${name}.position.${pos}"
                       "output.${name}.scale.${scale}"
                       "output.${name}.priority.${prio}")
            else
                args+=("output.${name}.disable")
            fi
        done < "$LAYOUT_FILE"
        if [[ -n "${virt:-}" ]]; then args+=("output.${virt}.disable"); fi
        if ! kscreen-doctor "${args[@]}" >/dev/null 2>&1; then return 1; fi
    fi
    return 0
}

# Last-resort: enable the first physical output, disable virtual, atomically.
force_physical_layout() {
    local name virt args
    name=$(kscreen_layout | awk -F'|' '$1 !~ /Virtual-/ { print $1; exit }')
    if [[ -z "$name" ]]; then return 1; fi
    virt=$(virt_output_name) || true
    args=("output.${name}.enable")
    if [[ -n "${virt:-}" ]]; then args+=("output.${virt}.disable"); fi
    if kscreen-doctor "${args[@]}" >/dev/null 2>&1; then return 0; fi
    return 1
}

# True when: virtual enabled at WxH, and no other output enabled.
verify_solo() {
    local virt="$1" res="$2" tries=0
    while (( tries < 12 )); do
        if kscreen-doctor -o 2>/dev/null | awk -v v="$virt" -v r="$res" '
            /^Output: [0-9]+ / {
                if (name != "") {
                    if (name == v) { if (en && geo == r) ok_v=1; }
                    else if (en) { other=1; }
                }
                name=$3; en=0; geo="";
                next;
            }
            /^[ \t]+enabled$/ { en=1; next; }
            /Geometry:/        { geo=$3; next; }
            END {
                if (name != "") {
                    if (name == v) { if (en && geo == r) ok_v=1; }
                    else if (en) { other=1; }
                }
                exit !(ok_v && !other);
            }'; then
            return 0
        fi
        sleep 1; tries=$((tries + 1))
    done
    return 1
}

# --- solo mode -------------------------------------------------------------
# Enable the virtual display as the ONLY output (one atomic kscreen call).
activate_solo() {
    local res="${1:-$VIRT_RES}"
    if [[ -f "$ACTIVE_FLAG" ]]; then
        log "Solo mode already active."
        return 0
    fi
    if ! command -v kscreen-doctor >/dev/null 2>&1; then
        die "kscreen-doctor not found; cannot manage displays."
    fi
    if [[ "${XDG_SESSION_TYPE:-}" == "x11" ]]; then
        die "X11 session: vkms virtual displays are invisible to KScreen/XRandR here. Use a Plasma (Wayland) session."
    fi
    purge_kscreen_virtual_config
    if ! ensure_vkms; then return 1; fi
    if ! wait_kscreen_for_virtual; then return 1; fi
    if ! save_layout; then
        log "WARNING: layout not saved; --off may not restore fully."
    fi
    local virt; virt=$(virt_output_name) || true
    if [[ -z "${virt:-}" ]]; then
        log "ERROR: virtual output vanished."
        return 1
    fi

    local mode="${res}@60" name en m2 pos scale prio
    local args=("output.${virt}.enable" "output.${virt}.mode.${mode}"
                "output.${virt}.scale.${VIRT_SCALE}" "output.${virt}.position.${VIRT_POS}")
    if [[ "$MAKE_PRIMARY" == "1" ]]; then args+=("output.${virt}.priority.1"); fi
    while IFS='|' read -r name en m2 pos scale prio; do
        if [[ -z "$name" || "$name" == "$virt" ]]; then continue; fi
        args+=("output.${name}.disable")
    done < <(kscreen_layout)

    if ! kscreen-doctor "${args[@]}" >/dev/null 2>&1; then
        log "Mode ${mode} rejected; retrying with default mode…"
        args=("output.${virt}.enable"
              "output.${virt}.scale.${VIRT_SCALE}" "output.${virt}.position.${VIRT_POS}")
        if [[ "$MAKE_PRIMARY" == "1" ]]; then args+=("output.${virt}.priority.1"); fi
        while IFS='|' read -r name en m2 pos scale prio; do
            if [[ -z "$name" || "$name" == "$virt" ]]; then continue; fi
            args+=("output.${name}.disable")
        done < <(kscreen_layout)
        if ! kscreen-doctor "${args[@]}" >/dev/null 2>&1; then
            log "ERROR: kscreen-doctor failed to apply solo layout."
            return 1
        fi
    fi
    if ! verify_solo "$virt" "$res"; then
        log "Layout not as expected; retrying once…"
        kscreen-doctor "${args[@]}" >/dev/null 2>&1 || true
        if ! verify_solo "$virt" "$res"; then
            log "ERROR: could not establish solo virtual display."
            return 1
        fi
    fi
    touch "$ACTIVE_FLAG"
    log "Solo virtual display '${virt}' active at ${res}; physical outputs disabled, layout saved."
    return 0
}

deactivate() {
    if [[ ! -f "$ACTIVE_FLAG" ]]; then
        log "Solo mode not active; nothing to restore."
        local virt; virt=$(virt_output_name) || true
        if [[ -n "${virt:-}" ]] && kscreen_layout \
                | awk -F'|' -v v="$virt" '$1==v && $2==1 { f=1 } END { exit !f }'; then
            log "Virtual output '${virt}' enabled without active flag; disabling it."
            kscreen-doctor "output.${virt}.disable" >/dev/null 2>&1 || true
        fi
        return 0
    fi
    if restore_layout; then
        log "Previous display layout restored."
    else
        log "WARNING: restore failed; forcing a physical output back on."
        if ! force_physical_layout; then
            log "ERROR: could not restore any layout. Try: kscreen-doctor output.eDP-1.enable"
        fi
    fi
    # Safety: never leave zero physical outputs enabled.
    if ! kscreen_layout | awk -F'|' '$1 !~ /Virtual-/ && $2==1 { f=1 } END { exit !f }'; then
        log "WARNING: no physical output enabled after restore; forcing one on."
        force_physical_layout || true
    fi
    rm -f "$ACTIVE_FLAG" "$LAYOUT_FILE"
    return 0
}

# --- commands --------------------------------------------------------------
cmd_on() {
    local res; res=$(client_res "$EXPLICIT_RES")
    log "Switching to solo virtual display at ${res}."
    activate_solo "$res"
}

cmd_off() {
    log "Restoring saved layout."
    deactivate
}

cmd_once() {
    local res; res=$(client_res "$EXPLICIT_RES")
    if session_active; then
        log "Session active; client resolution ${res}."
        activate_solo "$res"
    else
        log "No session; ensuring normal layout."
        deactivate
    fi
}

cmd_daemon() {
    local active=0 res
    trap 'log "Shutting down."; if [[ "$TEARDOWN_ON_EXIT" == "1" ]]; then deactivate; fi; exit 0' \
        EXIT INT TERM
    log "Watching for Steam Link sessions (mode: $DETECT_MODE)…"
    while true; do
        if session_active; then
            if (( active == 0 )); then
                res=$(client_res "$EXPLICIT_RES")
                log "Session detected; client resolution ${res}."
                if activate_solo "$res"; then
                    active=1
                else
                    log "Activation failed; will retry."
                fi
            fi
        else
            if (( active == 1 )); then
                log "Session ended."
                deactivate
                active=0
            fi
        fi
        sleep 2
    done
}

cmd_status() {
    echo "steamlink-virtual-display.sh v$VERSION"
    echo "detection: $DETECT_MODE"
    if session_active; then echo "session: ACTIVE"; else echo "session: idle"; fi
    if [[ -f "$ACTIVE_FLAG" ]]; then echo "solo: ACTIVE (layout saved)";
    else echo "solo: inactive"; fi
    echo "--- outputs ---"
    local name en mode pos scale prio st
    kscreen_layout | while IFS='|' read -r name en mode pos scale prio; do
        if [[ "$en" == "1" ]]; then st="enabled"; else st="disabled"; fi
        printf '%-10s %-8s mode=%-14s pos=%-9s scale=%s prio=%s\n' \
            "$name" "$st" "${mode:-?}" "$pos" "$scale" "$prio"
    done
    return 0
}

cmd_teardown() {
    deactivate
    if virt_sysfs_present; then
        if sudo -n modprobe -r vkms 2>/dev/null; then
            log "vkms module unloaded — virtual display fully removed."
        else
            log "NOTE: vkms still loaded; run 'sudo modprobe -r vkms' to fully remove it."
        fi
    else
        log "vkms not loaded."
    fi
    return 0
}

cmd_install_service() {
    local unit="$HOME/.config/systemd/user/steamlink-virtual-display.service"
    mkdir -p "$(dirname "$unit")"
    cat > "$unit" <<EOF
[Unit]
Description=Steam Link virtual display (solo output)
After=graphical-session.target

[Service]
Type=simple
ExecStart=%h/bin/steamlink-virtual-display.sh --daemon
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable --now steamlink-virtual-display.service
    log "Service installed and started: $unit"
}

# --- dispatch --------------------------------------------------------------
MODE=""
EXPLICIT_RES=""
while (( $# )); do
    case "$1" in
        --daemon)          MODE=daemon ;;
        --once)            MODE=once ;;
        --on)              MODE=on ;;
        --off)             MODE=off ;;
        --status)          MODE=status ;;
        --teardown)        MODE=teardown ;;
        --install-service) MODE=install-service ;;
        --match-link=*)    EXPLICIT_RES="${1#*=}" ;;
        --match-link)
            if [[ -z "${2:-}" ]]; then die "--match-link needs WxH (e.g. --match-link 1280x720)"; fi
            EXPLICIT_RES="$2"
            shift ;;
        -h|--help)         usage ;;
        *)
            if [[ "$1" =~ ^[0-9]+x[0-9]+$ ]]; then
                EXPLICIT_RES="$1"   # bare WxH positional arg
            else
                die "unknown argument: $1"
            fi ;;
    esac
    case "$1" in
        --match-link|--match-link=*)
            if [[ ! "$EXPLICIT_RES" =~ ^[0-9]+x[0-9]+$ ]]; then
                die "bad resolution: $EXPLICIT_RES"
            fi
            ;;
    esac
    shift
done
# Bare --match-link WxH means --on WxH.
if [[ -z "$MODE" && -n "$EXPLICIT_RES" ]]; then MODE=on; fi
if [[ -z "$MODE" ]]; then usage; fi

case "$MODE" in
    daemon)          cmd_daemon ;;
    once)            cmd_once ;;
    on)              cmd_on ;;
    off)             cmd_off ;;
    status)          cmd_status ;;
    teardown)        cmd_teardown ;;
    install-service) cmd_install_service ;;
esac
