# Cinnamon Desktop AppImage

An [Anylinux AppImage](https://github.com/pkgforge-dev/Anylinux-AppImages) of the
[Cinnamon Desktop Environment](https://github.com/linuxmint/cinnamon), built with
[quick-sharun](https://github.com/pkgforge-dev/Anylinux-AppImages/blob/main/useful-tools/quick-sharun.sh).

![Cinnamon running from the AppImage](screenshot.png)

**Status: works, with one caveat.** It starts a full Cinnamon X11 session:
Muffin composites, the panel loads with all 16 applets including the start
menu, and the whole `csd-*` settings-daemon set runs. The desktop-icons
component (`nemo-desktop`) does not start yet; see the note below.

It has only ever been tested in a headless sandbox with no user account, where
`nemo-desktop` segfaults because `getpwuid()` returns NULL. That is very likely
a sandbox artifact (a `getpwuid` stub makes it run fine), but it has not been
confirmed on a real desktop. Read [RESEARCH.md](RESEARCH.md) before relying on
this.

## Download

Grab `Cinnamon-x86_64.AppImage` (or `aarch64`) from the
[latest release](https://github.com/Nemo-010/Cinnamon-AppImage/releases/latest).

## Why this is not a normal AppImage

Cinnamon's dependency closure is 510 packages (~2.3 GiB installed), and unlike an
application it is not a single process:

- the session manager (`cinnamon-session`) resolves its components by reading
  `.desktop` files from `$XDG_DATA_DIRS/applications`, so those have to be
  bundled and their absolute `Exec=` paths rewritten;
- GObject-Introspection dlopens the library each typelib names, which `ldd`
  never sees, so ~10 libraries (`libibus`, `libkeybinder`, `libgsound`, …)
  have to be listed by hand;
- several components live in private lib dirs and are referenced by absolute
  path (`/usr/lib/cinnamon-session/...`, `/usr/lib/muffin/...`,
  `/usr/lib/cinnamon/...`, `/usr/share/cinnamon/...`), which needs both
  directory deployment and `PATH_MAPPING`;
- `cinnamon-session` itself is a shell script that execs a binary by absolute
  path, so it needs an override in `AppDir/bin`;
- the desktop icons (`nemo-desktop`) are a separate GApplication on the session
  bus;
- the start menu reads `/etc/xdg/menus` through `XDG_CONFIG_DIRS`, which
  defaults to the host's, so a hook has to prepend the AppDir.

The AppImage is ~200 MiB and 1136 shared objects.

## Building

Deploying on any system other than Arch Linux is a very bad idea. Cinnamon must
be installed to `/usr` before it is deployed, which is what
`get-dependencies.sh` does.

```sh
./get-dependencies.sh
./make-appimage.sh
```

The result is `dist/Cinnamon-x86_64.AppImage`.

## Requirements

**This does not run on a bare command-line install.** It is a *session*, not an
operating system: it replaces `/usr` but not the host's system services. You
need:

| Requirement | Why |
|---|---|
| An **X server** (Xorg, Xvfb, Xephyr, or an existing X session) | Cinnamon is X11-only here; nothing boots one for you |
| A **running system bus** (`dbus.service`) | `cinnamon-session` calls `g_bus_get_sync(G_BUS_TYPE_SYSTEM)` and `g_error()`s — a hard `abort()` — if it fails |
| A **passwd entry** for your user | `nemo-desktop` and several `csd-*` helpers call `getpwuid()` |
| **FUSE**, or ~550 MB free in `$TMPDIR` | Without `/dev/fuse` the runtime falls back to extracting the whole 532 MB AppDir |
| A `/bin/sh` | `AppRun.sh` and the hooks are shell scripts |

You do **not** need Cinnamon, GTK, GLib or any desktop libraries installed —
the bundle carries its own glibc 2.44, GTK3, all 1136 libraries, the GI
typelibs and Mesa. Verified: running `cinnamon` under the bundled loader
resolves every library from inside the AppDir.

### Default Arch / Alpine

Both work as *hosts*, but neither works out of the box as a plain CLI install,
and for different reasons:

* **Arch, default CLI install.** `dbus` is in `core` but is not pulled in by
  `base`, and there is no X server. So you need at least
  `pacman -S xorg-server xorg-xinit dbus` and a startx/display-manager setup.
  With those, this is the intended use case: launch it from `~/.xinitrc` or as
  an X session.
* **Alpine.** musl is not a problem — the bundle ships glibc and its own loader,
  and `sharun` is statically linked, so the only host dependency is a POSIX
  shell (busybox `ash` is fine). But Alpine has no systemd and no logind, so
  the system bus normally exists only if you install `dbus` and run
  `rc-service dbus start`. Also note `sharun`'s hook scripts call host `grep`,
  `ln` and `mkdir`; busybox provides all three.
* **No systemd/logind is survivable**, just degraded: `csm-systemd.c` and
  `csm-consolekit.c` differ here — the systemd path only `g_warning()`s, the
  ConsoleKit path `g_error()`s. Without either, power/suspend inhibition and
  session tracking do not work, but the shell still runs.

### Running

```sh
./Cinnamon-x86_64.AppImage
```

From a display manager, an X session, or with an X server you started yourself:

```sh
Xvfb :1 -screen 0 1920x1080x24 &
DISPLAY=:1 dbus-run-session -- ./Cinnamon-x86_64.AppImage
```

`start-cinnamon-session` creates a private *session* bus when
`DBUS_SESSION_BUS_ADDRESS` is unset, so `dbus-run-session` is optional. The
*system* bus is not optional.

On a host without FUSE, point `TMPDIR` at real disk first, or the extraction
will fail with `dwarfs: short write: -20 != N` (`ENOTDIR`, because a 489 MB
`/tmp` tmpfs filled up): `TMPDIR=$HOME/.cache ./Cinnamon-x86_64.AppImage`.

## Credits

- Cinnamon, Muffin, Nemo, CJS: GPL-2.0-or-later, Linux Mint.
- [quick-sharun](https://github.com/pkgforge-dev/Anylinux-AppImages) and
  [sharun](https://github.com/VHSgunzo/sharun), from pkgforge-dev and VHSgunzo.
