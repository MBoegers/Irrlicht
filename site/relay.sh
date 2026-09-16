#!/bin/sh
# Irrlicht relay installer — https://irrlicht.io
#
# Usage:
#   curl -fsSL https://irrlicht.io/relay.sh | sudo sh -s -- --domain relay.example.com
#   curl -fsSL https://irrlicht.io/relay.sh | sudo sh -s -- --tailscale
#   curl -fsSL https://irrlicht.io/relay.sh | sudo sh
#   curl -fsSL https://irrlicht.io/relay.sh | sudo sh -s -- --uninstall
#
# Installs `irrlichtrelay` — the standalone hub that lets a phone or a second
# machine watch a daemon's sessions, and the server that Irrlicht Elfdans
# (phone notifications) pushes from — on a Linux host with systemd (#1964).
# It replaces the hand-run steps of examples/relay/DEPLOY.md: match the
# architecture, download and verify the release tarball, extract it with
# bin/ and Resources/web/ kept together, create the service user, install and
# enable the unit, issue the first bearer token as the service user, and,
# under --domain, put Caddy in front for TLS.
#
# It never edits a firewall, never touches DNS, and never requests a
# certificate itself (Caddy does that). It prints the firewall command for
# this distribution instead of running it — DEPLOY.md records why: on Oracle
# Cloud an appended iptables rule silently does nothing, `ufw` can leave the
# instance unbootable, and flushing the ruleset kills the iSCSI boot volume.

set -eu

REPO="ingo-eichhorst/Irrlicht"
RELAY_NAME="irrlichtrelay"
RELAY_USER="irrlichtrelay"
RELAY_PORT="7839"
RELAY_ADDR="127.0.0.1:$RELAY_PORT"

DOMAIN=""
TAILSCALE=0
UNINSTALL=0
PURGE=0
VERSION=""
LABEL=""

# Install locations.
#
# Every one of them is root-owned and outside $HOME, so a test cannot isolate
# them by pointing HOME somewhere — hence the overrides. They exist so
# tools/lib/relay-install_test.sh can run the real install and uninstall paths
# inside a temp dir without touching a machine's real /opt, /etc or /var. That
# test refuses to run if any of them disappears from this file.
PREFIX="${IRRLICHT_RELAY_TEST_PREFIX:-/opt/irrlichtrelay}"
STATE_DIR="${IRRLICHT_RELAY_TEST_STATE_DIR:-/var/lib/irrlichtrelay}"
UNIT_PATH="${IRRLICHT_RELAY_TEST_UNIT_PATH:-/etc/systemd/system/irrlichtrelay.service}"
CADDY_DIR="${IRRLICHT_RELAY_TEST_CADDY_DIR:-/etc/caddy}"
CADDYFILE="$CADDY_DIR/Caddyfile"
CADDY_SNIPPET="$CADDY_DIR/irrlichtrelay.caddy"
# The marker on the import line we add to the Caddyfile, so --uninstall can
# remove exactly that line and nothing an operator wrote.
CADDY_MARKER="# irrlichtrelay (managed by irrlicht.io/relay.sh)"

# ─── Helpers ────────────────────────────────────────────────────────────────

if [ -t 1 ]; then
    BOLD=$(printf '\033[1m')
    DIM=$(printf '\033[2m')
    GREEN=$(printf '\033[32m')
    RED=$(printf '\033[31m')
    YELLOW=$(printf '\033[33m')
    RESET=$(printf '\033[0m')
else
    BOLD="" DIM="" GREEN="" RED="" YELLOW="" RESET=""
fi

say()  { printf '%s\n' "$*"; }
step() { printf '  %s…%s ' "$*" "$DIM"; }
ok()   { printf '%s✓%s\n' "$GREEN" "$RESET"; }
fail() { printf '%s✗%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }
warn() { printf '%s!%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }

# fetch downloads over HTTPS, following redirects with the protocol pinned —
# the same shape as site/install.sh. -L is required because GitHub release
# assets redirect to a CDN, but on its own it lets a redirect target choose the
# protocol; --proto pins the first request and --proto-redir every hop after.
fetch() { curl -fsSL --proto '=https' --proto-redir '=https' "$@"; }

usage() {
    cat <<'EOF'
Irrlicht relay installer

Usage:
  curl -fsSL https://irrlicht.io/relay.sh | sudo sh -s -- [options]

Options:
  --domain NAME    Serve over TLS at https://NAME (installs Caddy if absent,
                   writes the reverse-proxy block, enables QR phone pairing)
  --tailscale      Serve over the tailnet with `tailscale serve`; the origin is
                   this host's *.ts.net name (enables QR phone pairing)
  --label NAME     Label for the first bearer token (default: this hostname)
  --version V      Install a specific release (default: latest)
  --uninstall      Stop and remove the relay; keep its state directory
  --purge          With --uninstall: also remove the state directory (tokens,
                   push signing key, paired phones) and the service user
  -h, --help       Show this help

With neither --domain nor --tailscale the relay starts on loopback only:
usable from this host, not from a phone. Pairing a phone needs a stable
HTTPS origin, which is what the two options above provide.

What an install does:
  • Downloads irrlichtrelay-linux-<arch>.tar.gz from the GitHub release
  • Verifies the SHA-256 checksum
  • Extracts to /opt/irrlichtrelay (bin/ and Resources/web/ together)
  • Creates the irrlichtrelay system user and /var/lib/irrlichtrelay
  • Installs and enables the systemd unit
  • Issues the first bearer token and prints it once, together with the
    relay URL, in the form the Mac app's Settings → Sources expects

What it never does: edit a firewall, touch DNS, or write outside
/opt/irrlichtrelay, /var/lib/irrlichtrelay, the systemd unit and, under
--domain, /etc/caddy.
EOF
}

# ─── Parse args ────────────────────────────────────────────────────────────

while [ $# -gt 0 ]; do
    case "$1" in
        --domain)     [ $# -ge 2 ] || fail "--domain needs a hostname"; DOMAIN="$2"; shift 2 ;;
        --domain=*)   DOMAIN="${1#*=}"; shift ;;
        --tailscale)  TAILSCALE=1; shift ;;
        --label)      [ $# -ge 2 ] || fail "--label needs a value"; LABEL="$2"; shift 2 ;;
        --label=*)    LABEL="${1#*=}"; shift ;;
        --version)    [ $# -ge 2 ] || fail "--version needs a value"; VERSION="$2"; shift 2 ;;
        --version=*)  VERSION="${1#*=}"; shift ;;
        --uninstall)  UNINSTALL=1; shift ;;
        --purge)      PURGE=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *) fail "Unknown option: $1 (try --help)" ;;
    esac
done

[ -n "$DOMAIN" ] && [ "$TAILSCALE" -eq 1 ] && fail "--domain and --tailscale are exclusive: the relay has one public origin."
[ "$PURGE" -eq 1 ] && [ "$UNINSTALL" -eq 0 ] && fail "--purge only makes sense together with --uninstall."
case "$DOMAIN" in
    *://*|*/*) fail "--domain wants a bare hostname (relay.example.com), not a URL." ;;
esac

# ─── Preflight ─────────────────────────────────────────────────────────────

say ""
say "  ${BOLD}Irrlicht relay installer${RESET}"
say ""

# Linux with systemd, and nothing else. The relay itself runs anywhere Go
# does; this installer owns a systemd unit and Linux release tarballs, so it
# refuses by name and points at the two documented shapes rather than guessing.
case "$(uname -s)" in
    Linux) ;;
    Darwin)
        fail "This installer is for a Linux server (Shape A). A relay on the Mac itself (Shape B) is a launchd job — see https://irrlicht.io/docs/elfdans.html#relay-setup" ;;
    *) fail "Unsupported OS: $(uname -s). The relay installer supports Linux with systemd." ;;
esac
# `is-system-running` prints a state whenever systemd is PID 1 — `running`,
# `degraded` (one failed unit somewhere, common on servers), `starting` — and
# `offline` or nothing at all when it is not (a container, WSL1, a chroot).
# Its exit code is non-zero for `degraded` too, so grade the word, not the code.
SYSTEMD_STATE=""
if command -v systemctl >/dev/null 2>&1; then
    SYSTEMD_STATE=$(systemctl is-system-running 2>/dev/null || true)
fi
case "$SYSTEMD_STATE" in
    ""|offline|unknown)
        fail "systemd is required: this installer manages the relay as a systemd service. Without it, follow examples/relay/DEPLOY.md by hand." ;;
esac
[ "$(id -u)" -eq 0 ] || fail "Run as root: this writes to /opt, /var/lib and /etc/systemd. Re-run with: curl -fsSL https://irrlicht.io/relay.sh | sudo sh -s -- <options>"

case "$(uname -m)" in
    x86_64|amd64)  ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) fail "Unsupported architecture: $(uname -m). Releases carry linux-amd64 and linux-arm64 only." ;;
esac

for tool in curl tar; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool is required but not found."
done

# sha256_verify <dir> <asset> — checksum-check one asset against
# checksums.sha256, with whichever tool the host ships. shasum first, as
# site/install.sh does: the BSD `sha256sum` some hosts carry has no --status,
# and GNU coreutils' does — so the order is the difference between "verified"
# and "usage: sha256sum" on a host that has both.
sha256_verify() {
    _dir="$1"; _asset="$2"
    if command -v shasum >/dev/null 2>&1; then
        (cd "$_dir" && grep " $_asset\$" checksums.sha256 | shasum -a 256 -c --status)
    elif command -v sha256sum >/dev/null 2>&1; then
        (cd "$_dir" && grep " $_asset\$" checksums.sha256 | sha256sum -c --status)
    else
        fail "Need shasum or sha256sum to verify the download."
    fi
}

# run_as_relay_user <cmd...> — run the relay CLI as the service user with the
# service's IRRLICHT_HOME, so the CLI and the daemon read one tokens file.
# runuser is util-linux and present on every systemd distribution; `su` is the
# fallback for the odd image without it.
run_as_relay_user() {
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "$RELAY_USER" -- env "IRRLICHT_HOME=$STATE_DIR" "$@"
    else
        _cmd=""
        for _arg in "$@"; do
            _cmd="$_cmd '$(printf '%s' "$_arg" | sed "s/'/'\\\\''/g")'"
        done
        su -s /bin/sh -c "IRRLICHT_HOME='$STATE_DIR' exec $_cmd" "$RELAY_USER"
    fi
}

relay_user_exists() {
    if command -v getent >/dev/null 2>&1; then
        getent passwd "$RELAY_USER" >/dev/null 2>&1
    else
        grep -q "^$RELAY_USER:" /etc/passwd 2>/dev/null
    fi
}

# ─── Uninstall ─────────────────────────────────────────────────────────────
# Reverses everything an install wrote, in the reverse order it wrote them.
# The state directory is kept unless --purge: it holds tokens.json,
# vapid-keys.json, push-subscriptions.json and daemon-roster.json, and those
# four files are what lets a rebuilt relay keep every paired phone
# (examples/relay/DEPLOY.md, "Cloned VMs"). Deleting them on a routine
# uninstall would re-pair every phone for someone who only wanted a clean
# reinstall.
uninstall_relay() {
    step "Stopping and disabling the service"
    if [ -f "$UNIT_PATH" ]; then
        systemctl disable --now "$RELAY_NAME" 2>/dev/null || true
        rm -f "$UNIT_PATH"
        systemctl daemon-reload 2>/dev/null || true
    fi
    ok

    step "Removing $PREFIX"
    rm -rf "$PREFIX"
    ok

    if [ -f "$CADDY_SNIPPET" ] || { [ -f "$CADDYFILE" ] && grep -q "$CADDY_MARKER" "$CADDYFILE"; }; then
        step "Removing the Caddy site"
        rm -f "$CADDY_SNIPPET"
        if [ -f "$CADDYFILE" ] && grep -q "$CADDY_MARKER" "$CADDYFILE"; then
            # Drop our marker line and the import that follows it; touch nothing else.
            _tmp="$CADDYFILE.irrlicht-tmp"
            grep -v -e "$CADDY_MARKER" -e "^import $CADDY_SNIPPET\$" "$CADDYFILE" >"$_tmp" || true
            cat "$_tmp" >"$CADDYFILE"
            rm -f "$_tmp"
        fi
        if command -v caddy >/dev/null 2>&1; then
            systemctl reload caddy 2>/dev/null || true
        fi
        ok
    fi

    if [ "$PURGE" -eq 1 ]; then
        step "Removing $STATE_DIR and the $RELAY_USER user"
        rm -rf "$STATE_DIR"
        if relay_user_exists; then
            userdel "$RELAY_USER" 2>/dev/null || true
        fi
        ok
    fi
}

if [ "$UNINSTALL" -eq 1 ]; then
    uninstall_relay
    say ""
    say "  ${GREEN}✓${RESET} irrlichtrelay uninstalled"
    if [ "$PURGE" -eq 0 ]; then
        say "  ${DIM}State in $STATE_DIR was kept (tokens, push signing key, paired phones)."
        say "  Remove it too with: --uninstall --purge${RESET}"
    fi
    if command -v tailscale >/dev/null 2>&1 && tailscale serve status 2>/dev/null | grep -q ":$RELAY_PORT"; then
        say ""
        warn "tailscale serve still forwards to port $RELAY_PORT. Turn it off with:"
        warn "  tailscale serve --bg $RELAY_PORT off"
    fi
    say ""
    exit 0
fi

# ─── Detect version ────────────────────────────────────────────────────────

if [ -z "$VERSION" ]; then
    step "Detecting latest version"
    # Follow the /releases/latest redirect to avoid GitHub API rate limits.
    VERSION=$(fetch -o /dev/null -w '%{url_effective}' \
        "https://github.com/$REPO/releases/latest" \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+$') || true
    [ -n "$VERSION" ] || fail "Could not detect latest version"
    printf 'v%s\n' "$VERSION"
fi

# ─── Download and verify ───────────────────────────────────────────────────
# Nothing on the host is touched until the bytes are verified: a failed
# download must leave a running relay running.

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT INT TERM

BASE="https://github.com/$REPO/releases/download/v${VERSION}"
ASSET="${RELAY_NAME}-linux-${ARCH}.tar.gz"

step "Downloading checksums"
fetch -o "$TMPDIR/checksums.sha256" "$BASE/checksums.sha256" \
    || fail "Could not download $BASE/checksums.sha256"
ok

step "Downloading $ASSET"
fetch -o "$TMPDIR/$ASSET" "$BASE/$ASSET" \
    || fail "Download failed — does v$VERSION carry $ASSET? Relay tarballs ship from v0.6.3 on."
ok

step "Verifying checksum"
sha256_verify "$TMPDIR" "$ASSET" || fail "Checksum mismatch — aborting"
ok

step "Extracting $ASSET"
mkdir -p "$TMPDIR/extract"
tar -xzf "$TMPDIR/$ASSET" -C "$TMPDIR/extract" || fail "Extraction failed"
# The layout is load-bearing, not cosmetic: the relay finds the dashboard it
# serves at ../Resources/web relative to the binary, and a lone binary answers
# 503 on /. Refuse a tarball that would install that.
[ -x "$TMPDIR/extract/bin/$RELAY_NAME" ] \
    || fail "Unexpected tarball layout: bin/$RELAY_NAME is missing. Refusing to install a relay with no dashboard."
[ -f "$TMPDIR/extract/Resources/web/index.html" ] \
    || fail "Unexpected tarball layout: Resources/web/index.html is missing. Refusing to install a relay that would answer 503 on /."
ok

# ─── Origin ────────────────────────────────────────────────────────────────
# Decided before anything is written, because the unit's ExecStart carries
# --public-url and the token printout carries the URL.

PUBLIC_URL=""
if [ -n "$DOMAIN" ]; then
    PUBLIC_URL="https://$DOMAIN"
elif [ "$TAILSCALE" -eq 1 ]; then
    command -v tailscale >/dev/null 2>&1 \
        || fail "--tailscale needs the tailscale CLI on this host (https://tailscale.com/download/linux)."
    step "Reading this host's tailnet name"
    # Self.DNSName is the first DNSName in `tailscale status --json`; it ends
    # with a trailing dot.
    TS_NAME=$(tailscale status --json 2>/dev/null \
        | grep -o '"DNSName": *"[^"]*"' | head -n 1 \
        | sed -e 's/.*"DNSName": *"//' -e 's/"$//' -e 's/\.$//') || true
    [ -n "$TS_NAME" ] || fail "Could not read a DNSName from 'tailscale status --json'. Is tailscale up and MagicDNS enabled?"
    PUBLIC_URL="https://$TS_NAME"
    printf '%s\n' "$TS_NAME"
fi

# ─── Install ───────────────────────────────────────────────────────────────

if [ -f "$UNIT_PATH" ]; then
    step "Stopping the running relay for the upgrade"
    systemctl stop "$RELAY_NAME" 2>/dev/null || true
    ok
fi

step "Installing to $PREFIX"
rm -rf "$PREFIX"
mkdir -p "$PREFIX"
cp -R "$TMPDIR/extract/." "$PREFIX/"
chmod 755 "$PREFIX/bin/$RELAY_NAME"
ok

step "Creating the $RELAY_USER service user"
if relay_user_exists; then
    printf '%sexists%s\n' "$DIM" "$RESET"
else
    useradd --system --no-create-home --home "$STATE_DIR" --shell /usr/sbin/nologin "$RELAY_USER" \
        || fail "Could not create the $RELAY_USER user"
    ok
fi

step "Creating $STATE_DIR"
mkdir -p "$STATE_DIR"
chmod 0700 "$STATE_DIR"
chown "$RELAY_USER:$RELAY_USER" "$STATE_DIR" || fail "Could not chown $STATE_DIR"
ok

step "Writing $UNIT_PATH"
EXEC_START="$PREFIX/bin/$RELAY_NAME serve --addr $RELAY_ADDR --auth tokens-file"
[ -n "$PUBLIC_URL" ] && EXEC_START="$EXEC_START --public-url $PUBLIC_URL"
mkdir -p "$(dirname "$UNIT_PATH")"
# Same unit as examples/relay/irrlichtrelay.service, minus IRRLICHT_UI_DIR: the
# tarball layout lets the relay find Resources/web next to bin/ on its own.
cat >"$UNIT_PATH" <<UNIT
# Written by https://irrlicht.io/relay.sh — re-run the installer to upgrade,
# or --uninstall to remove. Hand edits survive neither.
[Unit]
Description=Irrlicht relay — cross-host session hub
Documentation=https://github.com/ingo-eichhorst/Irrlicht/blob/main/examples/relay/DEPLOY.md
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$RELAY_USER
Group=$RELAY_USER
StateDirectory=$RELAY_NAME
StateDirectoryMode=0700
Environment=IRRLICHT_HOME=$STATE_DIR
ExecStart=$EXEC_START
Restart=on-failure
RestartSec=2

# Hardening — the relay only needs a network socket and its state dir.
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes

[Install]
WantedBy=multi-user.target
UNIT
ok

# ─── First token ───────────────────────────────────────────────────────────
# Issued before the service starts so the first start already has a tokens
# file to load; a serving relay re-reads it on change anyway. On a re-run with
# tokens already issued, keep them: a fresh token on every upgrade would leave
# the operator with a growing list and no idea which one the Mac holds.

TOKEN=""
if [ -s "$STATE_DIR/tokens.json" ] && grep -q '"hash"' "$STATE_DIR/tokens.json"; then
    step "Keeping the existing tokens in $STATE_DIR/tokens.json"
    printf '%skept%s\n' "$DIM" "$RESET"
else
    [ -n "$LABEL" ] || LABEL="$(hostname 2>/dev/null || echo relay)"
    step "Issuing the first bearer token (label: $LABEL)"
    # `token issue` prints three lines: a summary, the indented plaintext, and
    # a reminder (core/cmd/irrlichtrelay/main.go runTokenIssue).
    TOKEN_OUT=$(run_as_relay_user "$PREFIX/bin/$RELAY_NAME" token issue --label "$LABEL") \
        || fail "token issue failed: $TOKEN_OUT"
    TOKEN=$(printf '%s\n' "$TOKEN_OUT" | sed -n '2p' | tr -d '[:space:]')
    [ -n "$TOKEN" ] || fail "token issue printed nothing recognisable as a token: $TOKEN_OUT"
    ok
fi

# ─── Start ─────────────────────────────────────────────────────────────────

step "Enabling and starting the service"
systemctl daemon-reload
systemctl enable --now "$RELAY_NAME" || fail "systemctl enable --now $RELAY_NAME failed — see: journalctl -u $RELAY_NAME -n 50"
ok

step "Waiting for the relay to answer on $RELAY_ADDR"
i=0
UP=0
while [ $i -lt 15 ]; do
    if curl -sf -m 1 "http://$RELAY_ADDR/api/v1/version" >/dev/null 2>&1; then
        UP=1
        break
    fi
    sleep 1
    i=$((i + 1))
done
if [ "$UP" -eq 1 ]; then
    ok
else
    printf '%sstill starting%s\n' "$YELLOW" "$RESET"
    warn "The relay did not answer within 15s. Check: journalctl -u $RELAY_NAME -n 50"
    warn "  A unit dying at status=203/EXEC means the wrong architecture was installed ($ARCH)."
fi

# ─── TLS front ─────────────────────────────────────────────────────────────

if [ -n "$DOMAIN" ]; then
    if ! command -v caddy >/dev/null 2>&1; then
        step "Installing Caddy"
        if command -v apt-get >/dev/null 2>&1; then
            # Caddy's own Debian/Ubuntu repository, as documented at
            # https://caddyserver.com/docs/install#debian-ubuntu-raspbian
            export DEBIAN_FRONTEND=noninteractive
            apt-get install -y -q debian-keyring debian-archive-keyring apt-transport-https curl gnupg >/dev/null \
                || fail "apt-get could not install Caddy's repository prerequisites"
            fetch 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
                | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
                || fail "Could not fetch Caddy's signing key"
            fetch 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
                >/etc/apt/sources.list.d/caddy-stable.list \
                || fail "Could not fetch Caddy's apt source list"
            apt-get update -q >/dev/null || fail "apt-get update failed after adding Caddy's repository"
            apt-get install -y -q caddy >/dev/null || fail "apt-get install caddy failed"
        elif command -v dnf >/dev/null 2>&1; then
            # https://caddyserver.com/docs/install#fedora-redhat-centos
            dnf install -y -q 'dnf-command(copr)' >/dev/null || fail "dnf could not install the copr plugin"
            dnf copr enable -y @caddy/caddy >/dev/null || fail "dnf copr enable @caddy/caddy failed"
            dnf install -y -q caddy >/dev/null || fail "dnf install caddy failed"
        else
            fail "No apt-get or dnf here. Install Caddy yourself (https://caddyserver.com/docs/install) and re-run with --domain $DOMAIN."
        fi
        ok
    fi

    step "Writing the Caddy site for $DOMAIN"
    mkdir -p "$CADDY_DIR"
    cat >"$CADDY_SNIPPET" <<CADDY
$CADDY_MARKER
# TLS from Let's Encrypt, reverse-proxied to the relay on loopback. The
# WebSocket upgrade needs nothing extra; Caddy forwards it by default.
$DOMAIN {
    reverse_proxy $RELAY_ADDR
}
CADDY
    if [ ! -f "$CADDYFILE" ] || ! grep -q "$CADDY_MARKER" "$CADDYFILE"; then
        # Append rather than replace: the operator may already serve other
        # sites from this Caddyfile.
        {
            printf '\n%s\n' "$CADDY_MARKER"
            printf 'import %s\n' "$CADDY_SNIPPET"
        } >>"$CADDYFILE"
    fi
    ok

    step "Reloading Caddy"
    systemctl enable --now caddy >/dev/null 2>&1 || fail "systemctl enable --now caddy failed — see: journalctl -u caddy -n 50"
    systemctl reload caddy 2>/dev/null || systemctl restart caddy || fail "Caddy would not reload — check: caddy validate --config $CADDYFILE"
    ok

    # Caddy's packaged unit grants CAP_NET_BIND_SERVICE; a hand-built one may
    # not, and an ACME failure from `bind: permission denied` looks exactly like
    # a blocked port (DEPLOY.md, "TLS and the hostname"). Check, do not fix.
    if ! systemctl show caddy -p AmbientCapabilities 2>/dev/null | grep -qi 'cap_net_bind_service'; then
        warn "Caddy's unit does not grant CAP_NET_BIND_SERVICE, so it may not be able to bind :443. Add a drop-in:"
        warn "  systemctl edit caddy   →   [Service]"
        warn "                             AmbientCapabilities=CAP_NET_BIND_SERVICE"
    fi
elif [ "$TAILSCALE" -eq 1 ]; then
    step "Serving port $RELAY_PORT on the tailnet"
    tailscale serve --bg "$RELAY_PORT" >/dev/null 2>&1 \
        || fail "tailscale serve --bg $RELAY_PORT failed. HTTPS certificates must be enabled for the tailnet (admin console → DNS → HTTPS Certificates)."
    ok
fi

# ─── Report ────────────────────────────────────────────────────────────────

say ""
say "  ${GREEN}✓${RESET} ${BOLD}irrlichtrelay v$VERSION${RESET} installed and running as a systemd service"
say ""

# What the Mac wants, in the form it wants it. Settings → Sources takes a
# WebSocket URL; the daemon accepts https:// too and rewrites it, but printing
# the scheme the field shows as its placeholder removes one guess (#1965).
if [ -n "$PUBLIC_URL" ]; then
    MAC_URL="wss://${PUBLIC_URL#https://}"
else
    MAC_URL="ws://$RELAY_ADDR"
fi

say "  ${BOLD}On your Mac${RESET}: Irrlicht menu → Settings → Advanced Settings → Sources"
say "    Turn on   ${BOLD}Publish to relay${RESET}"
say "    Relay URL ${BOLD}$MAC_URL${RESET}"
if [ -n "$TOKEN" ]; then
    say "    Token     ${BOLD}$TOKEN${RESET}"
    say "  ${DIM}The token is shown once; only its hash is stored on this host.${RESET}"
else
    say "    Token     ${DIM}your existing token (issue another with:${RESET}"
    say "              ${DIM}sudo -u $RELAY_USER IRRLICHT_HOME=$STATE_DIR $PREFIX/bin/$RELAY_NAME token issue --label <name>)${RESET}"
fi
say ""
say "  ${BOLD}Headless daemon${RESET} (Linux, no Mac app):"
if [ -n "$TOKEN" ]; then
    say "    IRRLICHT_RELAY_URL=$MAC_URL IRRLICHT_RELAY_TOKEN=$TOKEN irrlichd"
else
    say "    IRRLICHT_RELAY_URL=$MAC_URL IRRLICHT_RELAY_TOKEN=<token> irrlichd"
fi
say ""

if [ -n "$PUBLIC_URL" ]; then
    say "  ${BOLD}Then pair a phone${RESET}: in the same Settings pane press ${BOLD}Pair a phone…${RESET} and scan the QR."
    say "  Public origin: $PUBLIC_URL"
else
    warn "Loopback only: this relay is reachable from this host and nothing else."
    warn "  Pairing a phone needs a stable HTTPS origin. Re-run with --domain <name>"
    warn "  or --tailscale to get one; every paired phone is bound to that origin."
fi

if [ -n "$DOMAIN" ]; then
    say ""
    say "  ${BOLD}Still yours to do${RESET}:"
    say "    1. DNS: point $DOMAIN at this host's public IP (Caddy fetches the certificate once it resolves)."
    say "    2. Firewall: open TCP 443 inbound. This installer never edits firewalls — run it yourself:"
    if command -v firewall-cmd >/dev/null 2>&1; then
        say "         firewall-cmd --zone=public --permanent --add-port=443/tcp && firewall-cmd --reload"
    elif command -v iptables >/dev/null 2>&1; then
        say "         iptables -I INPUT 6 -p tcp --dport 443 -j ACCEPT    # INSERT above the final REJECT; appending does nothing"
        say "         netfilter-persistent save                           # or however this host persists rules"
    else
        say "         (no firewall-cmd or iptables found; open 443 however this host's firewall is managed)"
    fi
    say "       On Oracle Cloud the VCN security list is a second gate; see examples/relay/DEPLOY.md."
    say "       Never use ufw on an OCI Ubuntu image, and never flush the ruleset."
fi

say ""
say "  ${DIM}Logs: journalctl -u $RELAY_NAME -f     Uninstall: curl -fsSL https://irrlicht.io/relay.sh | sudo sh -s -- --uninstall${RESET}"
say ""
exit 0
