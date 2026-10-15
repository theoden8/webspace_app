#!/usr/bin/env bash
# Runs a command inside the headless desktop session the Linux CI job gives the
# app: an X display, a Wayland compositor, a session bus with a Secret Service
# that never prompts, and the XDG directories path_provider asks for. Exits
# with the command's status.
#
#   scripts/linux_test_session.sh <command> [args...]
#
# Needs the packages and pass-secret-service install from the Linux job in
# .github/workflows/build-and-test.yml.

set -x

# path_provider_linux's getApplicationDocumentsDirectory() calls
# `xdg-user-dir DOCUMENTS`, which reads $XDG_CONFIG_HOME/user-dirs.dirs and
# falls back to $HOME/Documents. The sid container ships with neither, and the
# lookup then throws MissingPlatformDirectoryException at boot.
mkdir -p "$HOME/Documents" "$HOME/.cache" "$HOME/.local/share" "$HOME/.config"
cat > "$HOME/.config/user-dirs.dirs" <<'EOF'
XDG_DESKTOP_DIR="$HOME/Desktop"
XDG_DOWNLOAD_DIR="$HOME/Downloads"
XDG_DOCUMENTS_DIR="$HOME/Documents"
XDG_PICTURES_DIR="$HOME/Pictures"
XDG_VIDEOS_DIR="$HOME/Videos"
XDG_MUSIC_DIR="$HOME/Music"
EOF
mkdir -p "$HOME/Desktop" "$HOME/Downloads" "$HOME/Pictures" \
         "$HOME/Videos" "$HOME/Music"
# Printed so the log shows the resolved path, or the empty failure.
xdg-user-dir DOCUMENTS

# The gpg key and pass store pass-secret-service keeps secrets in. Loopback
# pinentry and a passphrase-less key keep gpg-agent off any prompt, so a
# libsecret write never blocks. Reused when a key already exists.
mkdir -p "$HOME/.gnupg" && chmod 700 "$HOME/.gnupg"
printf '%s\n' "allow-loopback-pinentry" > "$HOME/.gnupg/gpg-agent.conf"
printf '%s\n' "pinentry-mode loopback" > "$HOME/.gnupg/gpg.conf"
if ! gpg --list-secret-keys --with-colons | grep -q '^sec'; then
  cat > /tmp/gpgkey <<'EOF'
%no-protection
Key-Type: rsa
Key-Length: 2048
Name-Real: CI
Name-Email: ci@local
Expire-Date: 0
%commit
EOF
  gpg --batch --gen-key /tmp/gpgkey
fi
GPGID=$(gpg --list-keys --with-colons | awk -F: '/^pub/{print $5; exit}')
[ -d "$HOME/.password-store" ] || pass init "$GPGID"

# Software GL, and a Wayland socket for WPE's libWPEBackend-fdo, whose only
# buffer path binds to a Wayland display (without one a WebView mount hangs at
# EGL surface creation). weston's headless backend needs no GPU.
#
# WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS: WPE wraps its subprocesses in
# bwrap, which needs CAP_SYS_ADMIN and user namespaces, both blocked in an
# Actions container job. Safe for a single-tenant runner loading test pages,
# never for a user.
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
mkdir -p /tmp/runtime-root && chmod 0700 /tmp/runtime-root
export XDG_RUNTIME_DIR=/tmp/runtime-root
export WAYLAND_DISPLAY=wayland-test
weston --backend=headless --width=1280 --height=720 \
  --socket="$WAYLAND_DISPLAY" --no-config > /tmp/weston.log 2>&1 &
WESTON_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] && break
  sleep 1
done

# pass_secret_service claims org.freedesktop.secrets on the session bus before
# the app's first libsecret call, which would otherwise dbus-activate a
# gnome-keyring that prompts and hangs. It creates the default collection on
# first OpenSession; the unlock goes through gpg-agent's loopback path.
status=0
xvfb-run -a --server-args="-screen 0 1280x720x24 +extension GLX +render -nolisten tcp" \
  dbus-run-session -- bash -c '
    pass_secret_service > /tmp/pss.log 2>&1 &
    PSS_PID=$!
    sleep 2
    python3 -c "
import secretstorage
conn = secretstorage.dbus_init()
coll = secretstorage.get_default_collection(conn)
if coll.is_locked():
    coll.unlock()
print(f\"keyring: locked={coll.is_locked()} label={coll.get_label()}\")
"
    rc=0
    "$@" || rc=$?
    kill "$PSS_PID" 2>/dev/null
    exit $rc
  ' bash "$@" || status=$?
kill "$WESTON_PID" 2>/dev/null || true
exit $status
