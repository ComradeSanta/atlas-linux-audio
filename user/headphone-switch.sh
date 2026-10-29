#!/usr/bin/env bash
# headphone-switch — route Atlas playback between the DA7219 headphone jack and
# the MAX98373 speakers, driven by the jack.
#
# Scope: ROUTING ONLY.  It sets the DA7219 card profile, the default sink and
# moves playback streams.  It never touches the speaker UCM/DSP (the ChromeOS
# Waves/DSM transplant), amp mixer values, the PipeWire clock config or any
# tone shaping, so speaker audio quality is unchanged.
#
# Behavior:
#   jack in  -> DA7219 HiFi profile, default sink = headphones, move streams.
#               A 3-pole plug is reported by the DA7219 AAD as "Line Out";
#               both that and "Headphone Jack" count as headphones here.
#   jack out -> if headphones were the default, hand playback to the speakers;
#               otherwise honour the user's explicit sink (e.g. HDMI) and only
#               rescue streams left on headphones; then DA7219 profile off.
#   login    -> pin the speakers once (unless headphones are already in), and
#               never yank a stream that an application restored deliberately.
#
# Runs as a daemon: one pass at start, then checks the jack once a second (the
# ALSA CARD jack control is readable with the DA7219 profile off, so this works
# at login before any profile is active).  `headphone-switch.sh sync` does one
# pass.
#
# Testing: HEADPHONE_SWITCH_FORCE=in|out fakes the jack state.
set -u

SPK='alsa_output.platform-avs_max98373.18.auto.HiFi__Speaker__sink'
DA7219_CARD='alsa_card.platform-avs_da7219.19.auto'
DA7219_PROFILE='HiFi'   # profile-name prefix; WirePlumber appends "(Headphones|Line Out, Mic)"
JACK_NUMID=''
LINE_NUMID=''
PRE_DEFAULT="${XDG_RUNTIME_DIR:-/tmp}/headphone-switch.pre"

log() { printf '%s\n' "headphone-switch: $*" >&2; }

jack_numid() {
    amixer -c DA7219 controls 2>/dev/null |
        grep -F "iface=CARD,name='$1'" | head -n1 |
        sed 's/^numid=//; s/,.*//'
}

resolve_jacks() {
    JACK_NUMID=$(jack_numid 'Headphone Jack')
    LINE_NUMID=$(jack_numid 'Line Out Jack')
}

jack_present() {
    case "${HEADPHONE_SWITCH_FORCE:-}" in
        in)  return 0 ;;
        out) return 1 ;;
    esac
    if [ -z "$JACK_NUMID" ] || [ -z "$LINE_NUMID" ]; then
        resolve_jacks
    fi
    local n out
    for n in "$JACK_NUMID" "$LINE_NUMID"; do
        [ -n "$n" ] || continue
        out=$(amixer -c DA7219 cget numid="$n" 2>/dev/null)
        if [ -z "$out" ]; then
            # Card re-probed; numids may have changed.
            JACK_NUMID=''
            LINE_NUMID=''
            resolve_jacks
            for n in "$JACK_NUMID" "$LINE_NUMID"; do
                [ -n "$n" ] || continue
                amixer -c DA7219 cget numid="$n" 2>/dev/null |
                    grep -q 'values=on' && return 0
            done
            return 1
        fi
        grep -q 'values=on' <<<"$out" && return 0
    done
    return 1
}

sink_index() {
    pactl -f json list sinks 2>/dev/null |
        jq -r --arg n "$1" '.[]|select(.name==$n)|.index' | head -n1
}

hp_sink() {
    pactl -f json list sinks 2>/dev/null |
        jq -r '.[] | select(.name | test("avs_da7219.*(Headphones|Line.?Out)")) | .name' |
        head -n1
}

speaker_present() {
    pactl list short sinks 2>/dev/null | grep -qF "$SPK"
}

da7219_profile() {
    pactl -f json list cards 2>/dev/null |
        jq -r --arg c "$DA7219_CARD" --arg p "$DA7219_PROFILE" '
            .[] | select(.name == $c)
            | .profiles | to_entries[]
            | select(.key | startswith($p))
            | select(.value.available == true)
            | .key' 2>/dev/null | head -n1
}

ensure_da7219_profile() {
    local want="${1:-}" cur
    if [ -z "$want" ]; then
        want=$(da7219_profile)
        [ -n "$want" ] || { log "no available DA7219 HiFi profile yet"; return 1; }
    fi
    cur=$(pactl -f json list cards 2>/dev/null |
        jq -r --arg c "$DA7219_CARD" '.[]|select(.name==$c)|.active_profile' 2>/dev/null)
    [ "$cur" = "$want" ] && return 0
    if pactl set-card-profile "$DA7219_CARD" "$want" 2>/dev/null; then
        log "DA7219 profile: ${cur:-?} -> $want"
    else
        log "warning: could not set DA7219 profile $want (was ${cur:-?})"
    fi
}

set_default() {
    local cur
    cur=$(pactl get-default-sink 2>/dev/null || true)
    [ "$cur" = "$1" ] && return 0
    pactl set-default-sink "$1" && log "default sink: ${cur:-?} -> $1"
}

move_streams_to() {
    local name="$1" idx si sidx
    idx=$(sink_index "$name")
    [ -n "$idx" ] || return 0
    while IFS=$'\t' read -r si sidx; do
        [ -n "$si" ] || continue
        [ "$sidx" = "$idx" ] && continue
        if pactl move-sink-input "$si" "$idx" >/dev/null 2>&1; then
            log "moved stream $si -> $name"
        fi
    done < <(pactl -f json list sink-inputs 2>/dev/null |
        jq -r '.[]|"\(.index)\t\(.sink)"' 2>/dev/null)
}

move_streams_from() {
    local from="$1" to="$2" fidx tidx si sidx
    fidx=$(sink_index "$from")
    tidx=$(sink_index "$to")
    [ -n "$fidx" ] && [ -n "$tidx" ] || return 0
    while IFS=$'\t' read -r si sidx; do
        [ -n "$si" ] || continue
        [ "$sidx" = "$fidx" ] || continue
        if pactl move-sink-input "$si" "$tidx" >/dev/null 2>&1; then
            log "moved stream $si: $from -> $to"
        fi
    done < <(pactl -f json list sink-inputs 2>/dev/null |
        jq -r '.[]|"\(.index)\t\(.sink)"' 2>/dev/null)
}

engage() {  # jack in
    local hp cur
    ensure_da7219_profile
    hp=$(hp_sink)
    [ -n "$hp" ] || { log "jack in but headphone sink not ready yet"; return 0; }
    # Remember what was playing before the headphones, so an explicit HDMI (or
    # other) choice is restored on unplug.  The common case is the speakers.
    cur=$(pactl get-default-sink 2>/dev/null || true)
    if [ -n "$cur" ] && [ "$cur" != "$hp" ]; then
        printf '%s\n' "$cur" >"$PRE_DEFAULT"
    fi
    set_default "$hp"
    move_streams_to "$hp"
}

disengage() {  # jack out
    local hp cur pre=''
    hp=$(hp_sink)
    cur=$(pactl get-default-sink 2>/dev/null || true)
    [ -f "$PRE_DEFAULT" ] && { pre=$(cat "$PRE_DEFAULT" 2>/dev/null); rm -f "$PRE_DEFAULT"; }
    if [ -n "$hp" ] && [ -n "$cur" ] && [ "$cur" != "$hp" ]; then
        # The user explicitly picked another sink while listening on
        # headphones; keep it and rescue any stream left on the headphones.
        move_streams_from "$hp" "$cur"
    elif [ -n "$hp" ] && [ -n "$pre" ] && [ "$pre" != "$hp" ] && [ -n "$(sink_index "$pre")" ]; then
        # Restore the pre-headphone default (e.g. HDMI).
        set_default "$pre"
        move_streams_from "$hp" "$pre"
    elif [ -n "$hp" ] && [ "$cur" = "$hp" ] && speaker_present; then
        set_default "$SPK"
        move_streams_from "$hp" "$SPK"
    fi
    ensure_da7219_profile "off"
}

sync_once() {
    if jack_present; then engage; else disengage; fi
}

daemon() {
    local last='' pin=0 now hp
    resolve_jacks
    jack_present || pin=1
    sync_once
    last=$(jack_present && echo in || echo out)
    while :; do
        sleep 1
        now=$(jack_present && echo in || echo out)
        if [ "$now" != "$last" ]; then
            sync_once
            last=$now
            [ "$now" = out ] && pin=0
        elif [ "$now" = in ]; then
            hp=$(hp_sink)
            if [ -z "$hp" ]; then
                # Profile set but the sink is still coming up (or the profile
                # change raced the jack event); retry.
                ensure_da7219_profile
                continue
            fi
            # Also covers the sink appearing a moment after the profile change.
            set_default "$hp"
            move_streams_to "$hp"
        elif [ "$pin" -eq 1 ] && speaker_present; then
            # Login pin: set the default once, do not yank app-restored streams.
            set_default "$SPK"
            pin=0
        fi
    done
}

main() {
    case "${1:-}" in
        sync) sync_once ;;
        '')   daemon ;;
        *)    echo "usage: $0 [sync]" >&2; exit 2 ;;
    esac
}

main "$@"
