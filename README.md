# steamlink-virtual-display

Gives a Steam Link (or any Steam Remote Play client) its own virtual display on
SteamOS Desktop Mode — and makes that virtual display the host's **only**
output while the session is live, restoring the previous layout afterwards.

## Why a solo output?

With two displays active, Steam's absolute mouse coordinates map against the
wrong screen origin, so clicks land shifted by a fixed amount no matter what
resolution you pick. With a single virtual display the mapping is 1:1 —
exactly like streaming with no extra display at all.

## Requirements

- SteamOS Desktop Mode, KDE Plasma **Wayland** session
  (`vkms` virtual displays are invisible to KScreen on X11)
- `kscreen-doctor`, `pactl`, `ss`
- the `vkms` kernel module (ships with SteamOS)
- passwordless `sudo modprobe vkms` — run `sudo modprobe vkms` once
  interactively first (set a password with `passwd` if you haven't)

## Install

```bash
cp steamlink-virtual-display.sh ~/bin/
chmod +x ~/bin/steamlink-virtual-display.sh
~/bin/steamlink-virtual-display.sh --install-service   # switch automatically
```

Or run it manually per session (see below) — no service needed.

## Usage

```bash
~/bin/steamlink-virtual-display.sh --daemon          # watch sessions, switch automatically
~/bin/steamlink-virtual-display.sh --once            # apply the correct state once, exit
~/bin/steamlink-virtual-display.sh --on [WxH]        # switch to solo virtual display now
~/bin/steamlink-virtual-display.sh --off             # restore the saved layout now
~/bin/steamlink-virtual-display.sh --status          # show session/display state
~/bin/steamlink-virtual-display.sh --teardown        # restore layout, remove virtual display
~/bin/steamlink-virtual-display.sh --match-link [WxH]  # pin client resolution (implies --on)
~/bin/steamlink-virtual-display.sh --install-service   # install user systemd service
```

Try it manually first:

```bash
~/bin/steamlink-virtual-display.sh --on 1280x720
# ... test the mouse through the Link ...
~/bin/steamlink-virtual-display.sh --off
```

## How it works

- **Session detection:** watches for the PipeWire null sink
  `steam-streaming-playback` that Steam loads while streaming
  (`DETECT_MODE=ports` falls back to the old TCP 27036 probe).
- **Client resolution:** read from Steam's `streaming_log.txt`
  (`Maximum capture: WxH` line), then `--match-link` / `LINK_RES`,
  then `VIRT_RES` (default `1280x720`).
- **The switch:** one atomic `kscreen-doctor` call enables the `vkms`
  virtual display (client resolution, scale forced to 1, made primary)
  and disables every physical output together — atomicity matters,
  otherwise KWin glitches mid-transition.
- **Restore:** your exact layout (modes, positions, scales, priorities)
  is saved before the switch and re-applied when the session ends.
  A `--off`/`--teardown` or daemon exit always restores, and it refuses
  to leave you with zero physical outputs enabled.
- KScreen's remembered configs for the virtual output are purged before
  it appears, so a stale setup (wrong mode, 2x scale) can't come back.

## Environment knobs

| variable           | default     | meaning                                    |
|--------------------|-------------|--------------------------------------------|
| `DETECT_MODE`      | `auto`      | `auto` / `pipewire` / `ports`              |
| `VIRT_RES`         | `1280x720`  | fallback virtual resolution                |
| `LINK_RES`         | _(empty)_   | client resolution override, e.g. `1920x1080` |
| `VIRT_SCALE`       | `1`         | display scale for the virtual output       |
| `VIRT_POS`         | `0,0`       | position of the virtual output             |
| `MAKE_PRIMARY`     | `1`         | make the virtual output primary (`1`/`0`)  |
| `TEARDOWN_ON_EXIT` | `1`         | restore layout when `--daemon` exits       |

## Notes

- While a session is active the Deck's built-in screen goes dark — the
  virtual display is the only output. Everything comes back when the
  session ends.
- Leave Steam's *Remote Play → Advanced Host Options → "Change desktop
  resolution to match streaming client"* on; it agrees with the virtual
  display's resolution.

## Credits

Solo-output approach inspired by
[guitaripod/remoteplay-display](https://github.com/guitaripod/remoteplay-display).

## License

MIT — see [LICENSE](LICENSE).
