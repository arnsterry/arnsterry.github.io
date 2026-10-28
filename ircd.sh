#!/bin/bash
#
# Universal IRCd (ircu/NetIRC) Installer - works for ANY network
# Installs to: $HOME/ircd
#
# Modes:
#   1) Standalone / first server (hub) - no uplink, others link to you
#   2) Leaf server - links to an existing hub
#
# Non-interactive use: pre-set any variable below in the environment
# and that question is skipped, e.g.
#   NETWORK_NAME=MyNet DOMAIN=mynet.org SERVER_NAME=irc.mynet.org ./install_ircd.sh
#
set -e

INSTALL_PATH="${INSTALL_PATH:-$HOME/ircd}"

# ---------- helpers ----------
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

# ask VAR "Prompt" "default"   (skipped if VAR already set in the environment)
ask() {
    local __v="$1" __p="$2" __d="$3" __in
    if [ -n "${!__v}" ]; then return; fi
    if [ -n "$__d" ]; then
        read -r -p "$__p [$__d]: " __in
        __in="${__in:-$__d}"
    else
        read -r -p "$__p: " __in
    fi
    printf -v "$__v" '%s' "$__in"
}

# ask_required VAR "Prompt" "default"
ask_required() {
    local __v="$1"
    while true; do
        ask "$@"
        if [ -n "${!__v}" ]; then break; fi
        echo "  This field is required."
        unset "$__v"
    done
}

ask_yesno() {  # ask_yesno VAR "Prompt" y|n
    local __v="$1" __p="$2" __d="$3" __in
    if [ -n "${!__v}" ]; then return; fi
    read -r -p "$__p (y/n) [$__d]: " __in
    __in="${__in:-$__d}"
    case "$__in" in [Yy]*) printf -v "$__v" 'y' ;; *) printf -v "$__v" 'n' ;; esac
}

echo "================================================"
echo "        Universal IRCd Server Installer"
echo "================================================"
echo ""
echo "This will install IRCd to: $INSTALL_PATH"
echo ""

# ---------- Step 1: gather information ----------
echo "--- Network ---"
ask_required NETWORK_NAME "Network name (e.g. MyNet)"
ask_required DOMAIN "Network base domain (e.g. mynet.org)"
ask NETWORK_DESC "Network description" "$NETWORK_NAME IRC Network"
ask DEFAULT_CHANNEL "Auto-join channel for users (blank = none)" ""
ask ADMIN_CONTACT "Admin contact email" "admin@$DOMAIN"
ask ADMIN_LOCATION "Admin location line" "$NETWORK_NAME IRC Server"
ask WEB_URL "Network website URL (blank = none)" ""

echo ""
echo "--- This server ---"
ask_required SERVER_NAME "This server's hostname (e.g. irc.$DOMAIN)"
ask SERVER_DESC "This server's description" "$NETWORK_DESC"

while true; do
    ask SERVER_NUMERIC "This server's numeric (0-255, must be unique on the network)" "1"
    if [[ "$SERVER_NUMERIC" =~ ^[0-9]+$ ]] && [ "$SERVER_NUMERIC" -ge 0 ] && [ "$SERVER_NUMERIC" -le 255 ]; then
        break
    fi
    echo "  ERROR: Numeric must be a plain number between 0 and 255."
    unset SERVER_NUMERIC
done

ask CLIENT_PORT "Client port" "6667"
ask LINK_PORT "Server-to-server link port" "4400"

echo ""
echo "--- Mode ---"
echo "  1) Standalone / first server (hub)"
echo "  2) Leaf server (link to an existing hub)"
ask SERVER_MODE "Choose mode" "1"

if [ "$SERVER_MODE" = "2" ]; then
    ask_required HUB_NAME "Hub server hostname (e.g. hub.$DOMAIN)"
    ask_required HUB_IP "Hub server IP"
    ask HUB_PORT "Hub connect port" "$LINK_PORT"
    if [ -z "$LINK_PASS" ]; then
        while true; do
            read -r -s -p "Link password (shared with hub admin): " LINK_PASS; echo ""
            [ -n "$LINK_PASS" ] && break
            echo "  This field is required."
        done
    fi
fi

echo ""
echo "--- Services (optional) ---"
ask_yesno WANT_SERVICES "Add a local services link block (GNUWorld/Anope on 127.0.0.1)?" "n"
if [ "$WANT_SERVICES" = "y" ]; then
    ask SERVICES_NAME "Services server name" "services.$DOMAIN"
    ask SERVICES_PASS "Services link password (blank = generate)" ""
    SERVICES_PASS="${SERVICES_PASS:-$(openssl rand -hex 8 2>/dev/null || echo changeme_services)}"
fi

NETWORK_SLUG=$(echo "$NETWORK_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')
[ -z "$NETWORK_SLUG" ] && NETWORK_SLUG="ircnet"
HIDE_PREFIX="${NETWORK_SLUG:0:2}"
SVC_NAME="${NETWORK_SLUG}-ircd"

echo ""
echo "Configuration summary:"
echo "  Install path:    $INSTALL_PATH"
echo "  Network:         $NETWORK_NAME ($DOMAIN)"
echo "  Server name:     $SERVER_NAME"
echo "  Server numeric:  $SERVER_NUMERIC"
echo "  Client port:     $CLIENT_PORT"
echo "  Link port:       $LINK_PORT"
if [ "$SERVER_MODE" = "2" ]; then
    echo "  Mode:            Leaf -> $HUB_NAME ($HUB_IP:$HUB_PORT)"
else
    echo "  Mode:            Standalone / hub"
fi
[ "$WANT_SERVICES" = "y" ] && echo "  Services:        $SERVICES_NAME"
echo ""
ask CONFIRM "Proceed with installation? (y/n)" "y"
if [ "$CONFIRM" != "y" ]; then
    echo "Aborted."
    exit 1
fi

# ---------- Step 2: dependencies ----------
echo ""
echo ">>> Installing dependencies..."
$SUDO apt-get update -qq
$SUDO apt-get install -y -qq build-essential libssl-dev wget curl flex bison openssl

# Only needed if you use an old precompiled binary. Set INSTALL_LIBSSL11=1 to enable.
if [ "${INSTALL_LIBSSL11:-0}" = "1" ] && ! ldconfig -p | grep -q libssl.so.1.1; then
    echo ">>> Installing libssl1.1..."
    cd /tmp
    wget -q http://archive.ubuntu.com/ubuntu/pool/main/o/openssl/libssl1.1_1.1.1f-1ubuntu2_amd64.deb -O libssl1.1.deb
    $SUDO dpkg -i libssl1.1.deb || $SUDO apt-get install -f -y -qq
fi

# ---------- Step 3: source ----------
echo ""
echo ">>> Preparing IRCd source..."
cd ~

# Default: official Undernet ircu 2.10.12.19. Override with: SOURCE_URL=https://your.host/ircd.tar.gz
SOURCE_URL="${SOURCE_URL:-https://github.com/UndernetIRC/ircu2/releases/download/u2.10.12.19/ircu2.10.12.19.tar.gz}"
TARBALL="$(basename "$SOURCE_URL")"

if [ -f "$TARBALL" ]; then
    echo ">>> Found existing $TARBALL"
else
    echo ">>> Downloading $TARBALL..."
    wget "$SOURCE_URL" -O "$TARBALL"
    if [ ! -s "$TARBALL" ]; then
        echo "ERROR: Failed to download $TARBALL"
        rm -f "$TARBALL"
        exit 1
    fi
fi

echo ">>> Extracting source..."
rm -rf ircd_src_extracted
mkdir -p ircd_src_extracted
tar xzf "$TARBALL" -C ircd_src_extracted

SOURCE_DIR=$(find ircd_src_extracted -type f -name configure -printf '%h\n' | head -1)
if [ -z "$SOURCE_DIR" ]; then
    echo "ERROR: Could not find configure script inside tarball!"
    exit 1
fi
cd "$SOURCE_DIR" || exit 1

# ---------- Step 4: configure & compile ----------
echo ""
echo ">>> Configuring with install path: $INSTALL_PATH"
chmod +x configure
./configure --prefix="$INSTALL_PATH" --with-dpath="$INSTALL_PATH/lib"

DPATH_CHECK=$(grep "DPATH" config.h | grep -o '"[^"]*"' | tr -d '"')
if [ "$DPATH_CHECK" != "$INSTALL_PATH/lib" ]; then
    echo "ERROR: DPATH mismatch! Expected $INSTALL_PATH/lib, got $DPATH_CHECK"
    exit 1
fi
echo "    DPATH verified: $DPATH_CHECK"

echo ">>> Compiling (this may take a few minutes)..."
make -j"$(nproc)" 2>&1 | tail -10

if [ ! -f ircd/ircd ]; then
    echo "ERROR: Compilation failed - ircd binary not produced!"
    exit 1
fi
echo "    Compilation successful!"

# ---------- Step 5: deploy ----------
echo ""
echo ">>> Deploying binary..."
mkdir -p "$INSTALL_PATH/bin" "$INSTALL_PATH/lib"
NEWBIN="ircd.$(date +%Y%m%d%H%M)"
cp ircd/ircd "$INSTALL_PATH/bin/$NEWBIN"
chmod 755 "$INSTALL_PATH/bin/$NEWBIN"
ln -sf "$NEWBIN" "$INSTALL_PATH/bin/ircd"
echo "    Binary deployed: $INSTALL_PATH/bin/$NEWBIN"

# ---------- Step 6: generate ircd.conf ----------
echo ""
echo ">>> Generating ircd.conf..."

SERVER_IP=$(curl -s -4 --max-time 8 ifconfig.me || curl -s -4 --max-time 8 icanhazip.com || echo "0.0.0.0")
[ -z "$SERVER_IP" ] && SERVER_IP="0.0.0.0"
ADMIN_PASS=$(openssl rand -hex 8)
RANDOM_SEED=$(openssl rand -hex 16)
HIDE_KEY1=$(openssl rand -hex 14)
HIDE_KEY2=$(openssl rand -hex 14)
HIDE_KEY3=$(openssl rand -hex 14)

# --- optional pieces ---
AUTOJOIN_OTHER=""
AUTOJOIN_LOCAL=""
if [ -n "$DEFAULT_CHANNEL" ]; then
    AUTOJOIN_OTHER=" autojoinchannel = \"$DEFAULT_CHANNEL\";"
    AUTOJOIN_LOCAL=" autojoinchannel = \"$DEFAULT_CHANNEL\";"
fi

URL_FEATURES=""
if [ -n "$WEB_URL" ]; then
    URL_FEATURES=" \"HIS_URLSERVERS\" = \"$WEB_URL\";
 \"URLREG\" = \"$WEB_URL\";"
fi

if [ "$SERVER_MODE" = "2" ]; then
    HUB_FEATURE="FALSE"
    MAXLINKS_FEATURE="1"
    HUB_CONNECT_BLOCK="Connect {
 name = \"$HUB_NAME\";
 host = \"$HUB_IP\";
 password = \"$LINK_PASS\";
 port = $HUB_PORT;
 class = \"Server\";
 hub = \"*\";
};"
else
    HUB_FEATURE="TRUE"
    MAXLINKS_FEATURE="20"
    HUB_CONNECT_BLOCK="# Standalone/hub: add a Connect { } block here for each server that links to you,
# then /rehash. Example:
#
# Connect {
#  name = \"leaf.$DOMAIN\";
#  host = \"LEAF_IP\";
#  password = \"LINKPASSWORD\";
#  port = $LINK_PORT;
#  class = \"Server\";
#  hub = \"*\";
# };"
fi

SERVICES_UWORLD=""
SERVICES_CONNECT=""
SERVICES_PSEUDO=""
if [ "$WANT_SERVICES" = "y" ]; then
    SERVICES_UWORLD="UWorld {
 name = \"$SERVICES_NAME\";
};"
    SERVICES_CONNECT="Connect {
 name = \"$SERVICES_NAME\";
 host = \"127.0.0.1\";
 password = \"$SERVICES_PASS\";
 port = $LINK_PORT;
 class = \"LeafServer\";
 leaf;
};"
    SERVICES_PSEUDO="Pseudo \"X\" {
 name = \"X\";
 nick = \"X@$SERVICES_NAME\";
};

Pseudo \"LOGIN\" {
 name = \"X\";
 prepend = \"LOGIN \";
 nick = \"X@$SERVICES_NAME\";
};"
fi

cat > "$INSTALL_PATH/lib/ircd.conf" << CONF_EOF
# $NETWORK_NAME Network - $SERVER_NAME
# Auto-generated by install_ircd.sh on $(date)

General {
 name = "$SERVER_NAME";
 vhost = "$SERVER_IP";
 description = "$SERVER_DESC";
 numeric = $SERVER_NUMERIC;
};

Admin {
 Location = "$ADMIN_LOCATION";
 Location = "$NETWORK_DESC";
 Contact = "$ADMIN_CONTACT";
};

Class {
 name = "Server";
 pingfreq = 1 minutes 30 seconds;
 connectfreq = 5 minutes;
 maxlinks = 20;
 sendq = 9000000;
};

Class {
 name = "LeafServer";
 pingfreq = 1 minutes 30 seconds;
 connectfreq = 5 minutes;
 maxlinks = 50;
 sendq = 9000000;
};

Class {
 name = "Local";
 pingfreq = 1 minutes 30 seconds;
 sendq = 160000;
 maxlinks = 100;
 usermode = "+iw";
$AUTOJOIN_LOCAL
};

Class {
 name = "Other";
 pingfreq = 1 minutes 30 seconds;
 sendq = 160000;
 maxlinks = 2048;
 usermode = "+ix";
$AUTOJOIN_OTHER
};

Class {
 name = "Opers";
 pingfreq = 1 minutes 30 seconds;
 sendq = 160000;
 maxlinks = 20;
 local = no;
 freeform = yes;
 mode_lchan = yes;
 deop_lchan = yes;
 walk_lchan = yes;
 show_invis = yes;
 see_chan = yes;
 list_chan = yes;
 usermode = "+W";
};

Client {
 host = "*@*";
 ip = "*@*";
 class = "Other";
 maxlinks = 100;
};

Client {
 ip = "*@127.0.0.1";
 class = "Local";
 maxlinks = 200;
};

motd {
 host = "*";
 file = "ircd.motd";
};

$SERVICES_UWORLD

Jupe {
 nick = "A,B,C,D,E,F,G,H,I,J,K,L,M,N,O,P,Q,R,S,T,U,V,W,X,Y,Z,{,|,},~,-,_,\`";
 nick = "LPT1,LPT2,COM1,COM2,COM3,COM4,AUX";
};

$HUB_CONNECT_BLOCK

$SERVICES_CONNECT

CRULE {
 server = "*";
 rule = "directcon(*)";
};

Operator {
 host = "*@*";
 password = "\$PLAIN\$$ADMIN_PASS";
 name = "admin";
 class = "Opers";
 hide_oper = yes;
 hide_channels = yes;
 whois_notice = yes;
 admin = yes;
};

Port {
 vhost = "$SERVER_IP" $CLIENT_PORT;
 hidden = no;
};

Port {
 server = yes;
 port = $LINK_PORT;
};

$SERVICES_PSEUDO

features {
 "LOG" = "SYSTEM" "FILE" "ircd.log";
 "LOG" = "SYSTEM" "LEVEL" "CRIT";
 "DOMAINNAME" = "$DOMAIN";
 "RELIABLE_CLOCK" = "FALSE";
 "BUFFERPOOL" = "27000000";
 "HAS_FERGUSON_FLUSHER" = "FALSE";
 "CLIENT_FLOOD" = "1024";
 "SERVER_PORT" = "$LINK_PORT";
 "NODEFAULTMOTD" = "FALSE";
 "KILL_IPMISMATCH" = "FALSE";
 "IDLE_FROM_MSG" = "TRUE";
 "HUB" = "$HUB_FEATURE";
 "WALLOPS_OPER_ONLY" = "TRUE";
 "NODNS" = "FALSE";
 "RANDOM_SEED" = "$RANDOM_SEED";
 "NICKNAMEHISTORYLENGTH" = "800";
 "NETWORK" = "$NETWORK_NAME";
 "HOST_HIDING" = "TRUE";
 "HIDDEN_HOST" = "users.$DOMAIN";
 "HIDDEN_IP" = "127.0.0.1";
 "MAXCHANNELSPERUSER" = "60";
 "NICKLEN" = "12";
 "MAXBANS" = "50";
 "MAXSILES" = "15";
 "HANGONGOODLINK" = "300";
 "HANGONRETRYDELAY" = "10";
 "CONNECTTIMEOUT" = "90";
 "MAXIMUM_LINKS" = "$MAXLINKS_FEATURE";
 "PINGFREQUENCY" = "120";
 "CONNECTFREQUENCY" = "600";
 "DEFAULTMAXSENDQLENGTH" = "40000";
 "GLINEMAXUSERCOUNT" = "20";
 "MPATH" = "ircd.motd";
 "RPATH" = "remote.motd";
 "PPATH" = "ircd.pid";
 "TOS_SERVER" = "0x08";
 "TOS_CLIENT" = "0x08";
 "POLLS_PER_LOOP" = "200";
 "IRCD_RES_TIMEOUT" = "4";
 "IRCD_RES_RETRIES" = "2";
 "AUTH_TIMEOUT" = "9";
 "IPCHECK_CLONE_LIMIT" = "4";
 "IPCHECK_CLONE_PERIOD" = "40";
 "IPCHECK_CLONE_DELAY" = "600";
 "CHANNELLEN" = "200";
 "CONFIG_OPERCMDS" = "TRUE";
 "OPLEVELS" = "FALSE";
 "ZANNELS" = "FALSE";
 "LOCAL_CHANNELS" = "FALSE";
 "ANNOUNCE_INVITES" = "TRUE";
 "HIS_SNOTICES" = "TRUE";
 "HIS_SNOTICES_OPER_ONLY" = "TRUE";
 "HIS_DEBUG_OPER_ONLY" = "TRUE";
 "HIS_WALLOPS" = "TRUE";
 "HIS_MAP" = "TRUE";
 "HIS_LINKS" = "TRUE";
 "HIS_TRACE" = "TRUE";
 "HIS_STATS_a" = "TRUE";
 "HIS_STATS_c" = "TRUE";
 "HIS_STATS_d" = "TRUE";
 "HIS_STATS_e" = "TRUE";
 "HIS_STATS_f" = "TRUE";
 "HIS_STATS_g" = "TRUE";
 "HIS_STATS_i" = "TRUE";
 "HIS_STATS_j" = "TRUE";
 "HIS_STATS_J" = "TRUE";
 "HIS_STATS_k" = "TRUE";
 "HIS_STATS_l" = "TRUE";
 "HIS_STATS_L" = "TRUE";
 "HIS_STATS_m" = "TRUE";
 "HIS_STATS_M" = "TRUE";
 "HIS_STATS_o" = "TRUE";
 "HIS_STATS_p" = "TRUE";
 "HIS_STATS_q" = "TRUE";
 "HIS_STATS_r" = "TRUE";
 "HIS_STATS_R" = "TRUE";
 "HIS_STATS_t" = "TRUE";
 "HIS_STATS_T" = "TRUE";
 "HIS_STATS_u" = "FALSE";
 "HIS_STATS_U" = "TRUE";
 "HIS_STATS_v" = "TRUE";
 "HIS_STATS_w" = "TRUE";
 "HIS_STATS_x" = "TRUE";
 "HIS_STATS_y" = "TRUE";
 "HIS_STATS_z" = "TRUE";
 "HIS_STATS_IAUTH" = "TRUE";
 "HIS_STATS_W" = "TRUE";
 "HIS_WHOIS_SERVERNAME" = "TRUE";
 "HIS_WHOIS_IDLETIME" = "TRUE";
 "HIS_WHOIS_LOCALCHAN" = "FALSE";
 "HIS_WHO_SERVERNAME" = "TRUE";
 "HIS_WHO_HOPCOUNT" = "TRUE";
 "HIS_MODEWHO" = "TRUE";
 "HIS_BANWHO" = "TRUE";
 "HIS_KILLWHO" = "FALSE";
 "HIS_REWRITE" = "TRUE";
 "HIS_REMOTE" = "TRUE";
 "HIS_NETSPLIT" = "TRUE";
 "HIS_SERVERNAME" = "*.$DOMAIN";
 "HIS_SERVERINFO" = "$NETWORK_NAME IRC NetWork";
$URL_FEATURES
 "CONNEXIT_NOTICES" = "TRUE";
};

CONF_EOF

echo "    ircd.conf generated."

# ---------- Step 6b: support files ----------
echo ""
echo ">>> Creating required support files..."

if [ ! -f "$INSTALL_PATH/lib/ircd.motd" ]; then
    cat > "$INSTALL_PATH/lib/ircd.motd" << MOTD_EOF
Welcome to $NETWORK_NAME IRC Network!
${WEB_URL:+Visit $WEB_URL for more info.}
MOTD_EOF
    echo "    ircd.motd created."
fi

touch "$INSTALL_PATH/lib/remote.motd"

if [ ! -f "$INSTALL_PATH/lib/ircd.pem" ]; then
    openssl req -newkey rsa:2048 -nodes -keyout "$INSTALL_PATH/lib/ircd.pem" \
        -x509 -days 3650 -out /tmp/ircd_cert.pem \
        -subj "/O=$NETWORK_NAME/CN=$SERVER_NAME" 2>/dev/null
    cat /tmp/ircd_cert.pem >> "$INSTALL_PATH/lib/ircd.pem"
    rm -f /tmp/ircd_cert.pem
    chmod 600 "$INSTALL_PATH/lib/ircd.pem"
    echo "    ircd.pem (self-signed SSL cert) created."
fi

# ---------- Step 7: test start ----------
echo ""
echo ">>> Starting IRCd..."
cd "$INSTALL_PATH/bin"
./ircd -f "$INSTALL_PATH/lib/ircd.conf"
sleep 3

if ps aux | grep -q "[i]rcd -f $INSTALL_PATH/lib/ircd.conf"; then
    echo "    IRCd started successfully!"
else
    echo ""
    echo "WARNING: IRCd does not appear to be running."
    if [ -f "$INSTALL_PATH/lib/ircd.log" ]; then
        echo "--- Last 20 lines of ircd.log ---"
        tail -20 "$INSTALL_PATH/lib/ircd.log"
        echo "---------------------------------"
    else
        echo "No log file. Running in foreground to show the error:"
        timeout 3 ./ircd -f "$INSTALL_PATH/lib/ircd.conf" 2>&1 || true
    fi
fi

# ---------- Step 8: systemd service ----------
echo ""
echo ">>> Setting up systemd service for auto-start on reboot..."

SVC_USER=$(whoami)
SVC_FILE="/etc/systemd/system/${SVC_NAME}.service"
PID_FILE="$INSTALL_PATH/lib/ircd.pid"

if ! command -v systemctl >/dev/null 2>&1; then
    echo "WARNING: systemd not found - skipping service creation."
else
    echo ">>> Stopping manually-started IRCd so systemd can take over..."
    if [ -f "$PID_FILE" ]; then
        kill "$(cat "$PID_FILE")" 2>/dev/null || true
    else
        pkill -f "$INSTALL_PATH/bin/ircd" 2>/dev/null || true
    fi
    sleep 3

    $SUDO tee "$SVC_FILE" > /dev/null << SVCEOF
[Unit]
Description=$NETWORK_NAME IRCd - $SERVER_NAME
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
User=$SVC_USER
Group=$SVC_USER
WorkingDirectory=$INSTALL_PATH/bin
PIDFile=$PID_FILE
ExecStartPre=/bin/rm -f $PID_FILE
ExecStart=$INSTALL_PATH/bin/ircd -f $INSTALL_PATH/lib/ircd.conf
ExecStop=/bin/kill -TERM \$MAINPID
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SVCEOF

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable "$SVC_NAME" > /dev/null 2>&1
    $SUDO systemctl start "$SVC_NAME"
    sleep 3

    if $SUDO systemctl is-active --quiet "$SVC_NAME"; then
        echo "    IRCd is running via systemd and will auto-start on reboot."
    else
        echo "WARNING: systemd failed to start IRCd."
        echo "Check: sudo journalctl -u $SVC_NAME -n 30"
    fi
fi

# ---------- Summary ----------
echo ""
echo "================================================"
echo "  INSTALLATION COMPLETE"
echo "================================================"
echo "Network:         $NETWORK_NAME"
echo "Server:          $SERVER_NAME"
echo "Numeric:         $SERVER_NUMERIC"
echo "Install:         $INSTALL_PATH"
echo "Log file:        $INSTALL_PATH/lib/ircd.log"
echo "Public IP:       $SERVER_IP"
echo "Client port:     $CLIENT_PORT"
echo "Link port:       $LINK_PORT"
echo "Oper login:      /oper admin $ADMIN_PASS   (save this!)"
[ "$WANT_SERVICES" = "y" ] && echo "Services pass:   $SERVICES_PASS   (server: $SERVICES_NAME)"
echo ""
if [ "$SERVER_MODE" = "2" ]; then
    echo "Send this to the hub admin so they add a Connect {} block:"
    echo "  Server name:    $SERVER_NAME"
    echo "  Server IP:      $SERVER_IP"
    echo "  Numeric:        $SERVER_NUMERIC"
    echo "  Link password:  (the one you entered)"
    echo "  Link port:      $LINK_PORT"
else
    echo "To link other servers to this hub, add a Connect {} block"
    echo "in $INSTALL_PATH/lib/ircd.conf and run /rehash."
fi
echo ""
echo "Manage:  sudo systemctl {start|stop|restart|status} $SVC_NAME"
echo "Open firewall ports: $CLIENT_PORT and $LINK_PORT (tcp)"
echo "================================================"
