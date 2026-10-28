#!/bin/bash
#
# UnderIRC leaf-server installer
# Settings are copied from the hub's config (Ro.UnderIRC.org), so you only
# answer 3 questions: server name, numeric, link password.
#
# Non-interactive use (skips the questions):
#   SERVER_NAME=usa.underirc.org SERVER_NUMERIC=4 LINK_PASS=secret ./ircd.sh
#
INSTALL_PATH="${INSTALL_PATH:-$HOME/ircd}"

# ---------------------------------------------------------------
# FIXED SETTINGS - copied from the hub's under.conf. Edit only if the
# hub changes. Environment variables can override any of them.
# ---------------------------------------------------------------
NETWORK_NAME="${NETWORK_NAME:-UnderIRC}"
DOMAIN="${DOMAIN:-underirc.org}"
HUB_NAME="${HUB_NAME:-Ro.UnderIRC.org}"
HUB_IP="${HUB_IP:-96.47.231.251}"
HUB_PORT="${HUB_PORT:-4400}"
LINK_PORT="${LINK_PORT:-4400}"
CLIENT_PORTS="${CLIENT_PORTS:-6667 6666 6668 6669}"
SERVICES_NAME="${SERVICES_NAME:-UnderIRC.org}"
ADMIN_CONTACT="${ADMIN_CONTACT:-IRC Admins <Arns@underirc.org>}"
MAXCON="${MAXCON:-4096}"
SOURCE_URL="${SOURCE_URL:-https://github.com/UndernetIRC/ircu2/releases/download/u2.10.12.19/ircu2.10.12.19.tar.gz}"

die() { echo ""; echo "ERROR: $*"; exit 1; }
if [ "$(id -u)" -eq 0 ]; then
    die "Do not run this as root. Run it as your normal user (it uses sudo only when needed)."
    fi
SUDO="sudo"

# ---------------------------------------------------------------
# THE 3 QUESTIONS
# ---------------------------------------------------------------
echo "================================================"
echo "     UnderIRC Leaf Server Installer"
echo "================================================"
echo "Links this server to $HUB_NAME. Only 3 questions."
echo ""

if [ -z "$SERVER_NAME" ]; then
    echo "1) Your server's name. Any name under your network, e.g. usa.underirc.org"
    read -r -p "   Server name [usa.underirc.v6.rocks]: " SERVER_NAME
    SERVER_NAME="${SERVER_NAME:-usa.underirc.v6.rocks}"
fi

while true; do
    if [ -z "$SERVER_NUMERIC" ]; then
        echo "2) Your server's number (0-255). Must be UNIQUE on the network."
        echo "   The hub is 1. Ask the hub admin which numbers are free."
        read -r -p "   Server number [4]: " SERVER_NUMERIC
        SERVER_NUMERIC="${SERVER_NUMERIC:-4}"
    fi
    if [[ "$SERVER_NUMERIC" =~ ^[0-9]+$ ]] && [ "$SERVER_NUMERIC" -ge 0 ] \
       && [ "$SERVER_NUMERIC" -le 255 ] && [ "$SERVER_NUMERIC" -ne 1 ]; then
        break
    fi
    echo "   Must be a number 0-255, and not 1 (the hub uses 1)."
    unset SERVER_NUMERIC
done

while [ -z "$LINK_PASS" ]; do
    echo "3) Link password. Must be EXACTLY the one the hub admin puts in the hub."
    read -r -s -p "   Link password (typing is hidden): " LINK_PASS; echo ""
done

echo ""
echo "  Server:   $SERVER_NAME  (number $SERVER_NUMERIC)"
echo "  Hub:      $HUB_NAME  ($HUB_IP:$HUB_PORT)"
echo "  Install:  $INSTALL_PATH"
echo ""
if [ -z "$ASSUME_YES" ]; then
    read -r -p "Press Enter to install (Ctrl+C to cancel) " _
fi

# ---------------------------------------------------------------
# DEPENDENCIES (only runs apt if something is missing)
# ---------------------------------------------------------------
echo ""
echo ">>> Checking dependencies..."
MISSING=0
for c in gcc make flex bison wget openssl curl; do
    command -v "$c" >/dev/null 2>&1 || MISSING=1
done
[ -f /usr/include/openssl/ssl.h ] || MISSING=1
if [ "$MISSING" = "1" ]; then
    echo ">>> Installing build tools (needs your sudo password)..."
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq build-essential libssl-dev wget curl flex bison openssl \
        || die "Could not install dependencies."
else
    echo "    All present."
fi

# ---------------------------------------------------------------
# DOWNLOAD + BUILD
# ---------------------------------------------------------------
echo ""
echo ">>> Downloading ircu source..."
cd "$HOME" || die "No home directory."
TARBALL="$(basename "$SOURCE_URL")"
if [ ! -s "$TARBALL" ]; then
    wget -q "$SOURCE_URL" -O "$TARBALL" || { rm -f "$TARBALL"; die "Download failed."; }
fi
rm -rf ircd_src_extracted && mkdir -p ircd_src_extracted
tar xzf "$TARBALL" -C ircd_src_extracted || die "Could not extract $TARBALL"
SOURCE_DIR=$(find ircd_src_extracted -type f -name configure -printf '%h\n' | head -1)
[ -n "$SOURCE_DIR" ] || die "configure script not found in tarball."
cd "$SOURCE_DIR" || die "Cannot enter source dir."

echo ">>> Configuring..."
# --with-maxcon: without it configure picks ~1,000,000 and ircd refuses to start.
chmod +x configure
./configure --prefix="$INSTALL_PATH" --with-dpath="$INSTALL_PATH/lib" \
            --with-maxcon="$MAXCON" --with-domain="$DOMAIN" >/tmp/ircd_configure.log 2>&1 \
    || { tail -15 /tmp/ircd_configure.log; die "configure failed (log: /tmp/ircd_configure.log)"; }

echo ">>> Compiling (a few minutes)..."
make -j"$(nproc)" >/tmp/ircd_make.log 2>&1
[ -f ircd/ircd ] || { tail -15 /tmp/ircd_make.log; die "Compile failed (log: /tmp/ircd_make.log)"; }

mkdir -p "$INSTALL_PATH/bin" "$INSTALL_PATH/lib"
NEWBIN="ircd.$(date +%Y%m%d%H%M)"
cp ircd/ircd "$INSTALL_PATH/bin/$NEWBIN"
chmod 755 "$INSTALL_PATH/bin/$NEWBIN"
ln -sf "$NEWBIN" "$INSTALL_PATH/bin/ircd"
echo "    Built: $INSTALL_PATH/bin/$NEWBIN"

# ---------------------------------------------------------------
# GENERATE ircd.conf (mirrors the hub's under.conf)
# ---------------------------------------------------------------
echo ""
echo ">>> Writing ircd.conf..."
CONF="$INSTALL_PATH/lib/ircd.conf"
[ -f "$CONF" ] && cp "$CONF" "$CONF.bak.$(date +%Y%m%d%H%M)"

SERVER_IP=$(curl -s -4 --max-time 8 ifconfig.me || curl -s -4 --max-time 8 icanhazip.com || echo "YOUR_SERVER_IP")
OPER_PASS=$(openssl rand -hex 8)
RANDOM_SEED=$(openssl rand -hex 16)

PORT_BLOCKS=""
for p in $CLIENT_PORTS; do
    PORT_BLOCKS="$PORT_BLOCKS
Port {
 port = $p;
};
"
done

cat > "$CONF" << CONF_EOF
# $NETWORK_NAME leaf server - $SERVER_NAME
# Generated by ircd.sh on $(date). Mirrors hub $HUB_NAME.

General {
 name = "$SERVER_NAME";
 description = "$NETWORK_NAME NetWork";
 numeric = $SERVER_NUMERIC;
};

Admin {
 Location = "$NETWORK_NAME NetWork";
 Location = "$SERVER_NAME";
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
 name = "Local";
 pingfreq = 1 minutes 30 seconds;
 sendq = 160000;
 maxlinks = 100;
 usermode = "+iw";
};

Class {
 name = "Other";
 pingfreq = 1 minutes 30 seconds;
 sendq = 160000;
 maxlinks = 2048;
 usermode = "+i";
};

Class {
 name = "irccloud";
 pingfreq = 1 minutes 30 seconds;
 sendq = 160000;
 maxlinks = 1024;
 usermode = "+i";
};

Class {
 name = "netsplit";
 pingfreq = 1 minutes 30 seconds;
 sendq = 160000;
 maxlinks = 1024;
 usermode = "+i";
};

Class {
 name = "Opers";
 local = no;
 pingfreq = 1 minutes 30 seconds;
 sendq = 160000;
 maxlinks = 20;
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

Client {
 host = "*@*irccloud.com";
 class = "irccloud";
 maxlinks = 50;
};

Client {
 host = "*@*netsplit.de";
 class = "netsplit";
 maxlinks = 20;
};

motd {
 host = "*";
 file = "ircd.motd";
};

# Services run on the hub, not here. These names must match the hub's UWorld.
UWorld {
 name = "UnderIRC.org";
 name = "EWorld.UnderIRC.org";
 name = "Chanfix.UnderIRC.org";
 name = "Defender.UnderIRC.org";
};

Jupe {
 nick = "A,B,C,D,E,F,G,H,I,J,K,L,M,N,O,P,Q,R,S,T,U,V,W,X,Y,Z,{,|,},~,-,_,\`";
 nick = "EuWorld,UWorld,UWorld2,Defender";
 nick = "login,admin,pinoychat,underirc,staff,cservice,dalnet,undernet,protocol,pass,newpass,org";
 nick = "StatServ,NoteServ";
 nick = "ChanSvr,ChanSaver,ChanServ";
 nick = "NickSvr,NickSaver,NickServ";
 nick = "LPT1,LPT2,COM1,COM2,COM3,COM4,AUX";
};

# Link to the hub. Name, IP and password must match the hub's Connect block for you.
Connect {
 name = "$HUB_NAME";
 host = "$HUB_IP";
 password = "$LINK_PASS";
 port = $HUB_PORT;
 class = "Server";
 hub = "*";
};

CRULE {
 server = "*";
 rule = "directcon(*)";
};

Operator {
 host = "*@*";
 password = "\$PLAIN\$$OPER_PASS";
 name = "admin";
 class = "Opers";
};
$PORT_BLOCKS
Port {
 server = yes;
 port = $LINK_PORT;
};

Pseudo "CHANSERV" {
 name = "X";
 nick = "X@$SERVICES_NAME";
};

Pseudo "LOGIN" {
 name = "X";
 prepend = "LOGIN ";
 nick = "X@$SERVICES_NAME";
};

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
 "HUB" = "FALSE";
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
 "MAXIMUM_LINKS" = "1";
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
 "HIS_WHOIS_SERVERNAME" = "TRUE";
 "HIS_WHOIS_IDLETIME" = "TRUE";
 "HIS_WHOIS_LOCALCHAN" = "TRUE";
 "HIS_WHO_SERVERNAME" = "TRUE";
 "HIS_WHO_HOPCOUNT" = "TRUE";
 "HIS_MODEWHO" = "TRUE";
 "HIS_BANWHO" = "TRUE";
 "HIS_KILLWHO" = "FALSE";
 "HIS_REWRITE" = "TRUE";
 "HIS_REMOTE" = "TRUE";
 "HIS_NETSPLIT" = "TRUE";
 "HIS_SERVERNAME" = "*.UnderIRC.org";
 "HIS_SERVERINFO" = "UnderIRC NetWork";
 "HIS_URLSERVERS" = "https://underIRC.org/servers.php";
 "URLREG" = "http://underirc.arns.afraid.org/live";
 "HIS_STATS_W" = "TRUE";
 "CONNEXIT_NOTICES" = "TRUE";
};
CONF_EOF
chmod 600 "$CONF"

# support files
[ -f "$INSTALL_PATH/lib/ircd.motd" ] || printf 'Welcome to %s IRC Network!\n' "$NETWORK_NAME" > "$INSTALL_PATH/lib/ircd.motd"
[ -f "$INSTALL_PATH/lib/net_com.motd" ] || cp "$INSTALL_PATH/lib/ircd.motd" "$INSTALL_PATH/lib/net_com.motd"
touch "$INSTALL_PATH/lib/remote.motd"

# ---------------------------------------------------------------
# CHECK THE CONFIG BEFORE STARTING (this is what the old script skipped)
# ---------------------------------------------------------------
echo ""
echo ">>> Checking ircd.conf for errors..."
CHECK_OUT=$("$INSTALL_PATH/bin/ircd" -k -f "$CONF" 2>&1); CHECK_RC=$?
if [ $CHECK_RC -ne 0 ] || echo "$CHECK_OUT" | grep -qi "error"; then
    echo "$CHECK_OUT"
    die "ircd.conf has errors (shown above). Nothing was started."
fi
echo "    Config OK."

# ---------------------------------------------------------------
# SAVE CREDENTIALS + HUB REQUEST (so nothing is lost if the screen scrolls)
# ---------------------------------------------------------------
CRED="$INSTALL_PATH/CREDENTIALS.txt"
cat > "$CRED" << CRED_EOF
Oper login:    /oper admin $OPER_PASS
Link password: (the one you typed)
Server:        $SERVER_NAME   numeric $SERVER_NUMERIC   IP $SERVER_IP   port $LINK_PORT
CRED_EOF
chmod 600 "$CRED"

HUBREQ="$INSTALL_PATH/SEND_TO_HUB_ADMIN.txt"
cat > "$HUBREQ" << HUB_EOF
Please add this to the hub ($HUB_NAME) ircd.conf, then /rehash:

Connect {
 name = "$SERVER_NAME";
 host = "$SERVER_IP";
 password = "<THE LINK PASSWORD>";
 port = $LINK_PORT;
 class = "Server";
};

Also please confirm server numeric $SERVER_NUMERIC is not used by another server.
HUB_EOF

# ---------------------------------------------------------------
# START (systemd if available)
# ---------------------------------------------------------------
echo ""
SVC_NAME="underirc-ircd"
if command -v systemctl >/dev/null 2>&1; then
    echo ">>> Setting up systemd service..."
    SVC_USER=$(whoami)
    PID_FILE="$INSTALL_PATH/lib/ircd.pid"
    # stop any old copy first
    pkill -f "$INSTALL_PATH/bin/ircd" 2>/dev/null; sleep 1
    $SUDO tee "/etc/systemd/system/${SVC_NAME}.service" >/dev/null << SVCEOF
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
ExecStart=$INSTALL_PATH/bin/ircd -f $CONF
ExecStop=/bin/kill -TERM \$MAINPID
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SVCEOF
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable "$SVC_NAME" >/dev/null 2>&1
    $SUDO systemctl restart "$SVC_NAME"
    sleep 3
    if $SUDO systemctl is-active --quiet "$SVC_NAME"; then
        echo "    Running via systemd (auto-starts on reboot)."
    else
        echo "WARNING: service did not start. See: sudo journalctl -u $SVC_NAME -n 30 --no-pager"
    fi
else
    echo ">>> systemd not found, starting directly..."
    (cd "$INSTALL_PATH/bin" && ./ircd -f "$CONF")
fi

# can we even reach the hub?
if timeout 5 bash -c "exec 3<>/dev/tcp/$HUB_IP/$HUB_PORT" 2>/dev/null; then
    HUB_REACH="reachable"
else
    HUB_REACH="NOT reachable (firewall or hub not listening)"
fi

# ---------------------------------------------------------------
# SUMMARY (always printed)
# ---------------------------------------------------------------
echo ""
echo "================================================"
echo "  DONE"
echo "================================================"
echo "Server:        $SERVER_NAME (number $SERVER_NUMERIC)"
echo "Your IP:       $SERVER_IP"
echo "Hub:           $HUB_NAME $HUB_IP:$HUB_PORT - $HUB_REACH"
echo "Oper login:    /oper admin $OPER_PASS   (also saved in $CRED)"
echo "Log file:      $INSTALL_PATH/lib/ircd.log"
echo ""
echo "NEXT STEP: send the hub admin the file below. The hub cannot accept"
echo "your server until he adds it and does /rehash:"
echo "    cat $HUBREQ"
echo ""
echo "Then connect right away (instead of waiting for autoconnect):"
echo "    /oper admin <password above>"
echo "    /connect $HUB_NAME $HUB_PORT"
echo ""
echo "Open firewall (tcp): ${CLIENT_PORTS// /, } and $LINK_PORT"
echo "Manage:  sudo systemctl {start|stop|restart|status} $SVC_NAME"
echo "================================================"
