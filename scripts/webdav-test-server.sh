#!/usr/bin/env bash
# Starts (or stops) a throwaway WebDAV server on this Mac for `WebDAVLiveTests`: the Apache that ships with
# macOS, with mod_dav, on 127.0.0.1:8765, user "anna" / "test-password", data in /tmp/healthaccess-webdav.
# Usage: scripts/webdav-test-server.sh start | stop | lan
# `lan` is for a test from a real iPhone in the same network: it listens on every address of this Mac, keeps the
# data in ~/HealthAccess-webdav-test (real health data must not sit in /tmp) and makes a random password.
set -euo pipefail
DIR=/tmp/healthaccess-webdav
MODE="${1:-start}"
LISTEN=127.0.0.1
PASSWORD=test-password
case "$MODE" in
  stop)
    for d in "$DIR" "$HOME/HealthAccess-webdav-test"; do
      [ -f "$d/httpd.pid" ] && kill "$(cat "$d/httpd.pid")" 2>/dev/null || true
    done
    rm -rf "$DIR"; echo "stopped (the files of a lan test stay in ~/HealthAccess-webdav-test until you delete them)"; exit 0 ;;
  lan)
    DIR="$HOME/HealthAccess-webdav-test"; LISTEN=0.0.0.0
    PASSWORD=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 12) ;;
esac
mkdir -p "$DIR/root/files"
chmod 700 "$DIR"
/usr/sbin/htpasswd -cb "$DIR/htpasswd" anna "$PASSWORD" >/dev/null 2>&1
cat > "$DIR/httpd.conf" <<CONF
ServerRoot "/usr"
ServerName localhost
Listen $LISTEN:8765
PidFile "$DIR/httpd.pid"
ErrorLog "$DIR/error.log"
LoadModule mpm_prefork_module libexec/apache2/mod_mpm_prefork.so
LoadModule unixd_module libexec/apache2/mod_unixd.so
LoadModule authn_core_module libexec/apache2/mod_authn_core.so
LoadModule authn_file_module libexec/apache2/mod_authn_file.so
LoadModule authz_core_module libexec/apache2/mod_authz_core.so
LoadModule authz_user_module libexec/apache2/mod_authz_user.so
LoadModule auth_basic_module libexec/apache2/mod_auth_basic.so
LoadModule dav_module libexec/apache2/mod_dav.so
LoadModule dav_fs_module libexec/apache2/mod_dav_fs.so
DavLockDB "$DIR/davlock"
DocumentRoot "$DIR/root"
<Directory "$DIR/root">
  Dav On
  AuthType Basic
  AuthName "healthaccess test"
  AuthUserFile "$DIR/htpasswd"
  Require valid-user
</Directory>
CONF
/usr/sbin/httpd -f "$DIR/httpd.conf" -k start
sleep 1
curl -s -o /dev/null -w "WebDAV test server: HTTP %{http_code} for anna\n" -u "anna:$PASSWORD" -X PROPFIND -H "Depth: 0" http://127.0.0.1:8765/files/
if [ "$MODE" = lan ]; then
  IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "<this Mac's address>")
  echo "In the app: Settings > Cloud copy > WebDAV server"
  echo "  Address:  http://$IP:8765/files"
  echo "  Name:     anna"
  echo "  Password: $PASSWORD"
  echo "Files arrive in $DIR/root/files/Health Access. Stop with: scripts/webdav-test-server.sh stop"
fi
