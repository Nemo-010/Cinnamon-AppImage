#!/bin/sh

set -eu

ARCH=$(uname -m)
export ARCH
export OUTPATH=./dist
export OUTNAME=Cinnamon-"$ARCH".AppImage
export UPINFO="gh-releases-zsync|${GITHUB_REPOSITORY%/*}|${GITHUB_REPOSITORY#*/}|latest|*$ARCH.AppImage.zsync"
export DEPLOY_LOCALE=1
export DEPLOY_OPENGL=1
export ANYLINUX_LIB=1
export MAIN_BIN=start-cinnamon-session

# muffin links against libpipewire directly, without it libmuffin cannot load
# and the whole session dies at the first window operation
export DEPLOY_PIPEWIRE=1

# cinnamon-launcher, cinnamon-killer-daemon and several settings panels are
# Python scripts that import psutil, setproctitle, PIL and gi, so the Python
# they run on has to be the bundled one.
export DEPLOY_PYTHON=1

export APPDIR=${APPDIR:-$PWD/AppDir}

# Cinnamon keeps several helpers in private lib dirs and refers to them by
# absolute path (cinnamon-session is a shell script, nemo dlopens its
# extensions), so those paths are mapped onto the AppDir at runtime.
export PATH_MAPPING='
	/usr/lib/cinnamon-session:${SHARUN_DIR}/lib/cinnamon-session
	/usr/lib/cinnamon-settings-daemon:${SHARUN_DIR}/lib/cinnamon-settings-daemon
	/usr/lib/cinnamon:${SHARUN_DIR}/lib/cinnamon
	/usr/lib/muffin:${SHARUN_DIR}/lib/muffin
	/usr/lib/nemo:${SHARUN_DIR}/lib/nemo
	/usr/lib/evolution-data-server:${SHARUN_DIR}/lib/evolution-data-server
	/usr/lib/cinnamon-screensaver:${SHARUN_DIR}/lib/cinnamon-screensaver
	/usr/share/cinnamon:${SHARUN_DIR}/share/cinnamon
'

# get-dependencies.sh is run as its own CI step, so it is not called here

echo "Creating desktop entry..."
cat > "$APPDIR/cinnamon.desktop" <<'DESKTOP_ENTRY'
[Desktop Entry]
Name=Cinnamon
Comment=This session logs you into Cinnamon
Exec=start-cinnamon-session
TryExec=start-cinnamon-session
Icon=cinnamon
Type=Application
X-GNOME-Provides=cinnamon
DESKTOP_ENTRY

# cinnamon-session starts the session components by name, and the xlets are
# spawned from JS, so every helper has to be bundled explicitly. The GTK theme
# is mandatory: nemo crashes in gtk_css_provider_to_string() when the theme it
# was configured with cannot be found.
#
# The libibus/libkeybinder/libgsound/libaccountsservice/libnma/libgcr/libnm/
# libupower/libpolkit-agent/libgraphene entries are there because typelibs
# reference their library by name and GObject-Introspection dlopens it: ldd
# never sees these, and without them the Cinnamon JS code dies with
# "Failed to load shared library ... referenced by the typelib" followed by
# "JS ERROR: Error: Unsupported type void, deriving from fundamental void".
quick-sharun \
	/usr/bin/start-cinnamon-session \
	/usr/bin/cinnamon-session \
	/usr/bin/cinnamon-session-cinnamon \
	/usr/bin/cinnamon-session-cinnamon2d \
	/usr/bin/cinnamon-session-quit \
	/usr/bin/cinnamon \
	/usr/bin/cinnamon2d \
	/usr/bin/cinnamon-launcher \
	/usr/bin/cinnamon-killer-daemon \
	/usr/bin/cinnamon-screensaver \
	/usr/bin/cinnamon-screensaver-command \
	/usr/bin/cinnamon-screensaver-lock-dialog \
	/usr/bin/cinnamon-settings \
	/usr/bin/cinnamon-settings-users \
	/usr/bin/cinnamon-desktop-editor \
	/usr/bin/cinnamon-menu-editor \
	/usr/bin/cinnamon-file-dialog \
	/usr/bin/cinnamon-subprocess-wrapper \
	/usr/bin/csd-* \
	/usr/bin/muffin \
	/usr/bin/nemo \
	/usr/bin/nemo-desktop \
	/usr/bin/cjs \
	/usr/bin/xterm \
	/usr/bin/dbus-launch \
	/usr/bin/dbus-daemon \
	/usr/bin/dbus-run-session \
	/usr/bin/xdg-open \
	/usr/bin/xdg-user-dirs-update \
	/usr/lib/libibus-1.0.so.5 \
	/usr/lib/libkeybinder-3.0.so.0 \
	/usr/lib/libgsound.so.0 \
	/usr/lib/libaccountsservice.so.1 \
	/usr/lib/libnma.so.0 \
	/usr/lib/libgcr-4.so.4 \
	/usr/lib/libnm.so.0 \
	/usr/lib/libupower-glib.so.3 \
	/usr/lib/libpolkit-agent-1.so.0 \
	/usr/lib/libgraphene-1.0.so.0 \
	/usr/lib/cinnamon-screensaver/libcscreensaver.so \
	/usr/lib/at-spi-bus-launcher \
	/usr/lib/xapps/xapp-sn-watcher \
	/usr/lib/cinnamon-session \
	/usr/lib/cinnamon-settings-daemon \
	/usr/lib/cinnamon \
	/usr/lib/muffin \
	/usr/lib/nemo \
	/usr/lib/evolution-data-server \
	/usr/lib/cinnamon-screensaver \
	/usr/lib/cinnamon-screensaver/girepository-1.0 \
	/usr/share/themes \
	/usr/share/nemo \
	/usr/share/applications \
	/usr/share/desktop-directories \
	/usr/share/xsessions \
	/etc/xdg/autostart \
	/etc/xdg/menus

# cinnamon-session resolves RequiredComponents and autostart entries through
# these files, and upstream hardcodes absolute /usr/bin and /usr/lib paths in
# them. The AppDir is the installation prefix here, so strip the prefix.
#
# evolution-data-server is the exception: evolution-alarm-notify links
# libedbus-private.so, which lives next to it in a private dir, so its absolute
# path is kept and mapped with PATH_MAPPING instead.
echo "Rewriting desktop entry Exec/TryExec paths..."
for f in "$APPDIR"/share/applications/*.desktop \
         "$APPDIR"/share/xsessions/*.desktop \
         "$APPDIR"/etc/xdg/autostart/*.desktop; do
	[ -f "$f" ] || continue
	sed -i \
	  -e '/evolution-data-server/!s|^Exec=/usr/lib/[^/]*/|Exec=|' \
	  -e '/evolution-data-server/!s|^Exec=/usr/lib/|Exec=|'       \
	  -e 's|^Exec=/usr/bin/|Exec=|'       \
	  -e 's|^TryExec=/usr/bin/|TryExec=|' \
	  -e '/evolution-data-server/!s|^TryExec=/usr/lib/[^/]*/|TryExec=|' \
	  "$f"
done

quick-sharun --make-appimage
