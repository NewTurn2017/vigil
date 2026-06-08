# br — instant built-in display brightness toggle

`br` blacks out your Mac's built-in display (0%) and restores it to 100%
instantly. Because the Mac stays awake at 0% brightness, a bundled global-hotkey
agent lets you restore the screen without needing to see a terminal.

## Build & install

```bash
make
make install PREFIX=$HOME/.local      # no sudo; or: sudo make install (PREFIX=/usr/local)
```

Ensure your install bin is on `PATH` (for `$HOME/.local`: add
`export PATH="$HOME/.local/bin:$PATH"` to your shell profile).

## Usage

| Command     | Action                         |
|-------------|--------------------------------|
| `br`        | Toggle 0% ↔ 100%               |
| `br on`     | 100%                           |
| `br off`    | 0%                             |
| `br 80`     | Set 80% (any integer 0–100)    |
| `br status` | Print current percent          |
| `br -h`     | Help                           |

## Global hotkey

```bash
make hotkey-install PREFIX=$HOME/.local
```

Default hotkey: **Control-Option-Command-B**. Press it anywhere to black out the
screen; press again to restore — even while the screen is black.

Change the hotkey by writing one line to `~/.config/br/hotkey.conf`, e.g.:

```
ctrl+opt+cmd+b
```

Separators `+`, `-`, or space; modifiers `ctrl`, `opt`/`alt`, `cmd`, `shift`;
keys `a`–`z`, `0`–`9`, `f1`–`f20`, `space`, `escape`, `return`, `tab`. After
editing, reload: `make hotkey-install PREFIX=$HOME/.local`.

Remove the agent: `make hotkey-uninstall PREFIX=$HOME/.local`. Agent logs:
`~/Library/Logs/br-agent.log`.

## Notes / caveats

- Controls the **built-in** display only.
- macOS auto-brightness (ambient sensor) may slowly raise brightness after `br off`.
- Apple panels keep a faint glow at 0% (not pure black) — expected.
- The hotkey uses Carbon `RegisterEventHotKey`, which needs **no** Accessibility
  permission.

## Develop

```bash
make test     # non-destructive: unit tests + a brightness get/set round-trip
make clean
```
