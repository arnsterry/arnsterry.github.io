#!/bin/bash
# --------------------------------------------------------------------------------------------
# PinoyChat ZNC installer
# --------------------------------------------------------------------------------------------
# Usage (as your normal user, NOT root; it uses sudo when needed):
#       bash <(curl -fsSL https://bot.pinoychat.fun/znc.sh)
#
# What it does
#   1. installs ZNC: the LATEST stable release compiled from source (default),
#      or the older apt version if you answer n or the build fails
#   2. asks a few questions and writes ~/znc-NAME/configs/znc.conf
#      (SSL listener for IRC *and* the web portal, webadmin loaded, user = admin)
#   3. creates a systemd service  znc-NAME  (starts on boot, restarts if it dies)
#   4. optional: installs an ident server (oidentd) so IRC shows your ident instead of ~user
#   5. optional: runs that ZNC inside its OWN Cloudflare WARP tunnel (own IPv6/IPv4)
#      - the tunnel tools come from installer.sh (WARP_SOURCE below), nothing is duplicated
#      - a small forwarder (znc-fwd-NAME) lets your IRC client still reach the ZNC port
#
# Debian / Ubuntu / Raspberry Pi OS with systemd only.
#
# Changes in this version
#   - FIX: global "LoadModule = webadmin" was missing, so the web portal showed a blank page
#   - FIX: listener now has AllowIRC/AllowWeb/URIPrefix set explicitly
#   - FIX: user is Admin so the whole web portal can be used
#   - FIX: an empty znc.pem is detected (it makes ZNC drop every TLS handshake)
#   - NEW: builds the latest ZNC from znc.in (apt on Ubuntu 20.04 only has 1.7.5)
#   - FIX: the user is Admin, so "Network number limit reached" (MaxNetworks) no longer happens
#   - NEW: optional ident server (oidentd), opens ufw ports if ufw is active
#   - NEW: summary shows the real public IP, the web portal URL and a live web check
# --------------------------------------------------------------------------------------------

set -u

WARP_SOURCE="https://bot.pinoychat.fun/installer.sh"
PORT_MIN=10000
PORT_MAX=60000

WANT_IDENT="0"
WANT_LATEST="1"
ZNC_BIN=""
ZNC_FALLBACK_VER="1.10.3"   # used only if znc.in/releases cannot be read
IDENT_STATE="not installed"
WARP_NS=""
WARP_ADDR=""

# -- string formatters (same look as installer.sh)
if [[ -t 1 ]]; then
    tty_escape() { printf "\033[%sm" "$1"; }
else
    tty_escape() { :; }
fi
tty_mkbold() { tty_escape "1;$1"; }
tty_red="$(tty_mkbold 31)"
tty_green="$(tty_mkbold 32)"
tty_yellow="$(tty_mkbold 33)"
tty_blue="$(tty_mkbold 34)"
tty_bold="$(tty_mkbold 39)"
tty_reset="$(tty_escape 0)"

shell_join() {
    local arg
    printf "%s" "$1"
    shift
    for arg in "$@"; do
        printf " %s" "${arg// /\ }"
    done
}
chomp() { printf "%s" "${1/"$'\n'"/}"; }
ohai() { printf "${tty_blue}==>${tty_bold} %s${tty_reset}\n" "$(shell_join "$@")"; }
warn() { printf "${tty_yellow}Warning${tty_reset}: %s\n" "$(chomp "$1")" >&2; }
abort() { printf "%s\n" "$@" >&2; exit 1; }
ring_bell() { if [[ -t 1 ]]; then printf "\a"; fi; }
check_sudo() {
    command -v sudo >/dev/null 2>&1 || abort "${tty_red}Error:${tty_reset} sudo is required."
}

ask() { # ask VAR "question" "default" "regex" "error text"
    local var="$1" q="$2" def="$3" re="$4" err="$5" v
    while true; do
        if [ -n "$def" ]; then read -r -p "    $q [$def]: " v; v="${v:-$def}"; else read -r -p "    $q: " v; fi
        if printf '%s' "$v" | grep -qE "$re"; then printf -v "$var" '%s' "$v"; return; fi
        echo "    ${tty_yellow}$err${tty_reset}"
    done
}

# ---------------------------------------------------------------------------
# Checks and packages
# ---------------------------------------------------------------------------

preflight() {
    [ -n "${BASH_VERSION:-}" ] || abort "Bash is required to run this script."
    [ "$(id -u)" != "0" ] || abort "${tty_red}Error:${tty_reset} do not run this as root. Log in as your normal user (the script uses sudo when needed)."
    command -v apt-get >/dev/null 2>&1 || abort "${tty_red}Error:${tty_reset} this installer needs Debian/Ubuntu (apt)."
    command -v systemctl >/dev/null 2>&1 || abort "${tty_red}Error:${tty_reset} this installer needs systemd."
    check_sudo
    sudo -v || abort "${tty_red}Error:${tty_reset} sudo failed."
}

install_packages() {
    ohai "Installing packages (socat, openssl, curl)..."
    sudo apt-get update -qq >/dev/null 2>&1 || true
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y socat openssl curl ca-certificates iproute2 \
        || abort "${tty_red}Error:${tty_reset} package install failed."
}

# ---------------------------------------------------------------------------
# ZNC itself: latest release from source, or apt as fallback
# ---------------------------------------------------------------------------

znc_latest_version() {
    local page v
    page="$(curl -fsSL -m 15 https://znc.in/releases/ 2>/dev/null)" || page=""
    v="$(printf '%s' "$page" | grep -oE 'znc-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz' \
        | sed -E 's/^znc-//; s/\.tar\.gz$//' | sort -V | tail -1)"
    printf '%s' "${v:-$ZNC_FALLBACK_VER}"
}

build_znc_latest() {
    local ver tmp jobs mem rc
    ver="$(znc_latest_version)"

    if [ -x /usr/local/bin/znc ] && /usr/local/bin/znc --version 2>/dev/null | grep -qF "ZNC ${ver} "; then
        ohai "ZNC ${ver} is already installed in /usr/local - reusing it."
        return 0
    fi

    ohai "Building ZNC ${ver} from source (10-20 minutes on a small VPS, please wait)..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential cmake pkg-config \
        libssl-dev libicu-dev zlib1g-dev gettext >/dev/null 2>&1 \
        || { warn "Could not install the build tools."; return 1; }
    # optional: lets ZNC use Argon2 password hashes
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y libargon2-dev >/dev/null 2>&1 || true

    # small VPS: one job at a time, or the compiler runs out of RAM
    mem="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null)"
    jobs=1
    if [ "${mem:-0}" -ge 1500000 ]; then
        jobs="$(nproc 2>/dev/null || echo 1)"
        [ "$jobs" -gt 2 ] && jobs=2
    fi

    tmp="$(mktemp -d)" || return 1
    (
        set -e
        cd "$tmp"
        # the newest release lives in /releases/, older ones are moved to /releases/archive/
        curl -fsSL -o znc.tar.gz "https://znc.in/releases/znc-${ver}.tar.gz" \
            || curl -fsSL -o znc.tar.gz "https://znc.in/releases/archive/znc-${ver}.tar.gz"
        tar xf znc.tar.gz
        cd "znc-${ver}"
        mkdir -p build && cd build
        cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local >"$tmp/build.log" 2>&1
        make -j"$jobs" >>"$tmp/build.log" 2>&1
        sudo -v   # the build can outlast the sudo timestamp
        sudo make install >>"$tmp/build.log" 2>&1
    )
    rc=$?
    if [ "$rc" -ne 0 ]; then
        warn "ZNC ${ver} failed to build. Last lines of the log:"
        tail -n 15 "$tmp/build.log" >&2 2>/dev/null
        rm -rf "$tmp"
        return 1
    fi
    rm -rf "$tmp"
    [ -x /usr/local/bin/znc ] || return 1
    return 0
}

install_znc() {
    ZNC_BIN=""
    if [ "$WANT_LATEST" = "1" ]; then
        if build_znc_latest; then
            ZNC_BIN="/usr/local/bin/znc"
        else
            warn "Source build failed - falling back to the (older) ZNC from apt."
        fi
    fi
    if [ -z "$ZNC_BIN" ]; then
        ohai "Installing ZNC from apt..."
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y znc \
            || abort "${tty_red}Error:${tty_reset} znc install failed."
        ZNC_BIN="$(command -v znc)"
    fi
    [ -x "$ZNC_BIN" ] || abort "${tty_red}Error:${tty_reset} znc is not installed."
    ohai "Using $("$ZNC_BIN" --version 2>/dev/null | head -1)"
}

# ---------------------------------------------------------------------------
# Questions
# ---------------------------------------------------------------------------

random_free_port() {
    local p
    for _ in $(seq 1 60); do
        p="$(shuf -i "${PORT_MIN}-${PORT_MAX}" -n 1)"
        if ! ss -tln 2>/dev/null | grep -q ":$p "; then echo "$p"; return 0; fi
    done
    return 1
}

collect_settings() {
    echo
    echo "    ${tty_green}============================================================${tty_reset}"
    echo "    ${tty_bold}  ZNC bouncer setup${tty_reset}"
    echo "    ${tty_green}============================================================${tty_reset}"
    echo
    ask ZUSER   "ZNC username"                 "$(whoami)" '^[A-Za-z][A-Za-z0-9_-]{0,31}$' "Letters, digits, - and _ only, starting with a letter."
    while true; do
        read -r -s -p "    ZNC password (min 8 characters, hidden): " P1; echo
        read -r -s -p "    Repeat the password: " P2; echo
        [ "${#P1}" -ge 8 ] && [ "$P1" = "$P2" ] && break
        echo "    ${tty_yellow}Passwords must match and have at least 8 characters.${tty_reset}"
    done
    ask NICK    "IRC nickname"                 "$ZUSER"    '^[A-Za-z_][A-Za-z0-9_-]{0,29}$' "Letters, digits, - and _ only."
    ask REAL    "Real name"                    "$NICK"     '^[A-Za-z0-9 ._-]{1,50}$'        "Letters, digits, spaces, . _ - only."
    ask NETNAME "Network name"                 "Undernet"  '^[A-Za-z0-9_-]{1,30}$'          "Letters, digits, - and _ only."
    ask SERVER  "IRC server"                   "irc.undernet.org" '^[A-Za-z0-9.-]{3,80}$'   "A host name like irc.undernet.org"
    ask SPORT   "IRC server port"              "6667"      '^[0-9]{2,5}$'                   "A port number."
    ask SSLIRC  "SSL to the IRC server? (y/n)" "n"         '^[YyNn]$'                       "Answer y or n."
    read -r -p "    Channels to join (e.g. #bislig #chat, or empty): " CHANS

    local defport
    defport="$(random_free_port)" || abort "Could not find a free port."
    ask PORT    "Port for your IRC client / web portal" "$defport" '^[0-9]{2,5}$' "A port number."
    if ss -tln 2>/dev/null | grep -q ":$PORT "; then
        abort "${tty_red}Error:${tty_reset} port $PORT is already in use on this machine. Run again and pick another."
    fi

    INST="$(printf '%s' "$ZUSER" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9_-')"
    [ -n "$INST" ] || INST="znc"
    D="$HOME/znc-$INST"
    SVC="znc-$INST"
    [ ! -e "$D" ] || abort "${tty_red}Error:${tty_reset} $D already exists. Choose another ZNC username or remove that folder."
    [ ! -f "/etc/systemd/system/$SVC.service" ] || abort "${tty_red}Error:${tty_reset} service $SVC already exists. Choose another ZNC username."

    echo
    echo "      apt only has an old ZNC on many systems (Ubuntu 20.04: 1.7.5). Compiling gives the"
    echo "      latest stable release with all security fixes, but takes 10-20 minutes."
    ask LATESTANS "Install the LATEST ZNC from source? (y/n)" "y" '^[YyNn]$' "Answer y or n."
    case "$LATESTANS" in y|Y) WANT_LATEST="1" ;; *) WANT_LATEST="0" ;; esac

    USE_WARP="0"
    echo
    echo "    ${tty_green}============================================================${tty_reset}"
    ohai "Run this ZNC inside its own ${tty_green}Cloudflare WARP${tty_reset} tunnel?"
    echo "    ${tty_green}============================================================${tty_reset}"
    echo
    echo "      Hides this machine's IP and gives the ZNC its own address on IRC."
    echo "      ${tty_yellow}Caution:${tty_reset} WARP addresses are shared by many people. Undernet bans them for"
    echo "      'excessive connections' (1 day), and then the ZNC cannot connect."
    echo "      A clean ident (no ~) is not possible through WARP."
    echo
    ask WARPANS "Use WARP? (y/n)" "n" '^[YyNn]$' "Answer y or n."
    case "$WARPANS" in y|Y) USE_WARP="1" ;; esac

    WANT_IDENT="0"
    echo
    if [ "$USE_WARP" = "1" ]; then
        echo "    Ident server skipped: it cannot work through a WARP tunnel."
    else
        echo "    ${tty_green}============================================================${tty_reset}"
        ohai "Install an ${tty_green}ident server${tty_reset} (oidentd)?"
        echo "    ${tty_green}============================================================${tty_reset}"
        echo
        echo "      Without it, IRC servers show you as ~${ZUSER}. With it, the ident is a clean '${ZUSER}'."
        echo "      It listens on TCP port 113. One ident is used for every ZNC under this Linux user."
        echo
        ask IDANS "Install ident server? (y/n)" "y" '^[YyNn]$' "Answer y or n."
        case "$IDANS" in y|Y) WANT_IDENT="1" ;; esac
    fi
}

# ---------------------------------------------------------------------------
# WARP toolkit (taken from installer.sh, so there is only one copy to maintain)
# ---------------------------------------------------------------------------

ensure_warp() {
    if command -v warpns-new >/dev/null 2>&1 && command -v warpns-wait >/dev/null 2>&1 \
       && command -v warpns-bind >/dev/null 2>&1 && command -v warpns-name >/dev/null 2>&1 \
       && command -v wgcf >/dev/null 2>&1; then
        return 0
    fi
    ohai "Loading the WARP toolkit from ${WARP_SOURCE}"
    local src code
    src="$(curl -fsSL "${WARP_SOURCE}")" || { warn "Could not download ${WARP_SOURCE}"; return 1; }
    code="$(printf '%s\n' "$src" | awk '
        /^(warp_system_warp_check|install_warp_toolkit)\(\) \{/ { p = 1 }
        p { print }
        p && /^}/ { p = 0 }')"
    if ! printf '%s\n' "$code" | grep -q '^install_warp_toolkit() {'; then
        warn "install_warp_toolkit was not found in ${WARP_SOURCE}"
        return 1
    fi
    eval "$code"
    install_warp_toolkit
}

# ---------------------------------------------------------------------------
# ZNC config + certificate
# ---------------------------------------------------------------------------

write_znc_config() {
    local ver srv chan_lines="" c salt hash l6

    ver="$("$ZNC_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
    [ -n "$ver" ] || ver="1.8.0"

    case "$SSLIRC" in y|Y) srv="$SERVER +$SPORT" ;; *) srv="$SERVER $SPORT" ;; esac

    for c in $(printf '%s' "$CHANS" | tr ',' ' '); do
        printf '%s' "$c" | grep -qE '^[#&][A-Za-z0-9_.#&-]{1,50}$' || { warn "Skipping invalid channel '$c'"; continue; }
        chan_lines="${chan_lines}        <Chan $c>
        </Chan>
"
    done

    # IPv4 only when: inside a WARP tunnel (the forwarder connects to 127.0.0.1),
    # or when this machine has no IPv6 (ZNC refuses to start if it cannot bind IPv6)
    if [ "$USE_WARP" = "1" ] || [ ! -e /proc/net/if_inet6 ]; then l6="false"; else l6="true"; fi

    mkdir -p "$D/configs" || abort "Could not create $D"
    chmod 700 "$D"
    salt="$(head -c 60 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)"
    hash="$(printf '%s%s' "$P1" "$salt" | sha256sum | cut -d' ' -f1)"
    # webadmin MUST be loaded globally (before the listener) or the web portal is blank.
    cat > "$D/configs/znc.conf" <<ZEOF
Version = $ver
LoadModule = webadmin

<Listener l>
    Port = $PORT
    IPv4 = true
    IPv6 = $l6
    SSL = true
    AllowIRC = true
    AllowWeb = true
    URIPrefix = /
</Listener>

<User $ZUSER>
    Admin = true
    Nick = $NICK
    AltNick = ${NICK}_
    Ident = $ZUSER
    RealName = $REAL
    LoadModule = chansaver
    <Pass password>
        Method = SHA256
        Hash = $hash
        Salt = $salt
    </Pass>
    <Network $NETNAME>
        Server = $srv
${chan_lines}    </Network>
</User>
ZEOF
    chmod 600 "$D/configs/znc.conf"
    unset P1 P2 hash salt

    printf '    Creating the certificate ... '
    if "$ZNC_BIN" --datadir="$D" --makepem >/dev/null 2>&1 && [ -s "$D/znc.pem" ]; then
        echo "done"
    else
        rm -f "$D/znc.pem"
        echo "failed (ZNC will have no SSL certificate; retry: $ZNC_BIN --datadir=$D --makepem)"
    fi
}

# ---------------------------------------------------------------------------
# systemd service
# ---------------------------------------------------------------------------

write_service() {
    local zbin grp
    zbin="$ZNC_BIN"
    grp="$(id -gn)"
    ohai "Creating systemd service: ${tty_green}${SVC}${tty_reset}"
    sudo tee "/etc/systemd/system/${SVC}.service" >/dev/null <<SVCEOF
[Unit]
Description=ZNC IRC bouncer - $INST
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$(whoami)
Group=$grp
ExecStart=$zbin -f --datadir=$D
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SVCEOF
    sudo systemctl daemon-reload
    sudo systemctl enable "$SVC" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Ident server (oidentd): replies with a clean ident for this Linux user
# ---------------------------------------------------------------------------

setup_ident() {
    local me cf marker
    me="$(whoami)"
    cf="/etc/oidentd.conf"
    marker="# znc-installer: user ${me}"

    ohai "Installing the ident server (oidentd)..."

    # port 113 already taken by something that is not oidentd -> do not fight it
    if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE '[:.]113$' && ! pgrep -x oidentd >/dev/null 2>&1; then
        warn "Port 113 is already used by another ident service. oidentd was NOT installed."
        IDENT_STATE="skipped (port 113 busy)"
        return 0
    fi

    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y oidentd >/dev/null 2>&1 \
        || { warn "Could not install oidentd."; IDENT_STATE="failed (apt install)"; return 0; }

    sudo touch "$cf"
    if sudo grep -qF "$marker" "$cf"; then
        warn "An ident rule for Linux user '${me}' already exists in ${cf}; keeping it."
    else
        sudo tee -a "$cf" >/dev/null <<IDEOF

${marker}
user "${me}" {
    default {
        allow spoof
        force reply "${ZUSER}"
    }
}
IDEOF
    fi

    sudo systemctl enable oidentd >/dev/null 2>&1
    sudo systemctl restart oidentd >/dev/null 2>&1
    sleep 1
    if sudo systemctl is-active --quiet oidentd; then
        IDENT_STATE="oidentd running on port 113 (ident: ${ZUSER})"
    else
        warn "oidentd did not start. Check: sudo journalctl -u oidentd -n 30"
        IDENT_STATE="installed but NOT running"
    fi
}

# ---------------------------------------------------------------------------
# Firewall (only touches ufw, and only if it is active)
# ---------------------------------------------------------------------------

open_firewall() {
    command -v ufw >/dev/null 2>&1 || return 0
    sudo ufw status 2>/dev/null | grep -q "^Status: active" || return 0
    ohai "ufw is active - opening TCP ${PORT}$([ "$WANT_IDENT" = "1" ] && echo ' and 113')"
    sudo ufw allow "${PORT}/tcp" >/dev/null 2>&1 || warn "Could not open ${PORT}/tcp in ufw."
    if [ "$WANT_IDENT" = "1" ]; then
        sudo ufw allow 113/tcp >/dev/null 2>&1 || warn "Could not open 113/tcp in ufw."
    fi
}

# ---------------------------------------------------------------------------
# WARP: put the ZNC inside its tunnel + forward the client port into it
# ---------------------------------------------------------------------------

setup_warp_znc() {
    local ip_bin socat_bin listen_addr
    if [ -e /proc/net/if_inet6 ]; then
        listen_addr="TCP6-LISTEN:${PORT},fork,reuseaddr,ipv6only=0"
    else
        listen_addr="TCP4-LISTEN:${PORT},fork,reuseaddr"
    fi
    ip_bin="$(command -v ip)"
    socat_bin="$(command -v socat)"
    [ -n "$socat_bin" ] || { warn "socat is missing"; return 1; }

    WARP_NS="$(warpns-name "znc${INST}")"
    ohai "Preparing private WARP tunnel ${tty_green}${WARP_NS}${tty_reset} for ${tty_green}${SVC}${tty_reset}..."
    sudo sh -c "[ -f /etc/warpns/${WARP_NS}.conf ] || warpns-new ${WARP_NS}" || { warn "Could not create the tunnel."; return 1; }
    WARP_ADDR="$(sudo warpns-wait "${WARP_NS}")" || { warn "The tunnel did not come up. The ZNC was NOT started."; return 1; }
    ohai "Tunnel IPv6: ${tty_green}${WARP_ADDR}${tty_reset}"

    # the ZNC now runs inside the tunnel (warpns-bind also restarts the service)
    sudo warpns-bind "${SVC}" "${WARP_NS}" || { warn "Could not attach ${SVC} to the tunnel."; return 1; }

    # forwarder: host port -> port inside the tunnel, so your IRC client can still connect
    sudo tee /usr/local/bin/znc-ns-connect >/dev/null <<ENTEOF
#!/bin/bash
# usage: znc-ns-connect NAMESPACE PORT -> connects stdin/stdout to 127.0.0.1:PORT inside that namespace
exec ${ip_bin} netns exec "\$1" ${socat_bin} STDIO "TCP:127.0.0.1:\$2"
ENTEOF
    sudo chmod 755 /usr/local/bin/znc-ns-connect

    sudo tee "/etc/systemd/system/znc-fwd-${INST}.service" >/dev/null <<FWDEOF
[Unit]
Description=ZNC ${INST}: port ${PORT} forwarded into WARP tunnel ${WARP_NS}
After=wgns@${WARP_NS}.service ${SVC}.service
Wants=wgns@${WARP_NS}.service

[Service]
ExecStart=${socat_bin} ${listen_addr} EXEC:"/usr/local/bin/znc-ns-connect ${WARP_NS} ${PORT}"
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
FWDEOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now "znc-fwd-${INST}" >/dev/null 2>&1
    return 0
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

public_ip() {
    local pip
    pip="$(curl -4 -fsS -m 5 https://ifconfig.me 2>/dev/null)"
    if ! printf '%s' "$pip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        pip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
    fi
    printf '%s' "$pip"
}

show_summary() {
    local host pip code web="not answering yet"
    pip="$(public_ip)"
    host="${pip:-$(hostname -f 2>/dev/null)}"

    # the web portal needs a few seconds after (re)start; plain GET, because HEAD hangs on ZNC
    for _ in 1 2 3 4 5 6; do
        code="$(curl -sk -m 5 -o /dev/null -w '%{http_code}' "https://127.0.0.1:${PORT}/login" 2>/dev/null)"
        case "$code" in 200|302) web="OK"; break ;; esac
        sleep 2
    done

    echo
    echo "    ${tty_green}============================================================${tty_reset}"
    echo "    ${tty_bold}PinoyChat ZNC Installation Complete!${tty_reset}"
    echo "    ${tty_green}============================================================${tty_reset}"
    echo
    echo "    ${tty_bold}Connect your IRC client to:${tty_reset}"
    echo "      Server   : ${tty_green}${host:-this server}${tty_reset}   (or this machine's IP / domain)"
    echo "      Port     : ${tty_green}${PORT}${tty_reset}   (SSL on)"
    echo "      Username : ${tty_green}${ZUSER}/${NETNAME}${tty_reset}"
    echo "      Password : the one you just chose"
    echo
    echo "    ${tty_bold}Web portal:${tty_reset}"
    echo "      URL      : ${tty_green}https://${host:-YOUR_IP}:${PORT}/${tty_reset}   (type https://, accept the certificate warning)"
    echo "      Username : ${tty_green}${ZUSER}${tty_reset}   (without /${NETNAME})"
    echo "      Check    : ${web}"
    echo
    echo "    ${tty_bold}Config    :${tty_reset} ${D}/configs/znc.conf"
    if [ "$USE_WARP" = "1" ]; then
        echo "    ${tty_bold}WARP IPv6 :${tty_reset} ${WARP_ADDR:-unknown}   (tunnel ${WARP_NS:-?})"
    fi
    echo "    ${tty_bold}ZNC       :${tty_reset} $("$ZNC_BIN" --version 2>/dev/null | head -1)"
    echo "    ${tty_bold}Ident     :${tty_reset} ${IDENT_STATE}"
    if sudo systemctl is-active --quiet "$SVC"; then
        echo "    ${tty_bold}Status    :${tty_reset} ${tty_green}Running${tty_reset}"
    else
        echo "    ${tty_bold}Status    :${tty_reset} ${tty_red}not running${tty_reset}  - check: sudo journalctl -u ${SVC} -n 30"
    fi
    echo
    echo "    ${tty_bold}Manage:${tty_reset}"
    echo "      ${tty_green}sudo systemctl status  ${SVC}${tty_reset}"
    echo "      ${tty_green}sudo systemctl restart ${SVC}${tty_reset}"
    echo "      ${tty_green}sudo journalctl -u ${SVC} -n 40${tty_reset}"
    echo
    echo "    If you cannot connect from outside, allow TCP port ${PORT}$([ "$WANT_IDENT" = "1" ] && echo ' (and 113 for ident)') in your"
    echo "    VPS provider's firewall / security group panel too."
    echo
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    echo
    echo "    ${tty_green}============================================================${tty_reset}"
    echo "    ${tty_bold}  PinoyChat ZNC Installer${tty_reset}"
    echo "    ${tty_green}============================================================${tty_reset}"
    echo
    preflight
    install_packages
    collect_settings
    install_znc

    if [ "$USE_WARP" = "1" ]; then
        if ! ensure_warp; then
            ring_bell
            warn "WARP setup failed - continuing WITHOUT WARP (the ZNC will use this machine's own IP)."
            USE_WARP="0"
        fi
    fi

    write_znc_config
    write_service
    [ "$WANT_IDENT" = "1" ] && setup_ident
    open_firewall

    if [ "$USE_WARP" = "1" ]; then
        if ! setup_warp_znc; then
            ring_bell
            warn "WARP failed. ${SVC} is created but NOT started (it would show your real IP)."
            warn "Fix the tunnel, then run:  sudo warpns-bind ${SVC} ${WARP_NS:-NAME}"
        fi
    else
        sudo systemctl start "$SVC"
    fi

    show_summary
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
