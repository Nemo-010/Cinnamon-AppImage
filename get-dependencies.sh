#!/bin/sh

set -eu

echo "Installing package dependencies..."
echo "---------------------------------------------------------------"
pacman -Syu --noconfirm \
	base-devel \
	git \
	patchelf \
	binutils \
	cinnamon \
	cinnamon-control-center \
	cinnamon-screensaver \
	xdg-utils \
	xdg-user-dirs \
	gnome-terminal \
	xterm \
	xorg-server-xvfb \
	ttf-dejavu \
	ttf-liberation

# /etc/xdg/menus/cinnamon-applications-merged is a relative symlink to
# "applications-merged", i.e. /etc/xdg/menus/applications-merged. A minimal
# container does not have that directory, and quick-sharun's cp -Lr then fails
# on the dangling symlink and silently skips the whole menus directory, which
# makes the start menu applet die with
# "gmenu_tree_get_root_directory: assertion 'tree->loaded' failed".
mkdir -p /etc/xdg/menus/applications-merged

# quick-sharun reads ~/version to stamp the AppImage; without it the release
# tag becomes "UNKNOWN".
pacman -Q cinnamon | awk '{print $2}' | cut -d- -f1 > ~/version

echo "Installing debloated packages..."
echo "---------------------------------------------------------------"
get-debloated-pkgs --add-mesa --prefer-nano icu-mini

# quick-sharun only deploys binaries it can find, so the session entry point
# shipped in AppDir/bin has to be installed to /usr before deployment.
echo "Installing helper scripts..."
echo "---------------------------------------------------------------"
install -Dm755 AppDir/bin/start-cinnamon-session /usr/bin/start-cinnamon-session
