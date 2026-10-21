# Packaging Cinnamon as an Anylinux AppImage — research notes

Research done in a fakechroot Arch bootstrap (no root, no userns). A working
build tree is at `/workspace/Cinnamon-AppImage`, a built artifact at
`/workspace/nativetest/Cinnamon-x86_64.AppImage` (200 MiB).

## 1. What is being packaged

| Component | Arch package | Version |
|---|---|---|
| `cinnamon` (shell, `cjs`, panel applets, settings) | `cinnamon` | 6.6.9 |
| window manager / compositor | `muffin` | 6.6.3 |
| session manager | `cinnamon-session` | 6.6.4 |
| settings daemon (`csd-*`) | `cinnamon-settings-daemon` | 6.6.4 |
| file manager + desktop icons | `nemo` | 6.6.4 |
| JS engine | `cjs` | 128.1 |

Dependency closure of `cinnamon` is **510 packages, ~2.3 GiB installed**
(190 from `core`, 320 from `extra`). That is the single most important fact
about this packaging job: it is a full GTK3 + GLib + GObject-Introspection +
Python + Evolution-Data-Server stack, not an application.

The result after `quick-sharun`: **200 MiB AppImage**, 1136 shared objects,
82 MiB of `share/` (JS applets, themes, 153 typelibs, locale, icons).

## 2. Which quick-sharun settings are needed

```sh
export DEPLOY_PIPEWIRE=1   # libmuffin has a hard DT_NEEDED on libpipewire-0.3
export DEPLOY_PYTHON=1     # cinnamon-launcher/killer-daemon/settings are Python
export DEPLOY_LOCALE=1
export DEPLOY_OPENGL=1
export ANYLINUX_LIB=1
```

`DEPLOY_GTK`/`DEPLOY_GDK` get switched on automatically from `libgtk-3` and
`libgdk_pixbuf`. `DEPLOY_PIPEWIRE` is *not* automatic here: quick-sharun's
autodetection walks `NEEDED` entries of the binaries given on the command
line, and `libmuffin` is only reached transitively, so `no-pipewire-kek.so.0`
gets substituted into `libmuffin.so.0` and the compositor fails to load with
`no-pipewire-kek.so.0: cannot open shared object file`. This is the first
hard failure a naive build hits.

## 3. Things a normal application does not need

### 3.1 Private library directories

Cinnamon keeps binaries in private dirs that are *not* on the default search
path and are referenced by absolute path:

```
/usr/lib/cinnamon-session/cinnamon-session-binary
/usr/lib/cinnamon-settings-daemon/csd-*
/usr/lib/cinnamon/libcinnamon.so, libst.so, *.typelib
/usr/lib/muffin/libmuffin*.so, *.typelib
/usr/lib/nemo/nemo-extensions-list
/usr/share/cinnamon/js, applets, theme, ...
```

These must be passed to quick-sharun as *directories* (it deploys them and
relocates binaries) **and** mapped, because the referring code uses hardcoded
paths:

```sh
export PATH_MAPPING='
	/usr/lib/cinnamon-session:${SHARUN_DIR}/lib/cinnamon-session
	/usr/lib/cinnamon-settings-daemon:${SHARUN_DIR}/lib/cinnamon-settings-daemon
	/usr/lib/cinnamon:${SHARUN_DIR}/lib/cinnamon
	/usr/lib/muffin:${SHARUN_DIR}/lib/muffin
	/usr/lib/nemo:${SHARUN_DIR}/lib/nemo
	/usr/share/cinnamon:${SHARUN_DIR}/share/cinnamon
'
```

### 3.2 Shell-script launchers need an override

`/usr/bin/cinnamon-session` is a `/bin/sh` script whose last line is
`exec /usr/lib/cinnamon-session/cinnamon-session-binary "$@"`. `path-mapping.so`
only intercepts ELF execs, so this fails with
`exec: /usr/lib/cinnamon-session/cinnamon-session-binary: not found`.
Fix: ship your own `AppDir/bin/cinnamon-session` that does
`exec cinnamon-session-binary "$@"` (PATH lookup). quick-sharun will not
overwrite a file you already put in `AppDir/bin`.

The same applies to the AppImage entry point: `start-cinnamon-session`
creates `XDG_RUNTIME_DIR`, sets `XDG_CURRENT_DESKTOP=X-Cinnamon` and
`XDG_SESSION_TYPE=x11`, and starts a private session bus only when
`DBUS_SESSION_BUS_ADDRESS` is unset.

### 3.3 Session components are resolved through .desktop files

`cinnamon-session` does not exec names directly. It reads
`share/cinnamon-session/sessions/cinnamon.session`:

```
RequiredComponents=cinnamon;org.cinnamon.ScreenSaver;nemo-autostart;cinnamon-killer-daemon;
```

and then looks up each component as a `.desktop` file in
`$XDG_DATA_DIRS/applications`. If `share/applications` is not deployed:

```
WARNING: Unable to find required component 'cinnamon'
CRITICAL: Unable to start session: Failed to load session "cinnamon"
```

So `/usr/share/applications`, `/usr/share/xsessions` and `/etc/xdg/autostart`
must all be deployed. And since upstream writes absolute paths in them
(`Exec=/usr/bin/cinnamon-launcher`, `Exec=/usr/lib/xapps/xapp-sn-watcher`,
`Exec=/usr/lib/at-spi-bus-launcher --launch-immediately`), the AppDir is the
installation prefix and the paths must be stripped:

```sh
sed -i -e 's|^Exec=/usr/lib/[^/]*/|Exec=|' \
       -e 's|^Exec=/usr/bin/|Exec=|' \
       -e 's|^TryExec=/usr/bin/|TryExec=|' ...
```

Without that, cinnamon-session reports
`Could not parse desktop file cinnamon.desktop or it references a not found
TryExec binary` and refuses to start the session.

### 3.4 GI-dlopened libraries are invisible to ldd

Typelibs reference their library by name and GObject-Introspection dlopens it,
so `ldd` never reports it. Every namespace the Cinnamon JS code touches has to
be listed on the quick-sharun command line explicitly:

```
imports.gi.{St,Clutter,Gio,GLib,Cinnamon,Meta,GObject,Gtk,Pango,Atk,Gdk,
            CinnamonDesktop,XApp,Graphene,NMClient,CMenu,AccountsService,
            UPowerGlib,NM,Cogl,CDesktopEnums,PolkitAgent,Polkit,NMA,IBus,
            GioUnix,GdkPixbuf,Gcr,Cvc}
```

Without `libibus-1.0.so.5`, `libkeybinder-3.0.so.0` and friends the shell dies
at startup with

```
Failed to load shared library 'libibus-1.0.so.5' referenced by the typelib
JS ERROR: Error: Unsupported type void, deriving from fundamental void
Execution of main.js threw exception: Script <main> threw an exception
```

`libcscreensaver.so` is the same story, from
`/usr/lib/cinnamon-screensaver/girepository-1.0`.

### 3.5 The start menu needs XDG_CONFIG_DIRS

The menu definition is `/etc/xdg/menus/cinnamon-applications.menu`, found via
`XDG_CONFIG_DIRS`, whose default is `/etc/xdg` — the *host's*. Bundling
`etc/xdg/menus` is not enough; it has to be added to the search path by a hook:

```sh
XDG_CONFIG_DIRS=$APPDIR/etc/xdg:${XDG_CONFIG_DIRS:-/etc/xdg}
```

Without it the applet dies with
`gmenu_tree_get_root_directory: assertion 'tree->loaded' failed` and
`[menu@cinnamon.org]: root is null`.

There is also a build-time trap: `/etc/xdg/menus/cinnamon-applications-merged`
is a *relative* symlink to `applications-merged`, i.e.
`/etc/xdg/menus/applications-merged`. A minimal container does not have that
directory, `cp -Lr` fails on the dangling symlink, and quick-sharun silently
skips the **whole** menus directory (`Failed to add /etc/xdg/menus to
AppDir/etc/xdg/menus/menus`). `get-dependencies.sh` creates it.

### 3.6 Desktop icons are a separate GApplication

`nemo-desktop` is its own process, started by `nemo-autostart.desktop`. It
registers `org.nemo.desktop` on the session bus. Two consequences:

* If any other instance is already registered on the bus, the new process
  gets `desktop_already_managed()` / single-instance hand-off and exits 0
  immediately. During testing this looks exactly like a crash and cost me a
  long detour: `nemo-desktop` "exiting after 2 s with rc=0" was a stale
  instance on the same bus, not a bundle problem. Verify with a fresh bus.
* `nemo-desktop` needs `org.nemo.desktop` GSettings schemas, which are in the
  bundle, so `GSETTINGS_SCHEMA_DIR` must include `$APPDIR/share/glib-2.0/schemas`
  (sharun sets this) — otherwise `Settings schema 'org.nemo.preferences' is
  not installed` and `GLib-GIO-ERROR` aborts.

## 4. State of the build

Verified working (extracted AppDir and AppImage, native, no fakechroot):

* Cinnamon 6.6.9 starts, Muffin compositor runs, the panel with **all 16
  applets** including `menu@cinnamon.org` loads, the clock renders.
* `cinnamon-launcher`, `cinnamon-killer-daemon` and the **whole `csd-*` set**
  (a11y-settings, automount, background, clipboard, color, housekeeping,
  keyboard, media-keys, power, print-notifications, printer,
  screensaver-proxy, settings-remap, wacom, xsettings) stay up.
* 42 X windows on the display, `cinnamon` process alive.
* Screenshot of a live session: panel + clock at the bottom of the screen.
* `nemo`, `nemo --version` (6.6.4), `cjs`, `cinnamon-settings` all run.

Not working yet:

1. **`nemo-autostart.desktop` "respawning too quickly"**, so
   `cinnamon-session` logs `Unable to start session` and the desktop icons
   never appear. The session still stays up and the panel works.

   Root cause identified with a `SIGSEGV` backtrace (preloaded handler, see
   below): `nemo-desktop` aborts inside
   `gnome_desktop_thumbnail_cache_check_permissions()` in
   `libcinnamon-desktop.so.4`, called from `nemo_application_startup()`:

   ```
   *** signal 11 at 0x14 ***
   ./lib/libc.so.6(+0x3e6f0)
   ./lib/libcinnamon-desktop.so.4(gnome_desktop_thumbnail_cache_check_permissions+0x3f)
   ./shared/bin/nemo-desktop(+0x2b45b)
   ./lib/libgobject-2.0.so.0(g_signal_emit_valist+0x39)
   ./lib/libgio-2.0.so.0(g_application_register+0x583)
   ./lib/libgio-2.0.so.0(g_application_run+0x129)
   ```

   That function dereferences the `getpwuid()` result, which is `NULL` here
   because the sandbox has **no `/etc/passwd` at all** — `csd-*` logs the
   matching `getpwuid_r(): failed due to unknown user id (966)` warnings.

   Verified by supplying a `getpwuid`/`getpwuid_r` stub through
   `LD_PRELOAD`: with it, `nemo-desktop` survives the full 12 s timeout
   instead of segfaulting, logs
   `Desktop failsafe timeout reached, applying fallback behavior`, and never
   crashes. **So this is a sandbox artifact, not a packaging bug**, and a
   normal host with a real user account will not hit it. It still cannot be
   called verified end-to-end here, because `sharun` strips `LD_PRELOAD`
   from the children `cinnamon-session` spawns, so the stub cannot be
   inherited into the autostarted instance.
2. `Could not load a pixbuf from icon theme` in `nemo-desktop`: the Arch
   `gdk-pixbuf2` 2.44.8 package used here ships **no** loader modules at all
   (`pacman -Ql gdk-pixbuf2` lists none, `/usr/lib/gdk-pixbuf-2.0` does not
   exist, `gdk-pixbuf-query-loaders` emits nothing), so this is a property of
   the container image, not of the bundle. On a normal Arch install the
   loaders and `loaders.cache` are present and quick-sharun deploys them.

Both of these need one run on a real desktop before the AppImage is called
usable. Everything else below is verified.

### Getting a backtrace inside an AppImage

`ptrace` is unavailable (`/proc/sys/kernel/yama/ptrace_scope=1`, no
`CAP_SYS_PTRACE`), so `gdb`/`strace` cannot attach. What worked: a tiny
`LD_PRELOAD` library with a `SIGSEGV` handler that calls
`backtrace_symbols_fd()`, loaded with `SHARUN_ALLOW_LD_PRELOAD=1` or by
running the bundled loader directly:

```sh
LD_PRELOAD=/path/libbt.so \
GSETTINGS_SCHEMA_DIR=$APPDIR/share/glib-2.0/schemas \
XDG_DATA_DIRS=$APPDIR/share:/usr/share \
$APPDIR/lib/ld-linux-x86-64.so.2 --library-path $APPDIR/lib \
  $APPDIR/shared/bin/nemo-desktop
```

## 5. Sandbox notes (fakechroot)

Building this needed three shims that are *not* needed on a real Arch system,
but which silently produced a broken bundle and are worth recording:

* `ldd` — the real `ldd` cannot `--verify` an absolute path under
  fakechroot and prints `not a dynamic executable` for every binary. Result:
  quick-sharun deployed almost no libraries and the AppImage was 128 MiB of
  mostly-empty tree. Shim: rewrite absolute args to `./`-relative and `cd /`.
* `readlink -f` — `realpath()` inside libc is not intercepted by fakechroot,
  so `readlink -f /usr/lib/libnemo-extension.so.1` returns the *host* path
  `/workspace/boot/root/root.x86_64/usr/lib/...`. quick-sharun's
  `_lib4bin_get_lib_dst_dir` then creates
  `AppDir/lib/workspace/boot/root/root.x86_64/usr/lib/...`, i.e. libraries
  that are bundled but unreachable. Shim: `sed -e "s|^$FAKECHROOT_BASE||"`.
* `fakeroot` — needs `FAKEROOTDONTTRYCHOWN=1`, and `pacman` needs a passwd
  entry for the build UID or `dbus-daemon` refuses to start
  (`Could not get password database information for UID`).

## 6. Recommendation

Packaging a full desktop environment this way is feasible but it is a
different class of problem from packaging an application:

* the dependency closure is 510 packages / 2.3 GiB, and the AppImage is
  ~200 MiB before any debloating;
* four separate mechanisms (private lib dirs, shell-script launchers,
  `.desktop`-resolved session components, per-component GApplications) each
  need their own fix, and none of them are quick-sharun bugs;
* the AppImage can only ever be an *X11 session you launch from a display
  manager*, it cannot provide login, polkit, logind, udev, or the system bus,
  so a large part of what makes Cinnamon work on a real system is still the
  host's;
* for a "lightweight dependency-free desktop in an AppImage" goal (the Lumina
  case) Cinnamon is the wrong target: Lumina is Qt5-only, has no
  GObject-Introspection, no Python components and no session manager to
  satisfy.

If this is pursued, the sensible scope is a *demo/portable session* AppImage
(what is built here) rather than a daily-driver desktop, and the remaining
work is: fix the nemo-desktop session hand-off on a machine with a real user
account, deploy `evolution-data-server`'s private dirs, and decide whether to
debloat (the `archlinux-pkgs-debater` mesa/icu/nano packages plus
`DEBLOAT_LOCALE=1` are the obvious wins).
