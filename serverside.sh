#!/bin/bash
#
# addleaf.sh - run on the HUB VPS to enroll a leaf server from its JOIN CODE.
#
#   ./addleaf.sh <JOIN_CODE>                    add a server
#   ./addleaf.sh --list                         show enrolled servers
#   ./addleaf.sh --remove <server-name>         remove a server
#
# The join code is printed by the leaf's ircd.sh. It is base64 of
#   name|numeric|ip|password
#
HUBCONF="${HUBCONF:-/home/sulap/ircd/lib/under.conf}"
HUBBIN="${HUBBIN:-/home/sulap/ircd/bin/ircd}"
HUBDIR="${HUBDIR:-/home/sulap/ircd/lib}"
LINK_PORT="${LINK_PORT:-4400}"
REG="$HUBDIR/leaves.txt"

die() { echo "ERROR: $*"; exit 1; }

# registry: "name numeric ip" per line. Seeded with servers that already exist.
if [ ! -f "$REG" ]; then
    cat > "$REG" << 'SEED'
Ro.UnderIRC.org 1 hub
usa.underirc.v6.rocks 4 172.111.11.214
dubai.underirc.v6.rocks 5 107.152.44.9
SEED
fi

check_and_reload() {   # roll back the config if it no longer parses
    if ! "$HUBBIN" -k -f "$HUBCONF" -d "$HUBDIR"; then
        echo "Config check FAILED, restoring backup."
        cp "$BACKUP" "$HUBCONF"
        return 1
    fi
    PID=$(pgrep -f "ircd.* -f $HUBCONF" | head -1)
    if [ -n "$PID" ]; then
        kill -HUP "$PID" && echo "Hub reloaded (PID $PID)."
    else
        echo "WARNING: hub process not found. Reload it yourself: /rehash"
    fi
}

case "$1" in
--list)
    cat "$REG"; exit 0 ;;
--remove)
    NAME="$2"; [ -n "$NAME" ] || die "usage: $0 --remove <server-name>"
    grep -qi "^$NAME " "$REG" || die "$NAME is not in $REG"
    BACKUP="$HUBCONF.bak.$(date +%Y%m%d%H%M%S)"; cp "$HUBCONF" "$BACKUP"
    # delete the whole Connect { ... }; block that has this server name
    python3 - "$HUBCONF" "$NAME" << 'PY' || die "could not edit config"
import re, sys
conf, name = sys.argv[1], sys.argv[2]
t = open(conf).read()
pat = re.compile(r'\n*Connect\s*\{[^}]*?name\s*=\s*"%s"\s*;[^}]*\};\n?' % re.escape(name), re.I)
t2, n = pat.subn("\n", t)
if n != 1: sys.exit(1)
open(conf, "w").write(t2)
PY
    check_and_reload || exit 1
    sed -i "/^$NAME /Id" "$REG"
    echo "Removed $NAME. (Your ufw rule for its IP, if any, can be deleted with: sudo ufw status numbered)"
    exit 0 ;;
"" | -h | --help)
    echo "usage: $0 <JOIN_CODE> | --list | --remove <server-name>"; exit 1 ;;
esac

# ---- add a server from a join code ----
RAW=$(printf '%s' "$1" | base64 -d 2>/dev/null) || die "That is not a valid join code."
IFS='|' read -r NAME NUMERIC IP PASS EXTRA <<< "$RAW"
[ -z "$EXTRA" ] && [ -n "$PASS" ] || die "Join code has the wrong format."

# strict validation: this text is written into your config file
[[ "$NAME" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$NAME" == *.* ]] || die "Bad server name: $NAME"
[[ "$NUMERIC" =~ ^[0-9]+$ ]] && [ "$NUMERIC" -ge 2 ] && [ "$NUMERIC" -le 255 ] || die "Bad numeric: $NUMERIC (need 2-255)"
[[ "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Bad IPv4 address: $IP"
for o in ${IP//./ }; do [ "$o" -le 255 ] || die "Bad IPv4 address: $IP"; done
[[ "$PASS" =~ ^[A-Za-z0-9._-]{8,}$ ]] || die "Bad link password format."

# no duplicates
grep -qi "^$NAME " "$REG"       && die "Server name $NAME is already enrolled."
awk -v n="$NUMERIC" '$2==n{f=1} END{exit !f}' "$REG" && die "Numeric $NUMERIC is already used. Ask the friend to reinstall with another number."
awk -v i="$IP" '$3==i{f=1} END{exit !f}' "$REG"       && die "IP $IP is already enrolled."

echo "Enrolling: $NAME  (number $NUMERIC, IP $IP)"
BACKUP="$HUBCONF.bak.$(date +%Y%m%d%H%M%S)"
cp "$HUBCONF" "$BACKUP"
cat >> "$HUBCONF" << CONN

Connect {
 name = "$NAME";
 host = "$IP";
 password = "$PASS";
 port = $LINK_PORT;
 class = "Server";
};
CONN

check_and_reload || exit 1
echo "$NAME $NUMERIC $IP" >> "$REG"

# firewall: only needed if port 4400 is not already open to everyone
if command -v ufw >/dev/null 2>&1; then
    if sudo ufw status 2>/dev/null | grep -qE "^$LINK_PORT/tcp +ALLOW IN +Anywhere"; then
        echo "Firewall: port $LINK_PORT already open to everyone, nothing to do."
    else
        sudo ufw allow from "$IP" to any port "$LINK_PORT" proto tcp
    fi
else
    echo "NOTE: ufw not found. Make sure TCP $LINK_PORT is open from $IP."
fi

echo "Done. $NAME will link by itself within a few minutes."
