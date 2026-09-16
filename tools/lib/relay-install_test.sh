#!/usr/bin/env bash
# Tests for site/relay.sh, the one-command Linux installer for irrlichtrelay
# (#1964). It replaces the ~15 hand-run server steps of examples/relay/DEPLOY.md,
# and an installer's failure mode is silence: a wrong architecture that fails
# later as status=203/EXEC, a flat tarball that installs a relay answering 503
# on /, a checksum nobody compared. Each case here feeds it one thing that is
# wrong in one way and grades the refusal, or drives one path end to end and
# grades what landed on disk.
#
# SAFETY. Every case runs the real site/relay.sh as a subprocess, and that
# script `rm -rf`s its install prefix, writes a systemd unit, creates users and
# starts services. Three things keep it off this machine, and all three are
# load-bearing:
#   1. The four IRRLICHT_RELAY_TEST_* overrides redirect every path the script
#      writes to (/opt/irrlichtrelay, /var/lib/irrlichtrelay, the unit, /etc/caddy)
#      into a mktemp -d. The guard below refuses to run if any of them has been
#      dropped from the script.
#   2. PATH is fronted by stubs for systemctl/useradd/userdel/chown/runuser/
#      curl/uname/id/getent/caddy/tailscale/firewall-cmd, so nothing here can
#      reach a real service manager, a real user database, or the network.
#   3. `env -i`, so the stubs' own switches (STUB_UNAME_S and friends) are the
#      only environment the installer sees.
# Build every environment through new_env().
#
# MUTATIONS. The last section re-runs this file against copies of the
# installer that are each broken in one way, and requires the case guarding
# that property to go red. That is the evidence AGENTS.md asks for from a
# guard: not "the check exists" but "removing it is noticed". A mutation that
# stays green is a FAIL of this suite, so the list below cannot drift into
# decoration. ONLY_CASE=<name> runs one case; the mutant children use it.
#
# Convention follows tools/lib/install-uninstall_test.sh: plain bash,
# hand-rolled asserts, a `fails` counter, "ALL PASS" / "N FAILED" at the end.

set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$DIR/../.." && pwd)"
RELAY_SH="${RELAY_SH:-$REPO_ROOT/site/relay.sh}"
NAME="relay-install_test"
ONLY_CASE="${ONLY_CASE:-}"

# Run the installer under a real POSIX shell where one exists (dash is an
# Apple system binary on macOS, and IS /bin/sh on Debian/Ubuntu, where
# `curl | sh` lands). Same reasoning as install-uninstall_test.sh (#1423).
POSIX_SH=""
for candidate in dash ash; do
    if command -v "$candidate" >/dev/null 2>&1; then
        POSIX_SH="$(command -v "$candidate")"
        break
    fi
done
RUNNER="${POSIX_SH:-sh}"

fails=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() {
    printf 'FAIL: %s\n' "$1"
    [ $# -gt 1 ] && printf '      %s\n' "$2"
    fails=$((fails + 1))
    return 0
}
assert_contains() {
    local haystack="$1" needle="$2" what="$3"
    case "$haystack" in
        *"$needle"*) pass "$what" ;;
        *) fail "$what" "expected to find [$needle] in: $(printf '%s' "$haystack" | head -c 600)" ;;
    esac
}
assert_not_contains() {
    local haystack="$1" needle="$2" what="$3"
    case "$haystack" in
        *"$needle"*) fail "$what" "did NOT expect [$needle] in: $(printf '%s' "$haystack" | head -c 600)" ;;
        *) pass "$what" ;;
    esac
}
assert_eq() {
    if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3" "expected [$2] got [$1]"; fi
}
assert_nonzero() {
    if [[ "$1" -ne 0 ]]; then pass "$2"; else fail "$2" "expected a non-zero exit, got 0"; fi
}
assert_file_absent() {
    if [[ -e "$1" ]]; then fail "$2" "expected [$1] to be gone"; else pass "$2"; fi
}
assert_file_present() {
    if [[ -e "$1" ]]; then pass "$2"; else fail "$2" "expected [$1] to exist"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[[ -f "$RELAY_SH" ]] || { echo "$NAME: $RELAY_SH does not exist" >&2; exit 1; }

# ---------------------------------------------------------------------------
# The seam guard. Every case depends on the installer honouring the four
# test overrides; if one is dropped — a plausible cleanup, since they are test
# seams in production code — the case would write to the real /opt, /etc or
# /var/lib and only THEN report failure. Refuse to run instead.
for seam in IRRLICHT_RELAY_TEST_PREFIX IRRLICHT_RELAY_TEST_STATE_DIR IRRLICHT_RELAY_TEST_UNIT_PATH IRRLICHT_RELAY_TEST_CADDY_DIR; do
    if ! grep -q "$seam" "$RELAY_SH"; then
        echo "$NAME: REFUSING TO RUN — $RELAY_SH no longer honours $seam." >&2
        echo "  Without it this test writes to the real system paths as root." >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Fixtures

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# make_release <fixture-dir> <mode> — build irrlichtrelay-linux-amd64.tar.gz
# plus checksums.sha256 the way tools/build-release.sh lays them out.
#   ok      bin/irrlichtrelay + Resources/web/, correct checksum
#   badsum  same tarball, checksum line for a different byte string
#   flat    the binary at the tarball root, no bin/, no Resources/ — what a
#           `tar` of a lone binary produces
#   noweb   bin/irrlichtrelay and nothing else — the layout that installs
#           cleanly and answers 503 on /, so the ONE check that catches it is
#           the Resources/web one
#   nobin   Resources/web/ and no bin/ — the mirror image, pinning the other
make_release() {
    local out="$1" mode="$2"
    local staging="$out/staging"
    rm -rf "$staging"; mkdir -p "$out" "$staging"
    case "$mode" in
        flat)  make_relay_stub "$staging/irrlichtrelay" ;;
        noweb) make_relay_stub "$staging/bin/irrlichtrelay" ;;
        nobin) mkdir -p "$staging/Resources/web"
               printf '<!doctype html><title>Irrlicht</title>\n' >"$staging/Resources/web/index.html" ;;
        *)     make_relay_stub "$staging/bin/irrlichtrelay"
               mkdir -p "$staging/Resources/web"
               printf '<!doctype html><title>Irrlicht</title>\n' >"$staging/Resources/web/index.html"
               printf '// elfdans\n' >"$staging/Resources/web/elfdans.js" ;;
    esac
    tar -czf "$out/irrlichtrelay-linux-amd64.tar.gz" -C "$staging" .
    rm -rf "$staging"
    local sum
    sum="$(sha256_of "$out/irrlichtrelay-linux-amd64.tar.gz")"
    if [[ "$mode" == badsum ]]; then
        sum="0000000000000000000000000000000000000000000000000000000000000000"
    fi
    printf '%s  irrlichtrelay-linux-amd64.tar.gz\n' "$sum" >"$out/checksums.sha256"
    # An unrelated asset line, so the grep in sha256_verify has to pick ours.
    printf '%s  irrlichd-linux-amd64.tar.gz\n' "1111111111111111111111111111111111111111111111111111111111111111" >>"$out/checksums.sha256"
}

# The relay binary inside the tarball. Speaks the two subcommands the
# installer uses, records what it was called with and under which
# IRRLICHT_HOME, and writes a tokens.json shaped like the real one so the
# "keep existing tokens" branch has something to find on a re-run.
make_relay_stub() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat >"$path" <<'STUB'
#!/bin/sh
printf 'IRRLICHT_HOME=%s argv=%s\n' "${IRRLICHT_HOME:-unset}" "$*" >>"${RELAY_TEST_LOG:?}"
case "$1" in
    --version) echo "0.6.3"; exit 0 ;;
    token)
        [ "$2" = "issue" ] || { echo "stub: unexpected token subcommand $2" >&2; exit 64; }
        mkdir -p "${IRRLICHT_HOME:?}"
        printf '[{"id":"t1","label":"%s","hash":"deadbeef","created":1}]\n' "$4" >"$IRRLICHT_HOME/tokens.json"
        printf 'token t1 issued (label %s, workspace "")\n' "\"$4\""
        printf '  %s\n' "stub-token-4f3a9c"
        echo "Store it now — it is shown only once and only its hash is kept."
        exit 0 ;;
    *) echo "stub irrlichtrelay: unexpected args: $*" >&2; exit 64 ;;
esac
STUB
    chmod +x "$path"
}

# new_env <name> [mode] — a fake machine: stubs on PATH, a fixture release,
# and the four redirected install locations. Echoes the root.
new_env() {
    local root="$WORK/$1"
    mkdir -p "$root/bin" "$root/home" "$root/fixtures" "$root/opt" "$root/etc/systemd/system" "$root/etc/caddy" "$root/var/lib" "$root/log"
    make_release "$root/fixtures" "${2:-ok}"

    # curl: serve fixtures by asset basename, answer the /releases/latest
    # redirect probe, and say "up" to the loopback health check. Logs every
    # argv so a case can assert the protocol pin travelled with the download.
    cat >"$root/bin/curl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$STUB_LOG_DIR/curl.log"
url=""; out=""; want_effective=0
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        -w) want_effective=1; shift 2 ;;
        -m) shift 2 ;;
        --proto|--proto-redir) shift 2 ;;
        http://*|https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
case "$url" in
    */releases/latest)
        [ "$want_effective" -eq 1 ] && printf 'https://github.com/ingo-eichhorst/Irrlicht/releases/tag/v0.6.3'
        exit 0 ;;
    http://127.0.0.1:7839/*) exit "${STUB_HEALTH_EXIT:-0}" ;;
    *)
        name="${url##*/}"
        [ -f "$STUB_FIXTURES/$name" ] || exit 22
        if [ -n "$out" ]; then cp "$STUB_FIXTURES/$name" "$out"; else cat "$STUB_FIXTURES/$name"; fi
        exit 0 ;;
esac
STUB

    cat >"$root/bin/uname" <<'STUB'
#!/bin/sh
case "$1" in
    -s) echo "${STUB_UNAME_S:-Linux}" ;;
    -m) echo "${STUB_UNAME_M:-x86_64}" ;;
    *) echo Linux ;;
esac
STUB
    cat >"$root/bin/id" <<'STUB'
#!/bin/sh
echo "${STUB_UID:-0}"
STUB
    cat >"$root/bin/hostname" <<'STUB'
#!/bin/sh
echo testbox
STUB
    cat >"$root/bin/systemctl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$STUB_LOG_DIR/systemctl.log"
case "$1" in
    is-system-running) echo "${STUB_SYSTEMD_STATE:-running}" ;;
    show) echo "AmbientCapabilities=cap_net_bind_service" ;;
esac
exit 0
STUB
    cat >"$root/bin/useradd" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$STUB_LOG_DIR/useradd.log"
touch "$STUB_LOG_DIR/user-exists"
STUB
    cat >"$root/bin/userdel" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$STUB_LOG_DIR/userdel.log"
rm -f "$STUB_LOG_DIR/user-exists"
STUB
    cat >"$root/bin/getent" <<'STUB'
#!/bin/sh
[ -f "$STUB_LOG_DIR/user-exists" ]
STUB
    cat >"$root/bin/chown" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$STUB_LOG_DIR/chown.log"
STUB
    # runuser -u USER -- cmd...: record, then run the command as ourselves.
    cat >"$root/bin/runuser" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$STUB_LOG_DIR/runuser.log"
while [ $# -gt 0 ]; do
    case "$1" in
        --) shift; break ;;
        -u) shift 2 ;;
        *) shift ;;
    esac
done
exec "$@"
STUB
    # sleep: the health-check loop sleeps between probes; a case that drives
    # the "never answers" branch would otherwise wait the real 15 seconds.
    cat >"$root/bin/sleep" <<'STUB'
#!/bin/sh
exit 0
STUB
    chmod +x "$root"/bin/*
    echo "$root"
}

# with_stub <root> <name> — add a stub that only records its argv.
with_stub() {
    local root="$1" name="$2"
    cat >"$root/bin/$name" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >>"\$STUB_LOG_DIR/$name.log"
exit 0
STUB
    chmod +x "$root/bin/$name"
}

with_tailscale_stub() {
    local root="$1"
    cat >"$root/bin/tailscale" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$STUB_LOG_DIR/tailscale.log"
case "$1 $2" in
    "status --json")
        cat <<'JSON'
{
  "Version": "1.80.0",
  "Self": {
    "HostName": "box",
    "DNSName": "box.tail1234.ts.net.",
    "Online": true
  },
  "Peer": { "nodekey:abc": { "DNSName": "other.tail1234.ts.net." } }
}
JSON
        ;;
    "serve status") ;;
esac
exit 0
STUB
    chmod +x "$root/bin/tailscale"
}

# run_installer <root> [VAR=value ...] -- [installer args...]
# Runs the real installer inside the fake machine. Echoes stdout+stderr,
# returns its exit code.
run_installer() {
    local root="$1"; shift
    local -a envs=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
    [[ $# -gt 0 ]] && shift
    env -i \
        HOME="$root/home" \
        PATH="$root/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        IRRLICHT_RELAY_TEST_PREFIX="$root/opt/irrlichtrelay" \
        IRRLICHT_RELAY_TEST_STATE_DIR="$root/var/lib/irrlichtrelay" \
        IRRLICHT_RELAY_TEST_UNIT_PATH="$root/etc/systemd/system/irrlichtrelay.service" \
        IRRLICHT_RELAY_TEST_CADDY_DIR="$root/etc/caddy" \
        STUB_LOG_DIR="$root/log" \
        STUB_FIXTURES="$root/fixtures" \
        RELAY_TEST_LOG="$root/log/relay-cli.log" \
        "${envs[@]+"${envs[@]}"}" \
        "$RUNNER" "$RELAY_SH" "$@" 2>&1
}

logof() { cat "$1/log/$2.log" 2>/dev/null || true; }
count_lines() { printf '%s' "$1" | grep -c . ; }

# ===========================================================================
# 1. THE HAPPY PATH, loopback, then a RE-RUN (upgrade) on the same machine.
#    Everything the runbook did by hand lands where the runbook put it, and
#    the printout is the Mac's two fields plus the toggle, in the form the
#    Settings pane expects. The re-run stops the running relay, replaces the
#    prefix and keeps the tokens: a fresh token per upgrade leaves the operator
#    with a growing list and no idea which one the Mac holds.
# ===========================================================================
case_happy() {
    local root out rc unit curl_log downloads pinned
    root="$(new_env happy)"
    out="$(run_installer "$root" -- --label first-mac)"; rc=$?
    assert_eq "$rc" "0" "1 happy: exits 0"
    assert_file_present "$root/opt/irrlichtrelay/bin/irrlichtrelay" "1 happy: bin/irrlichtrelay installed under the prefix"
    assert_file_present "$root/opt/irrlichtrelay/Resources/web/index.html" "1 happy: Resources/web/ installed next to bin/ (the layout that avoids the 503)"
    unit="$(cat "$root/etc/systemd/system/irrlichtrelay.service" 2>/dev/null)"
    assert_contains "$unit" "ExecStart=$root/opt/irrlichtrelay/bin/irrlichtrelay serve --addr 127.0.0.1:7839 --auth tokens-file" "1 happy: unit ExecStart points at the prefix, loopback, auth on"
    assert_not_contains "$unit" "--public-url" "1 happy: no --public-url without an origin"
    assert_not_contains "$unit" "IRRLICHT_UI_DIR" "1 happy: unit needs no IRRLICHT_UI_DIR (tarball layout resolves the dashboard)"
    assert_contains "$unit" "Environment=IRRLICHT_HOME=$root/var/lib/irrlichtrelay" "1 happy: unit's IRRLICHT_HOME is the state dir"
    assert_contains "$unit" "User=irrlichtrelay" "1 happy: runs as the service user"
    assert_contains "$(logof "$root" useradd)" "--system" "1 happy: service user created as a system account"
    assert_contains "$(logof "$root" chown)" "irrlichtrelay:irrlichtrelay $root/var/lib/irrlichtrelay" "1 happy: state dir handed to the service user"
    assert_contains "$(logof "$root" runuser)" "-u irrlichtrelay -- env IRRLICHT_HOME=$root/var/lib/irrlichtrelay" "1 happy: token issued AS the service user under the service's IRRLICHT_HOME"
    assert_contains "$(logof "$root" relay-cli)" "IRRLICHT_HOME=$root/var/lib/irrlichtrelay argv=token issue --label first-mac" "1 happy: the relay CLI saw that IRRLICHT_HOME and the label"
    assert_file_present "$root/var/lib/irrlichtrelay/tokens.json" "1 happy: tokens.json landed in the state dir the unit reads"
    assert_contains "$(logof "$root" systemctl)" "daemon-reload" "1 happy: systemctl daemon-reload"
    assert_contains "$(logof "$root" systemctl)" "enable --now irrlichtrelay" "1 happy: unit enabled and started"
    assert_contains "$out" "installed and running" "1 happy: reports running only after the health check answered"
    assert_contains "$out" "Publish to relay" "1 happy: names the toggle to flip"
    assert_contains "$out" "ws://127.0.0.1:7839" "1 happy: relay URL printed in the scheme the Sources field expects"
    assert_contains "$out" "stub-token-4f3a9c" "1 happy: the plaintext token is printed once"
    assert_contains "$out" "IRRLICHT_RELAY_URL=ws://127.0.0.1:7839 IRRLICHT_RELAY_TOKEN=stub-token-4f3a9c" "1 happy: headless daemon line is copy-pasteable"
    assert_contains "$out" "needs a stable HTTPS origin" "1 happy: loopback run says plainly why a phone cannot pair yet"
    assert_not_contains "$out" "Pair a phone" "1 happy: does not offer QR pairing without an origin"
    # The protocol pin has to travel with every download, or a hijacked
    # redirect can hand us a plaintext substitute (site/install.sh's fetch).
    curl_log="$(logof "$root" curl)"
    downloads="$(printf '%s\n' "$curl_log" | grep -c 'releases/download')"
    pinned="$(printf '%s\n' "$curl_log" | grep 'releases/download' | grep -c -- '--proto =https --proto-redir =https')"
    assert_eq "$downloads" "2" "1 happy: two release downloads (checksums + tarball)"
    assert_eq "$pinned" "$downloads" "1 happy: every release download carried the https protocol pin"
    assert_contains "$curl_log" "releases/download/v0.6.3/" "1 happy: detected version builds a v-prefixed download path"
    assert_file_absent "$root/etc/caddy/irrlichtrelay.caddy" "1 happy: no Caddy site without --domain"

    # --- re-run on the same machine ---
    printf 'stale\n' >"$root/opt/irrlichtrelay/stale-file-from-old-version"
    out="$(run_installer "$root" --)"; rc=$?
    assert_eq "$rc" "0" "2 rerun: exits 0"
    assert_contains "$(logof "$root" systemctl)" "stop irrlichtrelay" "2 rerun: stops the running relay before replacing it"
    assert_file_absent "$root/opt/irrlichtrelay/stale-file-from-old-version" "2 rerun: the old prefix contents are replaced, not merged"
    assert_contains "$out" "Keeping the existing tokens" "2 rerun: says it kept the tokens"
    assert_eq "$(logof "$root" relay-cli | grep -c 'token issue')" "1" "2 rerun: token issue ran once across both runs"
    assert_eq "$(count_lines "$(logof "$root" useradd)")" "1" "2 rerun: useradd ran once across both runs"
    assert_not_contains "$out" "stub-token" "2 rerun: does not print a token it did not issue"
    assert_contains "$out" "token issue --label" "2 rerun: tells the operator how to issue another one"
}

# ===========================================================================
# 3. CHECKSUM MISMATCH must refuse before anything is written.
# ===========================================================================
case_badsum() {
    local root out rc
    root="$(new_env badsum badsum)"
    out="$(run_installer "$root" --)"; rc=$?
    assert_nonzero "$rc" "3 badsum: exits non-zero"
    assert_contains "$out" "Checksum mismatch" "3 badsum: names the checksum"
    assert_file_absent "$root/opt/irrlichtrelay" "3 badsum: nothing installed"
    assert_file_absent "$root/etc/systemd/system/irrlichtrelay.service" "3 badsum: no unit written"
    assert_not_contains "$(logof "$root" systemctl)" "enable" "3 badsum: nothing enabled"
    assert_eq "$(count_lines "$(logof "$root" useradd)")" "0" "3 badsum: no user created"
}

# ===========================================================================
# 4. TARBALL LAYOUT. Three fixtures, each wrong in one way, so that each of
#    the two layout checks is pinned on its own: `noweb` is caught only by
#    the Resources/web check, `nobin` only by the bin/ check, and `flat` by
#    either. The 503 relay the comment in relay.sh names is the `noweb` one.
# ===========================================================================
case_layout() {
    local mode root out rc
    for mode in flat noweb nobin; do
        root="$(new_env "layout-$mode" "$mode")"
        out="$(run_installer "$root" --)"; rc=$?
        assert_nonzero "$rc" "4 $mode: exits non-zero"
        assert_contains "$out" "tarball layout" "4 $mode: names the layout as the problem"
        assert_file_absent "$root/opt/irrlichtrelay" "4 $mode: nothing installed"
        assert_not_contains "$(logof "$root" systemctl)" "enable" "4 $mode: nothing enabled"
    done
}

# ===========================================================================
# 5. UNSUPPORTED ARCHITECTURE refuses by name, before downloading — the
#    alternative is `Exec format error` or status=203/EXEC an hour later.
# ===========================================================================
case_arch() {
    local root out rc
    root="$(new_env riscv)"
    out="$(run_installer "$root" STUB_UNAME_M=riscv64 --)"; rc=$?
    assert_nonzero "$rc" "5 arch: exits non-zero"
    assert_contains "$out" "riscv64" "5 arch: names the architecture it saw"
    assert_eq "$(count_lines "$(logof "$root" curl)")" "0" "5 arch: refused before any download"
}

# ===========================================================================
# 6. NOT LINUX / NO SYSTEMD / NOT ROOT each refuse with the fix named.
# ===========================================================================
case_refusals() {
    local root out rc
    root="$(new_env darwin)"
    out="$(run_installer "$root" STUB_UNAME_S=Darwin --)"; rc=$?
    assert_nonzero "$rc" "6 darwin: exits non-zero"
    assert_contains "$out" "Shape B" "6 darwin: points at the Mac shape instead"
    assert_eq "$(count_lines "$(logof "$root" curl)")" "0" "6 darwin: no download"

    root="$(new_env nosystemd)"
    out="$(run_installer "$root" STUB_SYSTEMD_STATE=offline --)"; rc=$?
    assert_nonzero "$rc" "6 nosystemd: exits non-zero"
    assert_contains "$out" "systemd is required" "6 nosystemd: names systemd"

    root="$(new_env degraded)"
    out="$(run_installer "$root" STUB_SYSTEMD_STATE=degraded --)"; rc=$?
    assert_eq "$rc" "0" "6 degraded: a degraded systemd (one failed unit somewhere) is still systemd"

    root="$(new_env notroot)"
    out="$(run_installer "$root" STUB_UID=1000 --)"; rc=$?
    assert_nonzero "$rc" "6 notroot: exits non-zero"
    assert_contains "$out" "sudo" "6 notroot: tells the user to re-run with sudo"
    assert_eq "$(count_lines "$(logof "$root" curl)")" "0" "6 notroot: no download"
}

# ===========================================================================
# 7. --domain: Caddy fronted, --public-url set, firewall PRINTED never RUN.
#    Then the flagless re-run the unit header advertises as the upgrade path
#    must keep the origin, or QR pairing silently disappears while the wss://
#    URL keeps working.
# ===========================================================================
case_domain() {
    local root out rc unit snippet caddyfile sysd
    root="$(new_env domain)"
    with_stub "$root" caddy
    with_stub "$root" firewall-cmd
    out="$(run_installer "$root" -- --domain relay.example.com)"; rc=$?
    assert_eq "$rc" "0" "7 domain: exits 0"
    unit="$(cat "$root/etc/systemd/system/irrlichtrelay.service" 2>/dev/null)"
    assert_contains "$unit" "--auth tokens-file --public-url https://relay.example.com" "7 domain: unit carries --public-url with the https origin"
    snippet="$(cat "$root/etc/caddy/irrlichtrelay.caddy" 2>/dev/null)"
    assert_contains "$snippet" "relay.example.com {" "7 domain: Caddy site block for the domain"
    assert_contains "$snippet" "reverse_proxy 127.0.0.1:7839" "7 domain: reverse-proxies to the relay on loopback"
    caddyfile="$(cat "$root/etc/caddy/Caddyfile" 2>/dev/null)"
    assert_contains "$caddyfile" "import $root/etc/caddy/irrlichtrelay.caddy" "7 domain: Caddyfile imports the snippet"
    sysd="$(logof "$root" systemctl)"
    assert_contains "$sysd" "enable --now caddy" "7 domain: Caddy enabled"
    assert_contains "$sysd" "reload caddy" "7 domain: Caddy reloaded"
    assert_contains "$out" "wss://relay.example.com" "7 domain: Mac URL is wss:// on the domain"
    assert_contains "$out" "Pair a phone" "7 domain: offers QR pairing now that there is an origin"
    assert_contains "$out" "firewall-cmd --zone=public --permanent --add-port=443/tcp" "7 domain: prints the firewalld command for this host"
    assert_eq "$(count_lines "$(logof "$root" firewall-cmd)")" "0" "7 domain: NEVER ran firewall-cmd"
    assert_contains "$out" "point relay.example.com at this host" "7 domain: says DNS is still the operator's"
    assert_not_contains "$(logof "$root" curl)" "cloudsmith" "7 domain: did not try to install Caddy when it is already present"

    # Flagless re-run: the upgrade path.
    out="$(run_installer "$root" --)"; rc=$?
    assert_eq "$rc" "0" "7 domain rerun: exits 0"
    unit="$(cat "$root/etc/systemd/system/irrlichtrelay.service" 2>/dev/null)"
    assert_contains "$unit" "--public-url https://relay.example.com" "7 domain rerun: keeps --public-url from the previous install"
    assert_contains "$out" "Keeping the origin from the previous install" "7 domain rerun: says so"
    assert_contains "$out" "wss://relay.example.com" "7 domain rerun: still prints the wss:// URL, not loopback"
    assert_not_contains "$out" "Loopback only" "7 domain rerun: does not claim loopback"
    assert_eq "$(grep -c 'import ' "$root/etc/caddy/Caddyfile")" "1" "7 domain rerun: one Caddyfile import line, not two"

    # An operator's pre-existing Caddyfile is appended to, never replaced.
    root="$(new_env domain-existing)"
    with_stub "$root" caddy
    printf 'example.org {\n    respond "hello"\n}\n' >"$root/etc/caddy/Caddyfile"
    out="$(run_installer "$root" -- --domain relay.example.com)"; rc=$?
    assert_eq "$rc" "0" "7 domain existing: exits 0"
    caddyfile="$(cat "$root/etc/caddy/Caddyfile")"
    assert_contains "$caddyfile" 'respond "hello"' "7 domain existing: the operator's own site block survives"
    assert_contains "$caddyfile" "import $root/etc/caddy/irrlichtrelay.caddy" "7 domain existing: ours is appended"

    # --domain with no Caddy and no known package manager refuses by name
    # rather than guessing at a package manager.
    root="$(new_env domain-nocaddy)"
    out="$(run_installer "$root" -- --domain relay.example.com)"; rc=$?
    assert_nonzero "$rc" "7 domain nocaddy: exits non-zero"
    assert_contains "$out" "Install Caddy yourself" "7 domain nocaddy: names Caddy as the missing piece"

    root="$(new_env both)"
    out="$(run_installer "$root" -- --tailscale --domain x.example.com)"; rc=$?
    assert_nonzero "$rc" "7 both: --domain and --tailscale together refuse"
}

# ===========================================================================
# 8. --tailscale: origin derived from the tailnet name, serve turned on.
# ===========================================================================
case_tailscale() {
    local root out rc unit
    root="$(new_env tailscale)"
    with_tailscale_stub "$root"
    out="$(run_installer "$root" -- --tailscale)"; rc=$?
    assert_eq "$rc" "0" "8 tailscale: exits 0"
    unit="$(cat "$root/etc/systemd/system/irrlichtrelay.service" 2>/dev/null)"
    assert_contains "$unit" "--public-url https://box.tail1234.ts.net" "8 tailscale: unit's --public-url is Self.DNSName without the trailing dot"
    assert_not_contains "$unit" "other.tail1234" "8 tailscale: did not pick a peer's name"
    assert_contains "$(logof "$root" tailscale)" "serve --bg 7839" "8 tailscale: tailscale serve on the relay port"
    assert_contains "$out" "wss://box.tail1234.ts.net" "8 tailscale: Mac URL is the tailnet name"
    assert_file_absent "$root/etc/caddy/irrlichtrelay.caddy" "8 tailscale: no Caddy"

    root="$(new_env tailscale-missing)"
    out="$(run_installer "$root" -- --tailscale)"; rc=$?
    assert_nonzero "$rc" "8 tailscale missing: exits non-zero"
    assert_contains "$out" "tailscale CLI" "8 tailscale missing: names the CLI"
}

# ===========================================================================
# 9. --uninstall reverses what an install wrote, leaves the operator's own
#    Caddy config and the state dir alone; --purge removes the state too.
# ===========================================================================
case_uninstall() {
    local root out rc sysd caddyfile
    root="$(new_env uninstall)"
    with_stub "$root" caddy
    printf 'example.org {\n    respond "hello"\n}\n' >"$root/etc/caddy/Caddyfile"
    out="$(run_installer "$root" -- --domain relay.example.com)"; rc=$?
    assert_eq "$rc" "0" "9 uninstall: install first"
    : >"$root/log/systemctl.log"
    out="$(run_installer "$root" -- --uninstall)"; rc=$?
    assert_eq "$rc" "0" "9 uninstall: exits 0"
    sysd="$(logof "$root" systemctl)"
    assert_contains "$sysd" "disable --now irrlichtrelay" "9 uninstall: service disabled and stopped"
    assert_contains "$sysd" "daemon-reload" "9 uninstall: daemon-reload after removing the unit"
    assert_file_absent "$root/etc/systemd/system/irrlichtrelay.service" "9 uninstall: unit removed"
    assert_file_absent "$root/opt/irrlichtrelay" "9 uninstall: prefix removed"
    assert_file_absent "$root/etc/caddy/irrlichtrelay.caddy" "9 uninstall: Caddy snippet removed"
    assert_file_present "$root/etc/caddy/Caddyfile" "9 uninstall: Caddyfile still present"
    caddyfile="$(cat "$root/etc/caddy/Caddyfile" 2>/dev/null)"
    assert_not_contains "$caddyfile" "irrlichtrelay" "9 uninstall: Caddyfile import and marker stripped"
    assert_contains "$caddyfile" 'respond "hello"' "9 uninstall: the operator's own site block survives the uninstall"
    assert_contains "$sysd" "reload caddy" "9 uninstall: Caddy reloaded after the site went"
    assert_file_present "$root/var/lib/irrlichtrelay/tokens.json" "9 uninstall: state dir KEPT (tokens, signing key, paired phones)"
    assert_contains "$out" "--purge" "9 uninstall: says how to remove the state too"
    assert_eq "$(count_lines "$(logof "$root" userdel)")" "0" "9 uninstall: user kept with the state"

    out="$(run_installer "$root" -- --uninstall --purge)"; rc=$?
    assert_eq "$rc" "0" "9 purge: exits 0"
    assert_file_absent "$root/var/lib/irrlichtrelay" "9 purge: state dir removed"
    assert_contains "$(logof "$root" userdel)" "irrlichtrelay" "9 purge: service user removed"

    out="$(run_installer "$root" -- --purge)"; rc=$?
    assert_nonzero "$rc" "9 purge alone: refuses without --uninstall"
}

# ===========================================================================
# 10. A relay that never answers the health check is reported as such: the
#     token still prints (the operator needs it), but no success banner and a
#     non-zero exit. "Installed and running" when it is not is the one line
#     nobody re-checks.
# ===========================================================================
case_health() {
    local root out rc
    root="$(new_env health)"
    out="$(run_installer "$root" STUB_HEALTH_EXIT=7 --)"; rc=$?
    assert_nonzero "$rc" "10 health: exits non-zero when the relay never answered"
    assert_contains "$out" "not answering" "10 health: says the relay is not answering"
    assert_not_contains "$out" "installed and running" "10 health: no success banner"
    assert_contains "$out" "journalctl -u irrlichtrelay" "10 health: points at the journal"
    assert_contains "$out" "stub-token-4f3a9c" "10 health: the token is still printed (it was issued)"
    assert_file_present "$root/etc/systemd/system/irrlichtrelay.service" "10 health: the unit stays (the operator debugs, not reinstalls)"
}

# ===========================================================================
# 11. --version accepts the tag as pasted from the releases page.
# ===========================================================================
case_version() {
    local root out rc curl_log
    root="$(new_env version)"
    out="$(run_installer "$root" -- --version v0.6.3)"; rc=$?
    assert_eq "$rc" "0" "11 version: exits 0 with a v-prefixed --version"
    curl_log="$(logof "$root" curl)"
    assert_contains "$curl_log" "releases/download/v0.6.3/" "11 version: download path has one v"
    assert_not_contains "$curl_log" "vv0.6.3" "11 version: not two"
    assert_not_contains "$curl_log" "releases/latest" "11 version: an explicit version skips the latest probe"
}

# ===========================================================================
# 12. The installer must stay POSIX-sh clean — it reaches users as
#     `curl | sh`, which on Debian and Ubuntu is dash. A parser check is a
#     floor (see install-uninstall_test.sh check 9); tools/posix-lint.sh is
#     the gate, and it picks this file up by its shebang.
# ===========================================================================
case_syntax() {
    if [[ -n "$POSIX_SH" ]]; then
        if "$POSIX_SH" -n "$RELAY_SH" 2>/dev/null; then
            pass "12 syntax: site/relay.sh parses under $POSIX_SH (real POSIX shell; the cases above also ran under it)"
        else
            fail "12 syntax: site/relay.sh parses under $POSIX_SH"
        fi
    else
        if sh -n "$RELAY_SH" 2>/dev/null; then
            pass "12 syntax: site/relay.sh parses under /bin/sh (NO dash here — syntax only, and the cases above ran under bash-as-sh)"
        else
            fail "12 syntax: site/relay.sh parses under /bin/sh"
        fi
    fi
    assert_eq "$(head -n 1 "$RELAY_SH")" "#!/bin/sh" "12 shebang: #!/bin/sh, so tools/posix-lint.sh scopes it in"
}

# ---------------------------------------------------------------------------
# Run the cases (all, or the one ONLY_CASE names).
ALL_CASES="happy badsum layout arch refusals domain tailscale uninstall health version syntax"
ran_cases=0
for c in $ALL_CASES; do
    if [[ -z "$ONLY_CASE" || "$ONLY_CASE" == "$c" ]]; then
        "case_$c"
        ran_cases=$((ran_cases + 1))
    fi
done
if [[ "$ran_cases" -eq 0 ]]; then
    echo "$NAME: ONLY_CASE=$ONLY_CASE matches no case (have: $ALL_CASES)" >&2
    exit 1
fi

# ===========================================================================
# 13. MUTATIONS. Each entry breaks one property of the installer in a copy
#     and requires the named case to go red on the named assertion. A mutant
#     that does not change the file, does not parse, or stays green FAILS.
#     Skipped inside a mutant child (ONLY_CASE set) so this does not recurse.
# ===========================================================================
mutate() {
    local name="$1" case_name="$2" expr="$3" expect="$4"
    local copy="$WORK/mutants/$name.sh" out rc
    mkdir -p "$WORK/mutants"
    sed -e "$expr" "$RELAY_SH" >"$copy"
    if cmp -s "$RELAY_SH" "$copy"; then
        fail "13 mutation $name: the sed expression matched nothing (installer text drifted; fix the mutation)"
        return
    fi
    if ! "$RUNNER" -n "$copy" 2>/dev/null; then
        fail "13 mutation $name: mutant does not parse, so a red would prove nothing"
        return
    fi
    out="$(RELAY_SH="$copy" ONLY_CASE="$case_name" bash "$0" 2>&1)"; rc=$?
    if [[ $rc -ne 0 ]] && printf '%s' "$out" | grep -q -F "FAIL: $expect"; then
        pass "13 mutation $name: case $case_name went red on [$expect]"
    else
        fail "13 mutation $name: expected case $case_name to fail on [$expect]" "rc=$rc; FAIL lines: $(printf '%s' "$out" | grep '^FAIL' | head -3 | tr '\n' '|')"
    fi
}

if [[ -z "$ONLY_CASE" ]]; then
    # Without the bin/ check a nobin tarball gets copied into the prefix
    # before the missing binary trips a later step, so "nothing installed" is
    # the assertion that sees it, not the exit code.
    mutate drop-bin-check      layout    '/Unexpected tarball layout: bin\//s/.*/    || true/'                        "4 nobin: nothing installed"
    mutate drop-web-check      layout    '/Unexpected tarball layout: Resources/s/.*/    || true/'                    "4 noweb: exits non-zero"
    mutate skip-checksum       badsum    '/^sha256_verify "\$WORK_DIR" "\$ASSET" || fail/s/.*/true/'                  "3 badsum: exits non-zero"
    mutate drop-proto-pin      happy     '/^fetch() {/s/.*/fetch() { curl -fsSL "$@"; }/'                             "1 happy: every release download carried the https protocol pin"
    mutate always-new-token    happy     '/^if \[ -s "\$STATE_DIR\/tokens.json" \]/s/.*/if false; then/'             "2 rerun: says it kept the tokens"
    mutate run-firewall        domain    '/2\. Firewall: open TCP 443/s/.*/    firewall-cmd --add-port=443\/tcp >\/dev\/null 2>\&1 || true/' "7 domain: NEVER ran firewall-cmd"
    mutate forget-origin       domain    '/^    PUBLIC_URL=\$(sed -n/d'                                                "7 domain rerun: keeps --public-url from the previous install"
    mutate keep-unit           uninstall '/^        rm -f "\$UNIT_PATH"$/d'                                            "9 uninstall: unit removed"
    mutate delete-caddyfile    uninstall '/cat "\$_tmp" >"\$CADDYFILE"/s/.*/            rm -f "$CADDYFILE"/'         "9 uninstall: Caddyfile still present"
    mutate green-when-down     health    '/^\[ "\$UP" -eq 1 \] || exit 1$/s/.*/true/'                                 "10 health: exits non-zero when the relay never answered"
    mutate arch-fallthrough    arch      '/Unsupported architecture/s/.*/    *) ARCH="amd64" ;;/'                      "5 arch: exits non-zero"
    mutate drop-root-check     refusals  '/^\[ "\$(id -u)" -eq 0 \] || fail/d'                                         "6 notroot: exits non-zero"
    mutate peer-dnsname        tailscale 's/| head -n 1 \\$/| tail -n 1 \\/'                                           "8 tailscale: unit's --public-url is Self.DNSName without the trailing dot"
    mutate keep-v-prefix       version   '/^VERSION="\${VERSION#v}"$/d'                                                "11 version: not two"
fi

if [ "$fails" -eq 0 ]; then
    echo "$NAME: ALL PASS"
else
    echo "$NAME: $fails FAILED" >&2
    exit 1
fi
