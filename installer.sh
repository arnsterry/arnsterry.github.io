#!/bin/bash

# --------------------------------------------------------------------------------------------
# PinoyChat Eggdrop + BlackTools / A&A install script
# --------------------------------------------------------------------------------------------
#
# Usage:
#         ./installer.sh [option]
#
#           -i              Install Eggdrop + BlackTools or A&A
#           -r              Add backups / auto-repair / outage protection to ALL existing bots
#           -h, --help      Display script options
#
# --------------------------------------------------------------------------------------------
#
# Optional: each bot can get its own Cloudflare WARP IPv6 (Debian/Ubuntu/Raspberry Pi OS,
# systemd + WireGuard). The installer asks; see the WARP section below.
#
# Tested on:
#           - Debian 12
#           - Ubuntu 22.04 / 24.04
#           - CentOS 9
#           - FreeBSD 13
#           - macOS 14
#
# --------------------------------------------------------------------------------------------
# PinoyChat : irc.pinoychat.fun
# Eggdrop   : https://www.eggheads.org
# BlackTools: https://github.com/tclscripts/BlackTools-TCL
# --------------------------------------------------------------------------------------------

EGGDROP_VER="1.10.1"
EGGDROP_URL="https://ftp.eggheads.org/pub/eggdrop/source/1.10/eggdrop-${EGGDROP_VER}.tar.gz"
BT_ZIP_URL="https://raw.githubusercontent.com/arnsterry/pinoychat-files/main/BlackTools_authfix_patched.zip"
BT_DIR_NAME="BlackTools-TCL-master"
AA_ZIP_URL="https://raw.githubusercontent.com/arnsterry/pinoychat-files/main/a_and_a_light-0_04_00_ipv6.zip"

# -- install package choice: "blacktools" or "aa"
INSTALL_PACKAGE=""

# -- Cloudflare WARP per-bot IPv6 (private network namespace per bot)
USE_WARP="0"
USE_NATIVE6="0"
NATIVE6_ADDR=""
PREFER_IPV6="1"
WARP_NS=""
WARP_IPV6=""

set -u
shopt -s nocasematch
if [ -t 0 ]; then
    stty erase '^?'
fi

abort() {
    printf "%s\n" "$@" >&2
    exit 1
}

if [ -z "${BASH_VERSION:-}" ]; then
    abort "Bash is required to interpret this script."
fi

# -- string formatters
if [[ -t 1 ]]; then
    tty_escape() { printf "\033[%sm" "$1"; }
else
    tty_escape() { :; }
fi
tty_mkbold() { tty_escape "1;$1"; }
tty_underline="$(tty_escape "4;39")"
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

chomp() {
    printf "%s" "${1/"$'\n'"/}"
}

ohai() {
    printf "${tty_blue}==>${tty_bold} %s${tty_reset}\n" "$(shell_join "$@")"
}

warn() {
    printf "${tty_yellow}Warning${tty_reset}: %s\n" "$(chomp "$1")" >&2
}

ring_bell() {
    if [[ -t 1 ]]; then printf "\a"; fi
}

getc() {
    local save_state
    save_state="$(/bin/stty -g)"
    /bin/stty raw -echo
    IFS='' read -r -n 1 -d '' "$@"
    /bin/stty "${save_state}"
}

wait_for_user() {
    local c
    echo
    echo "Press ${tty_bold}RETURN${tty_reset}/${tty_bold}ENTER${tty_reset} to begin, or any other key to abort:"
    getc c
    if ! [[ "${c}" == $'\r' || "${c}" == $'\n' ]]; then
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Check the OS
# ---------------------------------------------------------------------------

OS="$(uname)"
GNUSED=1
if [[ "${OS}" == "Linux" ]]; then
    BT_ON_LINUX=1
elif [[ "${OS}" == "FreeBSD" || "${OS}" == "OpenBSD" || "${OS}" == "NetBSD" ]]; then
    BT_ON_BSD=1
    SYSTEM="${OS}"
    GNUSED=0
elif [[ "${OS}" == "Darwin" ]]; then
    BT_ON_MACOS=1
    SYSTEM="macOS"
    GNUSED=0
else
    echo "${tty_red}Error:${tty_reset} This installer is only supported on Linux, FreeBSD, NetBSD, OpenBSD, and macOS."
    abort
fi

# -- set OS-specific package manager
if [[ -n "${BT_ON_LINUX-}" ]]; then
    SYSTEM="Linux"
    PKGMGR="apt-get"
    PKGMGR_ARGS="install -y"
    PACKAGES="gcc make curl wget git tcl tcl-dev tcllib tcl-tls libssl-dev openssl ca-certificates unzip"
    if [ -f /etc/centos-release ] || [ -f /etc/redhat-release ]; then
        SYSTEM="CentOS/RHEL"
        PKGMGR="yum"
        PKGMGR_ARGS="install -y"
        PACKAGES="gcc make curl wget git tcl tcl-devel tcltls openssl-devel openssl ca-certificates unzip"
    elif [ -f /etc/os-release ]; then
        if grep -q "^ID=ubuntu" /etc/os-release; then
            SYSTEM="Ubuntu"
        elif grep -q "^ID=debian" /etc/os-release; then
            SYSTEM="Debian"
        fi
    fi
elif [[ -n "${BT_ON_BSD-}" ]]; then
    PKGMGR="pkg"
    PKGMGR_ARGS="install -y"
    PACKAGES="curl wget git tcl tcllib tcltls unzip"
elif [[ -n "${BT_ON_MACOS-}" ]]; then
    PKGMGR="brew"
    PKGMGR_ARGS="install"
    PACKAGES="curl wget git tcl-tk unzip"
fi

# ---------------------------------------------------------------------------
# Prerequisite helpers
# ---------------------------------------------------------------------------

check_sudo() {
    if ! command -v sudo >/dev/null; then
        ring_bell
        echo "${tty_red}Error:${tty_reset} ${tty_bold}sudo${tty_reset} is required to install packages from this script."
        abort
    fi
}

install_prereq() {
    check_sudo
    ohai "Installing prerequisites..."
    if [[ "${SYSTEM}" != "macOS" ]]; then
        ohai "sudo ${PKGMGR} ${PKGMGR_ARGS} ${PACKAGES}"
        sudo ${PKGMGR} ${PKGMGR_ARGS} ${PACKAGES}
    else
        ohai "${PKGMGR} ${PKGMGR_ARGS} ${PACKAGES}"
        ${PKGMGR} ${PKGMGR_ARGS} ${PACKAGES}
    fi
    if [ $? -ne 0 ]; then
        echo
        ring_bell
        echo "${tty_red}Error:${tty_reset} Package install failed. Please correct and try again."
        abort
    fi
    echo
    ohai "Done!"
    echo
}

ASKED=0
ask_for_prereq() {
    local input
    echo
    ohai "Do you wish to install prerequisite packages? (${tty_green}Y${tty_reset})es or (${tty_green}N${tty_reset})o"
    echo
    echo "    ${PKGMGR} ${PKGMGR_ARGS} ${PACKAGES}"
    echo
    getc input
    if [[ "${input}" == 'y' ]]; then
        install_prereq
    elif [[ "${input}" == 'n' ]]; then
        warn "Skipping prerequisite install. The build will fail if they are missing."
        echo
    else
        ring_bell
        warn "Invalid input, please select (${tty_green}Y${tty_reset})es or (${tty_green}N${tty_reset})o"
        ask_for_prereq
    fi
}

check_prereqs() {
    local missing=0
    for cmd in gcc make wget unzip; do
        if ! command -v "$cmd" >/dev/null; then
            ring_bell
            echo
            echo "${tty_red}Error:${tty_reset} Required tool ${tty_bold}${cmd}${tty_reset} is not installed."
            missing=1
        fi
    done
    if [ "$missing" -eq 1 ]; then
        ask_for_prereq
    fi
}

# ---------------------------------------------------------------------------
# TCL auto-detection
# ---------------------------------------------------------------------------

find_tcl() {
    TCL_CONFIG_ARG=""
    local best_ver=0
    local best_dir=""

    local search_paths=(
        /usr/lib
        /usr/lib64
        /usr/local/lib
        /usr/lib/x86_64-linux-gnu
        /usr/lib/aarch64-linux-gnu
        /usr/lib/arm-linux-gnueabihf
        /opt/homebrew/lib
        /usr/local/opt/tcl-tk/lib
    )

    local found_dirs
    found_dirs=$(find /usr /opt /usr/local -maxdepth 5 -name "tclConfig.sh" 2>/dev/null | xargs -I{} dirname {})
    while IFS= read -r d; do
        search_paths+=("$d")
    done <<< "$found_dirs"

    for dir in "${search_paths[@]}"; do
        local cfg="${dir}/tclConfig.sh"
        [ -f "$cfg" ] || continue
        local ver
        ver=$(grep -E "^TCL_VERSION=" "$cfg" 2>/dev/null | head -1 | sed "s/TCL_VERSION='\([^']*\)'.*/\1/;s/TCL_VERSION=\"\([^\"]*\)\".*/\1/;s/TCL_VERSION=//")
        [ -z "$ver" ] && continue
        local major minor
        major=$(echo "$ver" | cut -d. -f1)
        minor=$(echo "$ver" | cut -d. -f2)
        local ver_int=$(( major * 100 + minor ))
        if [ "$ver_int" -ge 805 ] && [ "$ver_int" -gt "$best_ver" ]; then
            best_ver=$ver_int
            best_dir="$dir"
        fi
    done

    if [ -n "$best_dir" ]; then
        local tcl_ver_str="$(( best_ver / 100 )).$(( best_ver % 100 ))"
        ohai "Found Tcl ${tcl_ver_str} in: ${tty_green}${best_dir}${tty_reset}"

        local inc_dir=""
        local cfg_inc
        cfg_inc=$(grep -E "^TCL_INCLUDE_SPEC=" "${best_dir}/tclConfig.sh" 2>/dev/null | head -1 \
                  | sed "s/TCL_INCLUDE_SPEC='\([^']*\)'.*/\1/;s/TCL_INCLUDE_SPEC=\"\([^\"]*\)\".*/\1/;s/TCL_INCLUDE_SPEC=//" \
                  | sed 's/^-I//')
        local inc_search=(
            "/usr/include/tcl${tcl_ver_str}"
            "/usr/include/tcl$(( best_ver / 100 ))"
            "/usr/local/include/tcl${tcl_ver_str}"
            "/usr/local/include/tcl$(( best_ver / 100 ))"
            "/usr/include"
            "/usr/local/include"
            "/opt/homebrew/include"
            "/usr/local/opt/tcl-tk/include"
        )
        [ -n "$cfg_inc" ] && inc_search=("$cfg_inc" "${inc_search[@]}")
        for d in "${inc_search[@]}"; do
            if [ -f "${d}/tcl.h" ]; then
                inc_dir="$d"
                break
            fi
        done

        local tcl_so=""
        for soname in \
            "libtcl${tcl_ver_str}.so" \
            "libtcl$(( best_ver / 100 )).so" \
            "libtcl.so" \
            "libtcl${tcl_ver_str}.so.1" \
            "libtcl${tcl_ver_str}.dylib" \
            "libtcl.dylib"
        do
            if [ -f "${best_dir}/${soname}" ]; then
                tcl_so="${best_dir}/${soname}"
                break
            fi
        done
        if [ -z "$tcl_so" ]; then
            tcl_so=$(find /usr /opt /usr/local -maxdepth 6 \
                \( -name "libtcl${tcl_ver_str}.so" -o -name "libtcl${tcl_ver_str}.dylib" \) 2>/dev/null | head -1)
        fi

        if [ -n "$inc_dir" ] && [ -n "$tcl_so" ]; then
            ohai "Found Tcl headers : ${tty_green}${inc_dir}/tcl.h${tty_reset}"
            ohai "Found Tcl library : ${tty_green}${tcl_so}${tty_reset}"
            TCL_CONFIG_ARG="--with-tcllib=${tcl_so} --with-tclinc=${inc_dir}/tcl.h"
        elif [ -n "$tcl_so" ]; then
            warn "Could not locate tcl.h — passing only --with-tcllib. Install tcl-dev if configure fails."
            TCL_CONFIG_ARG="--with-tcllib=${tcl_so}"
        else
            warn "Could not locate libtcl .so — configure will attempt autodetect."
            TCL_CONFIG_ARG=""
        fi
    else
        echo
        ring_bell
        echo "${tty_red}Error:${tty_reset} Could not find a suitable Tcl installation (>= 8.5)."
        echo "       On Debian/Ubuntu:  sudo apt-get install tcl tcl-dev"
        echo "       On CentOS/RHEL:    sudo yum install tcl tcl-devel"
        abort
    fi
}

# ---------------------------------------------------------------------------
# Network helpers
# ---------------------------------------------------------------------------

getIPv4() {
    if command -v ip >/dev/null; then
        IP4ADDRESS=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n 1)
    elif command -v ifconfig >/dev/null; then
        IP4ADDRESS=$(ifconfig | grep -E 'inet [0-9]' | grep -v '127.0.0.1' | awk '{print $2}' | head -n 1)
    else
        IP4ADDRESS=""
    fi
}

getIPv6() {
    if command -v ip >/dev/null; then
        IP6ADDRESS=$(ip -6 addr show | grep -oP '(?<=inet6\s)[\da-f:]+' | grep -v '^::1' | grep -v '^fe80' | head -n 1)
    elif command -v ifconfig >/dev/null; then
        IP6ADDRESS=$(ifconfig | grep -E 'inet6 ' | grep -v '::1' | grep -v 'fe80' | awk '{print $2}' | head -n 1)
    else
        IP6ADDRESS=""
    fi
}

getPort() {
    START_PORT=42420
    END_PORT=42519
    for ((PORT=START_PORT; PORT<=END_PORT; PORT++)); do
        if [[ " FreeBSD OpenBSD NetBSD Darwin " == *" ${OS} "* ]]; then
            if ! netstat -an | grep -E ".*\.$PORT .*LISTEN" >/dev/null 2>&1; then break; fi
        else
            if ! lsof -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then break; fi
        fi
    done
}

# ---------------------------------------------------------------------------
# Input helper
# ---------------------------------------------------------------------------

NOEMPTY=0
NUMERIC=0

ask_for_setting_value() {
    local setting_name="$1"
    local current_value="$2"
    read -r -p "    Enter value for ${tty_green}${setting_name}${tty_reset} [${tty_blue}${current_value}${tty_reset}]: " new_value </dev/tty
    echo

    if [[ "${NOEMPTY}" == "1" && "${new_value}" == "" && "${current_value}" == "" ]]; then
        ring_bell
        warn "A value is required for ${tty_green}${setting_name}${tty_reset}."
        echo
        ask_for_setting_value "$setting_name" "$current_value"
        return
    fi

    if [[ "${new_value}" == "" ]]; then
        new_value="${current_value}"
    fi

    if [[ "${NUMERIC}" == "1" && ! "${new_value}" =~ ^[0-9]+$ ]]; then
        ring_bell
        warn "Setting ${tty_green}${setting_name}${tty_reset} must be a ${tty_green}numeric${tty_reset} value."
        echo
        ask_for_setting_value "$setting_name" "$current_value"
        return
    fi
}

# ---------------------------------------------------------------------------
# Realname (GECOS) IRC color-code helper
# ---------------------------------------------------------------------------
#
# Converts a leading "NN " (1-2 digit mIRC color number followed by a space)
# into a real \x03 mIRC color-code byte, and converts literal "\002"/"\035"/
# "\037"/"\003" escape sequences the user may type into their real control
# bytes (bold, italic, underline, color-reset). Implemented in pure bash
# (no python3/perl dependency) so it works reliably regardless of which
# optional interpreters happen to be installed on the target system.
# ---------------------------------------------------------------------------

colorize_realname() {
    local val="$1"
    local c02 c1d c1f c03
    c02=$'\x02'; c1d=$'\x1d'; c1f=$'\x1f'; c03=$'\x03'

    if [[ "${val}" =~ ^([0-9]{1,2})\ (.*)$ ]]; then
        local num="${BASH_REMATCH[1]}"
        local rest="${BASH_REMATCH[2]}"
        printf -v num "%02d" "${num}"
        val="${c03}${num} ${rest}"
    fi

    val="${val//\\002/${c02}}"
    val="${val//\\035/${c1d}}"
    val="${val//\\037/${c1f}}"
    val="${val//\\003/${c03}}"

    printf '%s' "${val}"
}

# ---------------------------------------------------------------------------
# Network selection
# ---------------------------------------------------------------------------

NETWORK=""
BOTSERVER=""
BOTPORT="6667"

ask_for_network() {
    local input
    echo
    ohai "Which IRC network is this bot connecting to?"
    echo
    echo "        ${tty_green}1${tty_reset}: PinoyChat  ${tty_blue}(irc.pinoychat.fun)${tty_reset}"
    echo "        ${tty_green}2${tty_reset}: Undernet   ${tty_blue}(irc.undernet.org)${tty_reset}"
    echo "        ${tty_green}3${tty_reset}: DALnet     ${tty_blue}(irc.dal.net)${tty_reset}"
    echo "        ${tty_green}4${tty_reset}: Libera     ${tty_blue}(irc.libera.chat)${tty_reset}"
    echo "        ${tty_green}5${tty_reset}: EFnet      ${tty_blue}(irc.efnet.org)${tty_reset}"
    echo "        ${tty_green}6${tty_reset}: Other"
    echo
    getc input
    if [ "${input}" == '1' ]; then
        NETWORK="PinoyChat"
        BOTSERVER="irc.pinoychat.fun"
        BOTPORT="6667"
    elif [ "${input}" == '2' ]; then
        NETWORK="Undernet"
        BOTSERVER="irc.undernet.org"
        BOTPORT="6667"
    elif [ "${input}" == '3' ]; then
        NETWORK="DALnet"
        BOTSERVER="irc.dal.net"
        BOTPORT="6667"
    elif [ "${input}" == '4' ]; then
        NETWORK="Libera"
        BOTSERVER="irc.libera.chat"
        BOTPORT="6667"
    elif [ "${input}" == '5' ]; then
        NETWORK="EFnet"
        BOTSERVER="irc.efnet.org"
        BOTPORT="6667"
    elif [ "${input}" == '6' ]; then
        NETWORK="Other"
        BOTSERVER=""
        BOTPORT="6667"
    else
        ring_bell
        warn "Invalid input, please select a number from the list."
        ask_for_network
        return
    fi
    echo
    ohai "Network set to: ${tty_green}${NETWORK}${tty_reset}"
    echo
    if [ "${NETWORK}" == "DALnet" ]; then
        ask_dalnet_menu
    else
        DAL_ENABLED="0"
    fi
}

# ---------------------------------------------------------------------------
# DALnet extras: NickServ login + host display (own menu, only shown for DALnet)
# ---------------------------------------------------------------------------

DAL_ENABLED="0"
DAL_NICKPASS=""
DAL_MODES=""
DAL_SRC_LINE=""

ask_dalnet_menu() {
    local input
    DAL_ENABLED="1"
    DAL_NICKPASS=""
    DAL_MODES=""

    echo
    echo "    ${tty_blue}╔══════════════════════════════════════════════════════════╗${tty_reset}"
    echo "    ${tty_blue}║${tty_reset}                 ${tty_bold}D A L n e t   S E T U P${tty_reset}                  ${tty_blue}║${tty_reset}"
    echo "    ${tty_blue}╚══════════════════════════════════════════════════════════╝${tty_reset}"
    echo
    echo "    ${tty_bold}Step 1 of 2  -  NickServ login${tty_reset}"
    echo "    ${tty_blue}────────────────────────────────${tty_reset}"
    echo "      ${tty_green}1${tty_reset}  The bot's nick is ${tty_bold}already registered${tty_reset} - log in to NickServ automatically"
    echo "      ${tty_green}2${tty_reset}  Not registered - do not log in"
    echo
    ohai "Choose ${tty_green}1${tty_reset} or ${tty_green}2${tty_reset}:"
    echo
    while true; do
        getc input
        case "${input}" in
            1)
                echo
                echo "    Enter the NickServ password of the bot's registered nick."
                echo "    (typing is hidden; it is saved only in the bot's scripts/dalnet.tcl, readable by you only)"
                printf '    NickServ password: ' > /dev/tty
                stty -echo < /dev/tty 2>/dev/null
                IFS= read -r DAL_NICKPASS < /dev/tty
                stty echo < /dev/tty 2>/dev/null
                printf '\n' > /dev/tty
                if [ -z "${DAL_NICKPASS}" ]; then
                    warn "Empty password - NickServ login disabled."
                else
                    ohai "NickServ login ${tty_green}enabled${tty_reset}."
                fi
                break
                ;;
            2)
                echo
                ohai "NickServ login ${tty_green}off${tty_reset}."
                break
                ;;
            *) ring_bell ;;
        esac
    done

    echo
    echo "    ${tty_bold}Step 2 of 2  -  What /whois shows${tty_reset}"
    echo "    ${tty_blue}────────────────────────────────${tty_reset}"
    echo "      ${tty_green}1${tty_reset}  Show the bot's ${tty_bold}real IPv6 / IPv4${tty_reset}"
    echo "         sends  /mode BOTNAME -x  and  /mode BOTNAME -H  after every connect"
    echo "         (-x removes DALnet's host masking; -H is sent too, servers that don't know it ignore it)"
    echo "      ${tty_green}2${tty_reset}  Keep DALnet's masked host"
    echo
    ohai "Choose ${tty_green}1${tty_reset} or ${tty_green}2${tty_reset}:"
    echo
    while true; do
        getc input
        case "${input}" in
            1) DAL_MODES="-x -H"; echo; ohai "Real address ${tty_green}will be shown${tty_reset} (modes: ${DAL_MODES})."; break ;;
            2) echo; ohai "Masked host ${tty_green}kept${tty_reset}."; break ;;
            *) ring_bell ;;
        esac
    done
    echo
    echo "    ${tty_yellow}Note:${tty_reset} for IPv6 pick an IPv6-capable DALnet server in the next question."
    echo
}

# writes scripts/dalnet.tcl (and DAL_SRC_LINE, the line that loads it) - only when DALnet was chosen
write_dalnet_script() {
    DAL_SRC_LINE=""
    [ "${DAL_ENABLED}" == "1" ] || return 0
    [ -n "${DAL_NICKPASS}" ] || [ -n "${DAL_MODES}" ] || return 0

    local f="${EGGDROP_INSTALL_DIR}/scripts/dalnet.tcl" pw
    mkdir -p "${EGGDROP_INSTALL_DIR}/scripts"
    # make the password safe inside a Tcl "..." string
    pw="$(printf '%s' "${DAL_NICKPASS}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\$/\\$/g' -e 's/\[/\\[/g')"
    {
        printf '# dalnet.tcl - written by the PinoyChat installer\n'
        printf 'set dal(nickpass) "%s"\n' "${pw}"
        printf 'set dal(modes)    "%s"\n' "${DAL_MODES}"
        cat <<'DALEOF'
set dal(nickserv) "NickServ@services.dal.net"

# On every (re)connect eggdrop calls init-server when the server says "001", just BEFORE it sends its JOINs.
# Everything is sent with putquick, which goes out first, so the login and the modes are in place
# before the bot joins any channel. The modes are repeated a few seconds later as a safety net.
bind evnt - init-server dal:onconnect

proc dal:onconnect {type} {
    global dal
    if {$dal(nickpass) ne ""} {
        putquick "PRIVMSG $dal(nickserv) :IDENTIFY $dal(nickpass)"
    }
    if {$dal(modes) ne ""} {
        dal:setmodes
        utimer 6  dal:setmodes
        utimer 20 dal:setmodes
    }
}

proc dal:setmodes {} {
    global dal botnick
    foreach m $dal(modes) {
        putquick "MODE $botnick $m"
    }
}
putlog "dalnet.tcl loaded"
DALEOF
    } > "${f}"
    chmod 600 "${f}" 2>/dev/null
    DAL_SRC_LINE="catch {source scripts/dalnet.tcl}"
    ohai "[${tty_blue}Written${tty_reset}] ${tty_green}${f}${tty_reset}"
}

# ---------------------------------------------------------------------------
# Eggdrop install dir
# ---------------------------------------------------------------------------

EGGDROP_INSTALL_DIR=""

ask_for_install_dir() {
    local input
    echo
    ohai "Where should Eggdrop be installed? [${tty_green}${HOME}/eggdrop${tty_reset}]"
    echo
    read -r -p "    Directory: " input </dev/tty
    EGGDROP_INSTALL_DIR="${input:-${HOME}/eggdrop}"
    echo
    if [ -d "${EGGDROP_INSTALL_DIR}" ]; then
        ring_bell
        echo "${tty_red}Error:${tty_reset} Directory ${tty_green}${EGGDROP_INSTALL_DIR}${tty_reset} already exists. Please choose another."
        ask_for_install_dir
        return
    fi
    ohai "Using install directory: ${tty_green}${EGGDROP_INSTALL_DIR}${tty_reset}"
}

# ---------------------------------------------------------------------------
# Cloudflare WARP: one private tunnel (network namespace) per bot
# ---------------------------------------------------------------------------
# A bot that opts in gets its OWN WARP account + WireGuard tunnel inside a
# private network namespace. Each bot therefore shows a different Cloudflare
# IPv6 and can never leak this machine's real IP.
# Needs: Linux + systemd + apt (Debian / Ubuntu / Raspberry Pi OS) and kernel
# WireGuard support. Everything is installed once and re-used by every bot.
#
# Commands this section installs into /usr/local/bin:
#   warpns-name  BOT        short tunnel name used for a bot
#   warpns-up    NAME       (internal) builds the namespace + tunnel
#   warpns-wait  NAME       waits until the tunnel works, prints its IPv6
#   warpns-new   NAME       creates a new WARP account + tunnel
#   warpns-bind  SVC NAME   attaches a systemd bot service to a tunnel
#   warpbot      BOT        existing bot  -> tunnel (one command)
#   warpfirst    BOT        brand-new bot -> first run (-m) + tunnel
# ---------------------------------------------------------------------------

warp_system_warp_check() {
    # System-wide warp-cli makes every per-bot tunnel nest inside it and come
    # out on the SAME address, so it has to be OFF. Ask first: turning it off
    # exposes the real IP of any bot that is not inside its own tunnel.
    command -v warp-cli >/dev/null 2>&1 || return 0
    echo y | warp-cli status 2>/dev/null | grep -qiE 'Status update: *Connected' || return 0

    local input
    echo
    ohai "System-wide WARP (warp-cli) is currently ${tty_green}ON${tty_reset}."
    echo "    Per-bot tunnels only get ${tty_bold}different${tty_reset} IPv6 addresses while it is OFF."
    echo "    ${tty_yellow}Turning it off exposes this machine's real IP for any bot that is NOT${tty_reset}"
    echo "    ${tty_yellow}inside its own tunnel (for example older bots started with ./eggdrop).${tty_reset}"
    echo
    ohai "Turn system-wide WARP off now? (${tty_green}Y${tty_reset})es or (${tty_green}N${tty_reset})o"
    echo
    while true; do
        getc input
        case "${input}" in
            y) break ;;
            n) warn "Leaving warp-cli ON: your bots may all show the SAME IPv6 until you run: warp-cli disconnect"
               return 0 ;;
            "") return 0 ;;
            *) ring_bell ;;
        esac
    done

    echo y | warp-cli disconnect >/dev/null 2>&1
    sleep 3
    if ! getent hosts github.com >/dev/null 2>&1; then
        if command -v tailscale >/dev/null 2>&1; then
            ohai "DNS stopped working without WARP (Tailscale was managing DNS). Applying: tailscale set --accept-dns=false"
            sudo tailscale set --accept-dns=false
            sleep 2
        fi
        if ! getent hosts github.com >/dev/null 2>&1; then
            warn "Still no DNS - writing public resolvers (1.1.1.1 / 8.8.8.8) to /etc/resolv.conf"
            printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' | sudo tee /etc/resolv.conf >/dev/null
            sleep 1
        fi
    fi
    if getent hosts github.com >/dev/null 2>&1; then
        ohai "System-wide WARP is ${tty_green}OFF${tty_reset} and DNS works."
    else
        warn "DNS still fails with WARP off - reconnecting system-wide WARP."
        echo y | warp-cli connect >/dev/null 2>&1
    fi
    echo
}

install_warp_toolkit() {
    check_sudo
    echo
    echo "    ${tty_green}============================================================${tty_reset}"
    ohai "Setting up the ${tty_green}WARP per-bot toolkit${tty_reset} (safe to re-run)..."
    echo "    ${tty_green}============================================================${tty_reset}"
    echo

    # -- 1. packages
    ohai "Installing wireguard-tools..."
    sudo apt-get update -qq >/dev/null 2>&1 || true
    sudo apt-get install -y wireguard-tools curl ca-certificates iproute2 || {
        warn "Could not install wireguard-tools."
        return 1
    }

    # -- 2. kernel WireGuard module (and load it on every boot)
    if ! sudo modprobe wireguard 2>/dev/null; then
        warn "This kernel has no WireGuard support (modprobe wireguard failed)."
        return 1
    fi
    echo wireguard | sudo tee /etc/modules-load.d/wireguard.conf >/dev/null

    # -- 3. wgcf (creates free WARP accounts / WireGuard profiles)
    if ! command -v wgcf >/dev/null 2>&1; then
        local arch tag ver wurl
        case "$(uname -m)" in
            aarch64 | arm64) arch="arm64" ;;
            x86_64 | amd64)  arch="amd64" ;;
            armv7l | armv7)  arch="armv7" ;;
            i?86)            arch="386" ;;
            *) warn "Unsupported CPU type: $(uname -m)"; return 1 ;;
        esac
        ohai "Downloading wgcf (${arch})..."
        tag=$(curl -sIL -o /dev/null -w '%{url_effective}' https://github.com/ViRb3/wgcf/releases/latest | sed 's|.*/tag/||')
        case "${tag}" in v[0-9]*) ;; *) tag="v2.3.0" ;; esac
        ver="${tag#v}"
        wurl="https://github.com/ViRb3/wgcf/releases/download/${tag}/wgcf_${ver}_linux_${arch}"
        if curl -fsSL -o "/tmp/wgcf.$$" "${wurl}"; then
            sudo install -m 755 "/tmp/wgcf.$$" /usr/local/bin/wgcf
        fi
        rm -f "/tmp/wgcf.$$"
        command -v wgcf >/dev/null 2>&1 || { warn "Could not install wgcf."; return 1; }
    fi

    # -- 4. the helper commands
    ohai "Writing helper commands to /usr/local/bin ..."
    sudo mkdir -p /etc/warpns
    sudo chmod 700 /etc/warpns

    sudo tee /usr/local/bin/warpns-name >/dev/null <<'WARPEOF_NAME'
#!/bin/bash
# prints the short tunnel/namespace name for a bot (lowercase letters+digits, max 12 chars)
b=$1; [ -n "$b" ] || exit 1
n=$(printf '%s' "$b" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9')
[ -n "$n" ] || n=bot
if [ ${#n} -gt 12 ]; then n="${n:0:8}$(printf '%s' "$b" | md5sum | cut -c1-4)"; fi
echo "$n"
WARPEOF_NAME

    sudo tee /usr/local/bin/warpns-up >/dev/null <<'WARPEOF_UP'
#!/bin/bash
# (internal) builds the private namespace + WireGuard tunnel for /etc/warpns/NAME.conf
set -e
n=$1; c=/etc/warpns/$n.conf
ip netns del $n 2>/dev/null || true
ip netns add $n
ip link add wg-$n type wireguard
wg setconf wg-$n <(wg-quick strip $c)
# keep the NAT mapping alive so the server can always reach the bot (prevents "Ping timeout")
for k in $(wg show wg-$n peers); do wg set wg-$n peer "$k" persistent-keepalive 25; done
ip link set wg-$n netns $n
a4=$(grep -E '^Address' $c | grep -oE '[0-9.]+/32' | head -1)
a6=$(grep -E '^Address' $c | grep -oE '[0-9a-f:]+/128' | head -1)
ip -n $n link set lo up
ip -n $n addr add $a4 dev wg-$n
[ -n "$a6" ] && ip -n $n -6 addr add $a6 dev wg-$n
ip -n $n link set wg-$n mtu 1280 up
ip -n $n route add default dev wg-$n
[ -n "$a6" ] && ip -n $n -6 route add default dev wg-$n
mkdir -p /etc/netns/$n
printf 'nameserver 1.1.1.1\nnameserver 2606:4700:4700::1111\n' > /etc/netns/$n/resolv.conf
WARPEOF_UP

    sudo tee /usr/local/bin/warpns-wait >/dev/null <<'WARPEOF_WAIT'
#!/bin/bash
# usage: warpns-wait NAME  -> prints the tunnel's public IPv6; exit 0 once it works
n=$1; [ -n "$n" ] || { echo "usage: warpns-wait NAME" >&2; exit 1; }
for i in 1 2 3 4 5 6; do
  addr=$(ip netns exec $n curl -6 -s -m 10 https://ipv6.icanhazip.com 2>/dev/null)
  if [ -n "$addr" ]; then echo "$addr"; exit 0; fi
  systemctl restart wgns@$n; sleep 5
done
exit 1
WARPEOF_WAIT

    sudo tee /usr/local/bin/warpns-new >/dev/null <<'WARPEOF_NEW'
#!/bin/bash
# usage: warpns-new NAME -> registers a NEW free WARP account and starts its tunnel
set -e
n=$1; [ -n "$n" ] || { echo "usage: warpns-new NAME"; exit 1; }
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT; cd "$d"
wgcf register --accept-tos
wgcf generate
mkdir -p /etc/warpns; chmod 700 /etc/warpns
saved=$(cat /etc/warpns/.port 2>/dev/null || true)
declare -A seen; good=""
# try UDP ports until Cloudflare answers (some networks block 2408)
for p in $saved 4500 2408 500 1701; do
  [ -n "${seen[$p]:-}" ] && continue
  seen[$p]=1
  sed -i -E "s|^Endpoint = .*|Endpoint = 162.159.192.1:$p|" wgcf-profile.conf
  install -m 600 wgcf-profile.conf /etc/warpns/$n.conf
  systemctl enable wgns@$n >/dev/null 2>&1 || true
  systemctl restart wgns@$n || true
  sleep 2
  ip netns exec $n curl -4 -s -m 8 -o /dev/null https://icanhazip.com || true
  hs=$(ip netns exec $n wg show wg-$n latest-handshakes 2>/dev/null | awk '{print $2; exit}')
  if [ -n "$hs" ] && [ "$hs" != "0" ]; then good=$p; break; fi
done
if [ -n "$good" ]; then
  echo "$good" > /etc/warpns/.port
  echo "WARP tunnel $n is up (UDP port $good)."
else
  echo "WARNING: no handshake yet for tunnel $n - it will be retried automatically."
fi
exit 0
WARPEOF_NEW

    sudo tee /usr/local/bin/warpns-bind >/dev/null <<'WARPEOF_BIND'
#!/bin/bash
# usage: warpns-bind SERVICE NAME -> the bot service now runs INSIDE tunnel NAME
set -e
s=$1; n=$2; [ -n "$n" ] || { echo "usage: warpns-bind SERVICE NAME"; exit 1; }
mkdir -p /etc/systemd/system/$s.service.d
cat > /etc/systemd/system/$s.service.d/ns.conf <<EOT
[Unit]
Requires=wgns@$n.service
After=wgns@$n.service
[Service]
NetworkNamespacePath=/run/netns/$n
BindReadOnlyPaths=/etc/netns/$n/resolv.conf:/etc/resolv.conf
EOT
systemctl daemon-reload
systemctl restart $s
echo "$s now runs inside tunnel $n"
WARPEOF_BIND

    sudo tee /usr/local/bin/warpbot >/dev/null <<'WARPEOF_BOT'
#!/bin/bash
# usage: sudo warpbot BOTNAME -> put an EXISTING bot service inside its own tunnel
set -e
bot=$1; [ -n "$bot" ] || { echo "usage: sudo warpbot BOTNAME"; exit 1; }
svc=eggdrop-$bot
[ -f /etc/systemd/system/$svc.service ] || { echo "Service $svc not found. Check: systemctl list-units 'eggdrop-*' --all"; exit 1; }
n=$(warpns-name "$bot")
wd=$(systemctl show $svc -p WorkingDirectory --value)
u=$(systemctl show $svc -p User --value)
conf=$(grep -oE '[A-Za-z0-9_.-]+\.conf' /etc/systemd/system/$svc.service | grep -v warp | head -1)
if [ -f "$wd/$conf" ]; then
  if [ -n "$u" ]; then runuser -u "$u" -- sed -i -E 's/^(set +(vhost4|vhost6|my-ip|my-ip6) )/#\1/' "$wd/$conf"
  else sed -i -E 's/^(set +(vhost4|vhost6|my-ip|my-ip6) )/#\1/' "$wd/$conf"; fi
fi
[ -f /etc/warpns/$n.conf ] || warpns-new $n
addr=$(warpns-wait $n) || { echo "TUNNEL NOT UP - bot left unchanged"; exit 1; }
warpns-bind $svc $n
sleep 5
echo "Tunnel IPv6 for $bot: $addr"
systemctl status $svc --no-pager | head -4
WARPEOF_BOT

    sudo tee /usr/local/bin/warpfirst >/dev/null <<'WARPEOF_FIRST'
#!/bin/bash
# usage: sudo warpfirst BOTNAME -> NEW bot: first run (-m) inside its tunnel, then hand over to systemd
bot=$1; [ -n "$bot" ] || { echo "usage: sudo warpfirst BOTNAME"; exit 1; }
svc=eggdrop-$bot
[ -f /etc/systemd/system/$svc.service ] || { echo "Service $svc not found"; exit 1; }
n=$(warpns-name "$bot")
wd=$(systemctl show $svc -p WorkingDirectory --value)
u=$(systemctl show $svc -p User --value)
conf=$(grep -oE '[A-Za-z0-9_.-]+\.conf' /etc/systemd/system/$svc.service | grep -v warp | head -1)
runuser -u "$u" -- sed -i -E 's/^(set +(vhost4|vhost6|my-ip|my-ip6) )/#\1/' "$wd/$conf"
[ -f /etc/warpns/$n.conf ] || warpns-new $n || true
addr=$(warpns-wait $n) || { echo "TUNNEL NOT UP - bot not started"; exit 1; }
echo "Tunnel IPv6 for $bot: $addr"
ip netns exec $n sudo -u $u -H bash -c "cd '$wd' && ./eggdrop -m '$conf'"
echo
read -p "Say hello to the bot on IRC. Press Enter here when finished: "
pkill -u $u -f "eggdrop.*$conf" || true
sleep 2
warpbot $bot
WARPEOF_FIRST

    sudo tee /etc/systemd/system/wgns@.service >/dev/null <<'WARPEOF_UNIT'
[Unit]
Description=WARP namespace %i
After=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/warpns-up %i
ExecStop=/usr/bin/ip netns del %i
[Install]
WantedBy=multi-user.target
WARPEOF_UNIT

    sudo tee /usr/local/bin/warpns-watchdog >/dev/null <<'WARPEOF_WD'
#!/bin/bash
# Run every minute by warpns-watchdog.timer.
# Heals a dead WARP tunnel - but ONLY while this machine itself has internet.
# When the whole connection is down (overdue bill, router off) every tunnel looks dead; restarting
# them would kill all bots in the middle of saving their userfiles and shuffle UDP ports for nothing.
st=/run/warpns-watchdog; mkdir -p "$st"
ports=(4500 2408 500 1701)
host_online() {
  ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 || ping -c1 -W3 8.8.8.8 >/dev/null 2>&1 || \
    curl -4 -s -m 6 -o /dev/null https://1.1.1.1
}
alive() { ip netns exec "$1" curl -6 -s -m 8 -o /dev/null https://ipv6.icanhazip.com; }
now=$(date +%s)
if ! host_online; then
  [ -e "$st/offline" ] || logger -t warpns-watchdog "no internet on the host - leaving tunnels and bots alone"
  touch "$st/offline"; rm -f "$st"/*.fails "$st"/*.restarts; exit 0
fi
if [ -e "$st/offline" ]; then
  rm -f "$st/offline"; echo "$now" > "$st/back"
  logger -t warpns-watchdog "internet is back - waiting 5 minutes before touching any tunnel"
fi
if [ -e "$st/back" ] && [ $(( now - $(cat "$st/back") )) -lt 300 ]; then exit 0; fi
for f in /etc/warpns/*.conf; do
  [ -f "$f" ] || continue
  n=$(basename "$f" .conf)
  ip netns list | grep -qw "$n" || continue
  if alive "$n"; then rm -f "$st/$n.fails" "$st/$n.restarts"; continue; fi
  c=$(( $(cat "$st/$n.fails" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$st/$n.fails"
  [ "$c" -ge 3 ] || continue                                   # 3 failed checks in a row
  if [ -e "$st/$n.last" ] && [ $(( now - $(stat -c %Y "$st/$n.last") )) -lt 600 ]; then continue; fi  # 10 min cooldown
  touch "$st/$n.last"; echo 0 > "$st/$n.fails"
  r=$(( $(cat "$st/$n.restarts" 2>/dev/null || echo 0) + 1 )); echo "$r" > "$st/$n.restarts"
  logger -t warpns-watchdog "tunnel $n is dead (internet is up) - restarting it"
  systemctl restart "wgns@$n"; sleep 12
  if alive "$n"; then rm -f "$st/$n.restarts"; continue; fi
  if [ "$r" -ge 2 ]; then                                       # only change port after 2 failed restarts
    cur=$(grep -oE '^Endpoint = [0-9.]+:[0-9]+' "$f" | grep -oE '[0-9]+$')
    next=4500
    for i in 0 1 2 3; do [ "${ports[$i]}" = "$cur" ] && next=${ports[$(( (i+1) % 4 ))]}; done
    sed -i -E "s|^(Endpoint = [0-9.]+:)[0-9]+|\1$next|" "$f"
    logger -t warpns-watchdog "tunnel $n still dead - switching UDP port $cur -> $next"
    systemctl restart "wgns@$n"
  fi
done
exit 0
WARPEOF_WD

    sudo tee /etc/systemd/system/warpns-watchdog.service >/dev/null <<'WARPEOF_WDS'
[Unit]
Description=Heal dead WARP tunnels
[Service]
Type=oneshot
ExecStart=/usr/local/bin/warpns-watchdog
WARPEOF_WDS

    sudo tee /etc/systemd/system/warpns-watchdog.timer >/dev/null <<'WARPEOF_WDT'
[Unit]
Description=Check WARP tunnels every minute
[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
[Install]
WantedBy=timers.target
WARPEOF_WDT

    sudo chmod +x /usr/local/bin/warpns-name /usr/local/bin/warpns-up /usr/local/bin/warpns-wait \
                  /usr/local/bin/warpns-new /usr/local/bin/warpns-bind /usr/local/bin/warpbot \
                  /usr/local/bin/warpfirst /usr/local/bin/warpns-watchdog
    sudo systemctl daemon-reload
    sudo systemctl enable --now warpns-watchdog.timer >/dev/null 2>&1

    # -- 5. system-wide WARP must be off for per-bot addresses to differ
    warp_system_warp_check

    echo
    ohai "WARP toolkit ${tty_green}ready${tty_reset}."
    echo
    return 0
}

# One-time setup of the "own IPv6 address per bot" helper (no tunnel, nothing shared).
install_native6_toolkit() {
    check_sudo
    echo
    ohai "Setting up ${tty_green}own IPv6 address per bot${tty_reset}..."
    if ! command -v ip >/dev/null 2>&1; then
        warn "The 'ip' command is missing (package iproute2)."
        return 1
    fi
    if [ -z "$(ip -6 route show default 2>/dev/null)" ]; then
        warn "This machine has no IPv6 default route, so it has no IPv6 connectivity."
        return 1
    fi
    sudo tee /usr/local/bin/botip6 >/dev/null <<'BOTIP6EOF'
#!/bin/bash
# usage: sudo botip6 [--no-restart] BOTNAME
# Gives an eggdrop bot its OWN IPv6 address from this machine's IPv6 block (/64),
# keeps it after reboots, and binds the bot to it (vhost6).
set -e
restart=1; [ "$1" = "--no-restart" ] && { restart=0; shift; }
bot=$1; [ -n "$bot" ] || { echo "usage: sudo botip6 [--no-restart] BOTNAME"; exit 1; }
svc=eggdrop-$bot
[ -f /etc/systemd/system/$svc.service ] || { echo "Service $svc not found. Check: systemctl list-units 'eggdrop-*' --all"; exit 1; }
n=$(printf '%s' "$bot" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9'); [ -n "$n" ] || n=bot
cfg=/etc/botip6/$n.conf
mkdir -p /etc/botip6
if [ -f "$cfg" ]; then
  . "$cfg"
else
  IF=$(ip -6 route show default | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
  [ -n "$IF" ] || { echo "This machine has no IPv6 default route (no IPv6 connectivity)."; exit 1; }
  PFX=$(ip -6 route show dev "$IF" | awk '$1 ~ /^[23][0-9a-f]*:[0-9a-f:]*::\/64$/ {sub(/::\/64$/,"",$1); print $1; exit}')
  [ -n "$PFX" ] || PFX=$(ip -6 -o addr show dev "$IF" scope global | awk '{print $4}' | grep -iE '^[23][0-9a-f]*(:[0-9a-f]+){7}/' | head -1 | cut -d: -f1-4)
  [ -n "$PFX" ] || { echo "Could not find this machine's global IPv6 /64 prefix on $IF."; exit 1; }
  g=$(printf '%s' "$PFX" | awk -F: '{print NF}')
  while [ "$g" -lt 4 ]; do PFX="$PFX:0"; g=$((g+1)); done
  while :; do
    SUF=$(od -An -N8 -tx2 /dev/urandom | tr -d ' \n' | sed -e 's/\(....\)\(....\)\(....\)\(....\)/\1:\2:\3:\4/' -e 's/\(^\|:\)0\+\([0-9a-f]\)/\1\2/g')
    ADDR="$PFX:$SUF"
    ip -6 addr show | grep -qi "$ADDR" || break
  done
  printf 'IF=%s\nADDR=%s\n' "$IF" "$ADDR" > "$cfg"
fi

# systemd: bring the address up at every boot, before the bot starts
cat > /etc/systemd/system/botip6@.service <<'EOT'
[Unit]
Description=Own IPv6 address for bot %i
After=network.target
[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=/etc/botip6/%i.conf
ExecStart=/usr/bin/env ip -6 addr replace ${ADDR}/128 dev ${IF} nodad
ExecStop=/usr/bin/env ip -6 addr del ${ADDR}/128 dev ${IF}
[Install]
WantedBy=multi-user.target
EOT
mkdir -p /etc/systemd/system/$svc.service.d
rm -f /etc/systemd/system/$svc.service.d/ns.conf        # leave any WARP tunnel behind
printf '[Unit]\nWants=botip6@%s.service\nAfter=botip6@%s.service\n' "$n" "$n" > /etc/systemd/system/$svc.service.d/ip6.conf
systemctl daemon-reload
systemctl enable "botip6@$n" >/dev/null 2>&1 || true
systemctl restart "botip6@$n"

# bind the bot to its address (vhost6)
wd=$(systemctl show "$svc" -p WorkingDirectory --value)
u=$(systemctl show "$svc" -p User --value)
conf=$(grep -oE '[A-Za-z0-9_.-]+\.conf' /etc/systemd/system/$svc.service | grep -v warp | head -1)
run() { if [ -n "$u" ]; then runuser -u "$u" -- "$@"; else "$@"; fi; }
if [ -f "$wd/$conf" ]; then
  run sed -i -E '/^[[:space:]]*set[[:space:]]+(vhost6|my-ip6)[[:space:]]/d' "$wd/$conf"
  if grep -q '^set atempo(config_error)' "$wd/$conf"; then
    run sed -i "/^set atempo(config_error)/i set vhost6 \"$ADDR\"" "$wd/$conf"
  else
    run sh -c 'printf "set vhost6 \"%s\"\n" "$1" >> "$2"' x "$ADDR" "$wd/$conf"
  fi
fi

echo "Bot IPv6 for $bot: $ADDR"
out=$(curl -6 -s -m 8 --interface "$ADDR" https://ipv6.icanhazip.com 2>/dev/null || true)
if [ "$(printf '%s' "$out" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$ADDR" | tr 'A-Z' 'a-z')" ]; then
  echo "Internet check from $ADDR: OK"
else
  echo "WARNING: internet check from $ADDR gave '${out:-nothing}'. Your router/ISP may not allow extra addresses in the /64."
fi
if [ "$restart" = "1" ]; then
  systemctl restart "$svc"; sleep 5
  systemctl status "$svc" --no-pager | head -4
fi
BOTIP6EOF
    sudo chmod +x /usr/local/bin/botip6
    ohai "Helper ${tty_green}botip6${tty_reset} installed."
    echo
    return 0
}

# gives this bot its own address and binds the config + service to it (called before the first run)
native6_prepare_bot() {
    local n
    echo
    ohai "Giving ${tty_green}${BOTNICK}${tty_reset} its own IPv6 address..."
    sudo botip6 --no-restart "${BOTNICK}" || {
        ring_bell
        echo "${tty_red}Error:${tty_reset} could not set up the bot's IPv6 address."
        return 1
    }
    n="$(printf '%s' "${BOTNICK}" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9')"
    [ -n "${n}" ] || n="bot"
    NATIVE6_ADDR="$(sudo awk -F= '/^ADDR=/{print $2}' "/etc/botip6/${n}.conf" 2>/dev/null)"
    return 0
}

# Clean ident (no "~" before the username): one ident server answers for every bot on this machine
setup_identd() {
    check_sudo
    echo
    ohai "Setting up ${tty_green}oidentd${tty_reset} (clean ident)..."
    sudo apt-get install -y oidentd || { warn "Could not install oidentd."; return 1; }
    # minimal config: the distro default has been seen to fail with a syntax error, which stops the daemon
    if [ -f /etc/oidentd.conf ] && ! grep -q 'PinoyChat installer' /etc/oidentd.conf 2>/dev/null; then
        sudo cp /etc/oidentd.conf /etc/oidentd.conf.pinoychat.bak
    fi
    printf '# written by the PinoyChat installer: oidentd answers with the Linux username that owns the connection\n' | sudo tee /etc/oidentd.conf >/dev/null
    sudo systemctl enable oidentd >/dev/null 2>&1
    sudo systemctl restart oidentd
    sleep 2
    if ss -tln 2>/dev/null | grep -q ':113 '; then
        ohai "oidentd is ${tty_green}running${tty_reset} on port 113."
    else
        warn "oidentd did not start - check: sudo journalctl -u oidentd -n 20"
        return 1
    fi
    echo
    echo "    ${tty_yellow}One more step on YOUR router:${tty_reset} allow inbound ${tty_bold}TCP port 113${tty_reset} to this machine"
    echo "    (an IPv6 firewall rule, and an IPv4 port-forward if the bot uses IPv4). The IRC server connects"
    echo "    back to the bot on that port; while it is blocked the ident keeps its '~'."
    echo "    Test from a machine outside your network:  nc -vz <bot address> 113"
    echo
    return 0
}

ask_for_ident() {
    local input
    echo
    ohai "Clean ident (no ${tty_bold}~${tty_reset} before the username)? Installs the ident server ${tty_green}oidentd${tty_reset}. (${tty_green}Y${tty_reset})es or (${tty_green}N${tty_reset})o"
    echo
    getc input
    case "${input}" in
        y) setup_identd || warn "Ident setup failed - the ident will keep its ~." ;;
        n) echo
           ohai "Skipping ident setup."
           echo ;;
        *) ring_bell
           warn "Invalid input, please select (Y)es or (N)o"
           ask_for_ident ;;
    esac
}

ask_for_warp() {
    USE_WARP="0"
    USE_NATIVE6="0"
    PREFER_IPV6="1"
    [[ -n "${BT_ON_LINUX-}" ]] || return 0
    command -v systemctl >/dev/null 2>&1 || return 0
    command -v apt-get >/dev/null 2>&1 || return 0

    local input
    echo
    echo "    ${tty_green}============================================================${tty_reset}"
    ohai "How should this bot get its ${tty_green}IPv6${tty_reset} address?"
    echo "    ${tty_green}============================================================${tty_reset}"
    echo
    echo "      ${tty_green}1${tty_reset}  Its own address from this machine's IPv6 block  ${tty_bold}(recommended)${tty_reset}"
    echo "         A different address for every bot, stable, nothing shared with strangers."
    echo "         Your network's IPv6 prefix is visible in /whois."
    echo "      ${tty_green}2${tty_reset}  Cloudflare WARP tunnel, IPv6 (hides your own IP)"
    echo "         ${tty_yellow}Caution:${tty_reset} WARP addresses are shared by many people. Undernet bans them for"
    echo "         'excessive connections' (1 day), and then the bot cannot connect."
    echo "      ${tty_green}3${tty_reset}  Nothing special: use this machine's address as it is"
    echo "      ${tty_green}4${tty_reset}  Cloudflare WARP tunnel, IPv4 (hides your own IP)"
    echo "         The bot connects over IPv4 through the tunnel (use irc.undernet.org, not irc6)."
    echo "         The IPv4 address is also shared with many people, so the same caution applies."
    echo
    echo "    Tip for 1 and 2: pick an IPv6 IRC server (e.g. ${tty_green}irc6.undernet.org${tty_reset}) so the IPv6 is what shows."
    echo
    ohai "Choose ${tty_green}1${tty_reset}, ${tty_green}2${tty_reset}, ${tty_green}3${tty_reset} or ${tty_green}4${tty_reset}:"
    echo
    getc input
    case "${input}" in
        1)
            if install_native6_toolkit; then
                USE_NATIVE6="1"
                ohai "Own IPv6 address ${tty_green}enabled${tty_reset} for this bot - vhost questions will be skipped."
                echo
                ask_for_ident
            else
                ring_bell
                warn "Could not set that up - continuing WITHOUT a dedicated IPv6 address."
                echo
            fi
            ;;
        2)
            if install_warp_toolkit; then
                USE_WARP="1"
                ohai "WARP ${tty_green}enabled${tty_reset} for this bot - vhost questions will be skipped."
                echo
                echo "    ${tty_yellow}Note:${tty_reset} a clean ident (no ~) is not possible through WARP: the IRC server cannot connect back."
                echo
            else
                ring_bell
                warn "WARP setup failed - continuing WITHOUT WARP (the bot will use this machine's own IP)."
                echo
            fi
            ;;
        3)
            echo
            ohai "Using this machine's address as it is."
            echo
            ask_for_ident
            ;;
        4)
            if install_warp_toolkit; then
                USE_WARP="1"
                PREFER_IPV6="0"
                ohai "WARP ${tty_green}enabled${tty_reset} (IPv4 mode) for this bot - vhost questions will be skipped."
                echo
                echo "    ${tty_yellow}Note:${tty_reset} a clean ident (no ~) is not possible through WARP: the IRC server cannot connect back."
                echo
            else
                ring_bell
                warn "WARP setup failed - continuing WITHOUT WARP (the bot will use this machine's own IP)."
                echo
            fi
            ;;
        *)
            ring_bell
            warn "Invalid input, please press 1, 2, 3 or 4"
            ask_for_warp
            ;;
    esac
}

# creates (or re-uses) this bot's tunnel, prints its IPv6. Returns 1 on failure.
warp_prepare_bot() {
    WARP_NS="$(warpns-name "${BOTNICK}")"
    echo
    ohai "Preparing private WARP tunnel ${tty_green}${WARP_NS}${tty_reset} for ${tty_green}${BOTNICK}${tty_reset}..."
    sudo sh -c "[ -f /etc/warpns/${WARP_NS}.conf ] || warpns-new ${WARP_NS}" || {
        ring_bell
        echo "${tty_red}Error:${tty_reset} could not create the WARP account (Cloudflare may be rate-limiting - wait 10-15 minutes)."
        return 1
    }
    WARP_IPV6="$(sudo warpns-wait "${WARP_NS}")" || {
        ring_bell
        echo "${tty_red}Error:${tty_reset} the WARP tunnel did not come up."
        return 1
    }
    ohai "Tunnel IPv6 for ${BOTNICK}: ${tty_green}${WARP_IPV6}${tty_reset}"
    # inside the tunnel the machine's own addresses do not exist: make sure no vhost is set
    sed -i -E 's/^(set +(vhost4|vhost6|my-ip|my-ip6) )/#\1/' "${EGGDROP_INSTALL_DIR}/${BOTNICK}.conf"
    return 0
}

# first (-m) run of the bot INSIDE its tunnel
warp_run_first_mode() {
    sudo ip netns exec "${WARP_NS}" sudo -u "$(whoami)" -H bash -c \
        "cd '${EGGDROP_INSTALL_DIR}' && ./eggdrop -m '${BOTNICK}.conf'" > /dev/null 2>&1
}

# the address the bot is seen with from outside the tunnel (IPv6, or IPv4 in IPv4 mode)
warp_egress_ip() {
    if [ "${PREFER_IPV6}" == "0" ]; then
        sudo ip netns exec "${WARP_NS}" curl -4 -s -m 15 https://ipv4.icanhazip.com 2>/dev/null
    else
        sudo ip netns exec "${WARP_NS}" curl -6 -s -m 15 https://ipv6.icanhazip.com 2>/dev/null
    fi
}

# attach the systemd service to the tunnel and start it there. Returns 1 on failure.
warp_attach_service() {
    local svc="$1"
    ohai "Attaching ${tty_green}${svc}${tty_reset} to its WARP tunnel..."
    sudo warpns-bind "${svc}" "${WARP_NS}" || return 1
    sleep 5
    WARP_IPV6="$(warp_egress_ip)"
    return 0
}

# ---------------------------------------------------------------------------
# Eggdrop download & build
# ---------------------------------------------------------------------------

download_eggdrop() {
    local tmpdir
    tmpdir=$(mktemp -d)
    echo
    ohai "Downloading Eggdrop ${EGGDROP_VER}..."
    echo
    wget --show-progress -q -O "${tmpdir}/eggdrop.tar.gz" "${EGGDROP_URL}" || {
        echo "${tty_red}Error:${tty_reset} Failed to download Eggdrop. Check your internet connection."
        abort
    }

    ohai "Extracting source..."
    tar -xzf "${tmpdir}/eggdrop.tar.gz" -C "${tmpdir}"

    ohai "Compiling Eggdrop ${EGGDROP_VER} (this may take a minute)..."
    echo

    find_tcl

    cd "${tmpdir}/eggdrop-${EGGDROP_VER}"

    # A&A: eggdrop answers /msg commands (hello, ident, pass...) with NOTICE; make them private messages
    if [ "${INSTALL_PACKAGE}" == "aa" ]; then
        ohai "A&A: first-run hello replies will be ${tty_green}private messages${tty_reset} (not notices)"
        sed 's/"NOTICE %s :/"PRIVMSG %s :/g' src/mod/irc.mod/msgcmds.c > src/mod/irc.mod/msgcmds.c.new \
            && mv src/mod/irc.mod/msgcmds.c.new src/mod/irc.mod/msgcmds.c
    fi

    ohai "Running configure with: ${tty_green}${TCL_CONFIG_ARG}${tty_reset}"
    echo
    ./configure --prefix="${EGGDROP_INSTALL_DIR}" ${TCL_CONFIG_ARG} || {
        echo
        ring_bell
        echo "${tty_red}Error:${tty_reset} eggdrop configure failed. Please check output above."
        abort
    }

    make config || {
        echo
        ring_bell
        echo "${tty_red}Error:${tty_reset} eggdrop 'make config' failed. Please check output above."
        abort
    }

    make || {
        echo
        ring_bell
        echo "${tty_red}Error:${tty_reset} eggdrop compilation failed. Please check output above."
        abort
    }

    make install DEST="${EGGDROP_INSTALL_DIR}" || {
        echo
        ring_bell
        echo "${tty_red}Error:${tty_reset} eggdrop installation failed. Please check output above."
        abort
    }

    # A&A: eggdrop's first-run (hello) replies as colourful private messages (BlackTools style)
    if [ "${INSTALL_PACKAGE}" == "aa" ]; then
        _c="$(printf '\003')"
        for lf in "${EGGDROP_INSTALL_DIR}"/language/core.*.lang; do
            [ -f "${lf}" ] || continue
            LC_ALL=C sed \
                -e 's/^\(0x6[0-9a-fA-F][0-9a-fA-F],\)NOTICE %s :/\1PRIVMSG %s :/' \
                -e "s/^\(0x60a,PRIVMSG %s :\)Hi %s!  I'm %s, an eggdrop bot\./\1${_c}05Hi ${_c}09%s${_c}05!  I'm ${_c}09%s${_c}05, an eggdrop bot./" \
                -e "s/^\(0x60b,PRIVMSG %s :\)I'll recognize you by hostmask '%s' from now on\./\1${_c}05I'll recognize you by hostmask '${_c}09%s${_c}05' from now on./" \
                -e "s/^\(0x60e,\)YOU ARE THE OWNER ON THIS BOT NOW/\1${_c}09*** HOORAH! *** ${_c}04YOU ARE THE OWNER ON THIS BOT NOW/" \
                -e "s/^\(0x664,PRIVMSG %s :\)As master you really need to set a password: with \/MSG %s pass <your-chosen-password>\./\1${_c}05As master you really need to set a password: with ${_c}04\/MSG %s pass <your-chosen-password>${_c}05./" \
                -e "s/^\(0x665,PRIVMSG %s :\)All major commands are used from DCC chat\. From now on, you don't need to use the -m option when starting the bot\.  Enjoy !!!/\1${_c}05All major commands are used from DCC chat. From now on, you don't need to use the -m option when starting the bot.  ${_c}09Enjoy !!!/" \
                "${lf}" > "${lf}.new" && mv "${lf}.new" "${lf}"
        done
    fi

    cd "${HOME}"
    rm -rf "${tmpdir}"
    echo
    ohai "Eggdrop ${EGGDROP_VER} installed to: ${tty_green}${EGGDROP_INSTALL_DIR}${tty_reset}"
}

# ---------------------------------------------------------------------------
# BlackTools download
# ---------------------------------------------------------------------------

install_blacktools() {
    local tmpdir
    tmpdir=$(mktemp -d)
    local scripts_dir="${EGGDROP_INSTALL_DIR}/scripts"
    mkdir -p "${scripts_dir}"

    echo
    ohai "Downloading PinoyChat BlackTools (pre-patched, no [BT] branding)..."
    echo
    wget --show-progress -q -O "${tmpdir}/bt.zip" "${BT_ZIP_URL}" || {
        echo "${tty_red}Error:${tty_reset} Failed to download BlackTools. Check your internet connection."
        abort
    }

    ohai "Extracting BlackTools..."
    unzip -q "${tmpdir}/bt.zip" -d "${tmpdir}"

    [ -f "${tmpdir}/BlackTools.tcl" ] && cp "${tmpdir}/BlackTools.tcl" "${scripts_dir}/BlackTools.tcl"
    [ -d "${tmpdir}/BlackTools" ]     && cp -r "${tmpdir}/BlackTools/." "${scripts_dir}/BlackTools/"
    [ -d "${tmpdir}/${BT_DIR_NAME}" ] && cp -r "${tmpdir}/${BT_DIR_NAME}/." "${scripts_dir}/"

    rm -rf "${tmpdir}"
    echo
    ohai "BlackTools installed to: ${tty_green}${scripts_dir}${tty_reset}"
}

# ---------------------------------------------------------------------------
# Package choice: BlackTools vs A&A
# ---------------------------------------------------------------------------

ask_for_package() {
    local input
    echo
    echo "    ${tty_green}============================================================${tty_reset}"
    ohai "Which TCL script package do you want to install?"
    echo "    ${tty_green}============================================================${tty_reset}"
    echo
    echo "        ${tty_green}1${tty_reset}: ${tty_bold}BlackTools${tty_reset}  — PinoyChat patched version"
    echo "           Channel management, auth via X/ChanServ, stats, flood, etc."
    echo
    echo "        ${tty_green}2${tty_reset}: ${tty_bold}A&A (light)${tty_reset} v0.04.00 — by UniversaliA"
    echo "           Undernet/Quakenet-style manager with X/Q service support."
    echo
    getc input
    if [ "${input}" == '1' ]; then
        INSTALL_PACKAGE="blacktools"
        ohai "Package: ${tty_green}BlackTools${tty_reset}"
    elif [ "${input}" == '2' ]; then
        INSTALL_PACKAGE="aa"
        ohai "Package: ${tty_green}A&A (light)${tty_reset}"
    else
        ring_bell
        warn "Invalid input, please select ${tty_green}1${tty_reset} or ${tty_green}2${tty_reset}."
        ask_for_package
        return
    fi
    echo
}

# ---------------------------------------------------------------------------
# A&A download & install
# ---------------------------------------------------------------------------

install_aa() {
    local tmpdir
    tmpdir=$(mktemp -d)
    local scripts_dir="${EGGDROP_INSTALL_DIR}/scripts"
    mkdir -p "${scripts_dir}"

    echo
    ohai "Downloading A&A (light) v0.04.00..."
    echo
    wget --show-progress -q -O "${tmpdir}/aa.zip" "${AA_ZIP_URL}" || {
        echo "${tty_red}Error:${tty_reset} Failed to download A&A. Check your internet connection."
        abort
    }

    ohai "Extracting A&A..."
    unzip -q "${tmpdir}/aa.zip" -d "${tmpdir}/aa"

    [ -d "${tmpdir}/aa/ascript" ]            && cp -r "${tmpdir}/aa/ascript"         "${EGGDROP_INSTALL_DIR}/ascript"
    [ -d "${tmpdir}/aa/ascript.README" ]     && cp -r "${tmpdir}/aa/ascript.README"  "${EGGDROP_INSTALL_DIR}/ascript.README"
    [ -f "${tmpdir}/aa/settings.conf" ]      && cp "${tmpdir}/aa/settings.conf"      "${EGGDROP_INSTALL_DIR}/settings.conf"
    [ -f "${tmpdir}/aa/botnick.conf" ]       && cp "${tmpdir}/aa/botnick.conf"       "${EGGDROP_INSTALL_DIR}/botnick.conf.template"
    [ -f "${tmpdir}/aa/eggdrop.conf" ]       && cp "${tmpdir}/aa/eggdrop.conf"       "${EGGDROP_INSTALL_DIR}/eggdrop.conf"

    rm -rf "${tmpdir}"
    echo
    ohai "A&A installed to: ${tty_green}${EGGDROP_INSTALL_DIR}${tty_reset}"
}

# ---------------------------------------------------------------------------
# A&A interactive config
# ---------------------------------------------------------------------------

AA_CHANSERV_USER=""
AA_CHANSERV_PASS=""
AA_HOMECHAN=""
AA_SUPPCHAN=""
AA_HOMEPAGE=""
AA_NETWORK=""
AA_NETTYPE="5"

collect_aa_settings() {
    echo
    echo "    ${tty_green}============================================================${tty_reset}"
    ohai "A&A ${tty_green}Bot & Script${tty_reset} settings..."
    echo "    ${tty_green}============================================================${tty_reset}"
    echo

    ohai "[${tty_blue}Setting${tty_reset}] ${tty_green}nick${tty_reset}:"
    echo "    The primary ${tty_green}nickname${tty_reset} your bot will use on IRC."
    echo
    NOEMPTY=1; NUMERIC=0
    ask_for_setting_value "nick" "PinoyBot"
    BOTNICK="${new_value}"

    echo
    ohai "[${tty_blue}Setting${tty_reset}] ${tty_green}altnick${tty_reset}:"
    echo "    The alternate nickname used when ${tty_green}${BOTNICK}${tty_reset} is taken."
    echo
    NOEMPTY=1; NUMERIC=0
    ask_for_setting_value "altnick" "${BOTNICK}-"
    ALTNICK="${new_value}"

    echo
    ohai "[${tty_blue}Setting${tty_reset}] ${tty_green}username${tty_reset} (ident):"
    echo "    The ${tty_green}ident${tty_reset} shown in your bot's IRC hostmask."
    echo
    NOEMPTY=1; NUMERIC=0
    ask_for_setting_value "username" "$(whoami)"
    BOTUSERNAME="${new_value}"

    echo
    ohai "[${tty_blue}Setting${tty_reset}] ${tty_green}realname${tty_reset}:"
    echo "    The ${tty_green}realname${tty_reset} field shown in /WHOIS."
    echo
    echo "    ${tty_bold}IRC Color Codes:${tty_reset}"
    echo "    ┌─────┬──────────────┬─────┬──────────────┐"
    echo "    │ ${tty_green}00${tty_reset}  │ White        │ ${tty_green}08${tty_reset}  │ Yellow       │"
    echo "    │ ${tty_green}01${tty_reset}  │ Black        │ ${tty_green}09${tty_reset}  │ Light Green  │"
    echo "    │ ${tty_green}02${tty_reset}  │ Navy Blue    │ ${tty_green}10${tty_reset}  │ Teal         │"
    echo "    │ ${tty_green}03${tty_reset}  │ Green        │ ${tty_green}11${tty_reset}  │ Cyan         │"
    echo "    │ ${tty_green}04${tty_reset}  │ Red          │ ${tty_green}12${tty_reset}  │ Blue         │"
    echo "    │ ${tty_green}05${tty_reset}  │ Brown        │ ${tty_green}13${tty_reset}  │ Magenta/Pink │"
    echo "    │ ${tty_green}06${tty_reset}  │ Purple       │ ${tty_green}14${tty_reset}  │ Grey         │"
    echo "    │ ${tty_green}07${tty_reset}  │ Orange       │ ${tty_green}15${tty_reset}  │ Light Grey   │"
    echo "    └─────┴──────────────┴─────┴──────────────┘"
    echo
    echo "    ${tty_bold}Formatting:${tty_reset}"
    echo "    ${tty_green}\\002${tty_reset} = Bold    ${tty_green}\\035${tty_reset} = Italic    ${tty_green}\\037${tty_reset} = Underline"
    echo
    echo "    ${tty_bold}Examples:${tty_reset}"
    echo "    ${tty_green}4 the legacy of me${tty_reset}         → red realname"
    echo "    ${tty_green}13 Clarity. Peace. Serenity${tty_reset} → magenta realname"
    echo "    ${tty_green}7 \\002Bold Orange Text${tty_reset}       → bold orange realname"
    echo
    NOEMPTY=1; NUMERIC=0
    ask_for_setting_value "realname" "Powered by PinoyChat - Arns®"
    REALNAME="$(colorize_realname "${new_value}")"

    echo
    ohai "[${tty_blue}Setting${tty_reset}] ${tty_green}owner${tty_reset}:"
    echo "    Your ${tty_green}owner${tty_reset} handle (permanent global manager in A&A)."
    echo
    NOEMPTY=1; NUMERIC=0
    ask_for_setting_value "owner" "$(whoami)"
    BOTOWNER="${new_value}"

    ask_for_network
    case "${NETWORK}" in
        PinoyChat) AA_NETWORK="PinoyChat"; AA_NETTYPE="5" ;;
        Undernet)  AA_NETWORK="UNDERNET";  AA_NETTYPE="2" ;;
        DALnet)    AA_NETWORK="DALnet";    AA_NETTYPE="3" ;;
        Libera)    AA_NETWORK="Libera";    AA_NETTYPE="5" ;;
        EFnet)     AA_NETWORK="EFnet";     AA_NETTYPE="0" ;;
        *)         AA_NETWORK="${NETWORK}"; AA_NETTYPE="5" ;;
    esac

    echo
    ohai "[${tty_blue}Setting${tty_reset}] ${tty_green}server${tty_reset}:"
    echo "    The IRC ${tty_green}server${tty_reset} the bot should connect to."
    echo
    NOEMPTY=1; NUMERIC=0
    ask_for_setting_value "server" "${BOTSERVER}"
    BOTSERVER="${new_value}"

    echo
    ohai "[${tty_blue}Setting${tty_reset}] ${tty_green}port${tty_reset}:"
    echo "    The IRC ${tty_green}server port${tty_reset} to connect to (default: 6667)."
    echo
    NOEMPTY=1; NUMERIC=1
    ask_for_setting_value "port" "${BOTPORT}"
    BOTPORT="${new_value}"
    NUMERIC=0

    echo
    ohai "[${tty_blue}Setting${tty_reset}] ${tty_green}home channel${tty_reset}:"
    echo "    The ${tty_green}console/home channel${tty_reset} the bot joins first (usually a private chan)."
    echo
    NOEMPTY=1; NUMERIC=0
    ask_for_setting_value "home channel" "#pinoychat"
    AA_HOMECHAN="${new_value}"
    CHANNEL="${AA_HOMECHAN}"

    echo
    ohai "[${tty_blue}Setting${tty_reset}] ${tty_green}support channel${tty_reset}:"
    echo "    Channel where users can ask for help / apply for bot access."
    echo
    NOEMPTY=1; NUMERIC=0
    ask_for_setting_value "support channel" "${AA_HOMECHAN}"
    AA_SUPPCHAN="${new_value}"

    echo
    ohai "[${tty_blue}Setting${tty_reset}] ${tty_green}homepage${tty_reset}:"
    echo "    Support web-page shown to users (e.g. ${tty_green}https://pinoychat.fun${tty_reset})."
    echo
    NOEMPTY=0; NUMERIC=0
    ask_for_setting_value "homepage" "https://pinoychat.fun"
    AA_HOMEPAGE="${new_value}"

    echo
    ohai "[${tty_blue}Setting${tty_reset}] ${tty_green}service auth username${tty_reset} (X/Q/ChanServ):"
    echo "    Leave empty if your network has no services or you don't want auto-login."
    echo
    NOEMPTY=0; NUMERIC=0
    ask_for_setting_value "service auth username" ""
    AA_CHANSERV_USER="${new_value}"

    if [ -n "${AA_CHANSERV_USER}" ]; then
        echo
        ohai "[${tty_blue}Setting${tty_reset}] ${tty_green}service auth password${tty_reset}:"
        echo "    Password for ${tty_green}${AA_CHANSERV_USER}${tty_reset}."
        echo
        NOEMPTY=1; NUMERIC=0
        ask_for_setting_value "service auth password" ""
        AA_CHANSERV_PASS="${new_value}"
    fi

    echo
    ohai "[${tty_blue}Setting${tty_reset}] ${tty_green}listen port${tty_reset}:"
    echo "    Port > 1024 for telnet/botnet connections."
    echo
    getPort
    NOEMPTY=1; NUMERIC=1
    ask_for_setting_value "listen port" "${PORT}"
    LISTEN_PORT="${new_value}"
    NUMERIC=0

    if [ "${USE_WARP}" == "1" ] || [ "${USE_NATIVE6}" == "1" ]; then
        VHOST4=""; VHOST6=""
        echo
        ohai "Skipping vhost4/vhost6 (the installer sets this bot's IPv6 address)."
        return
    fi

    echo
    ohai "[${tty_blue}Setting${tty_reset}] ${tty_green}vhost4${tty_reset} (optional):"
    echo "    The ${tty_green}IPv4 bind address${tty_reset}. Leave empty to skip."
    echo
    getIPv4
    NOEMPTY=0; NUMERIC=0
    ask_for_setting_value "vhost4" "${IP4ADDRESS}"
    VHOST4="${new_value}"

    echo
    ohai "[${tty_blue}Setting${tty_reset}] ${tty_green}vhost6${tty_reset} (optional):"
    echo "    The ${tty_green}IPv6 bind address${tty_reset}. Leave empty to skip."
    echo
    getIPv6
    NOEMPTY=0; NUMERIC=0
    ask_for_setting_value "vhost6" "${IP6ADDRESS}"
    VHOST6="${new_value}"
}

# ---------------------------------------------------------------------------
# Patch A&A config files with user-supplied settings
# ---------------------------------------------------------------------------

patch_aa() {
    local botnick_conf="${EGGDROP_INSTALL_DIR}/${BOTNICK}.conf"
    local settings_f="${EGGDROP_INSTALL_DIR}/settings.conf"

    write_dalnet_script
    ohai "Writing ${tty_green}${BOTNICK}.conf${tty_reset} (A&A botnick config)..."
    echo

    local vhost_lines=""
    [ -n "${VHOST4}" ] && vhost_lines="${vhost_lines}set vhost4 \"${VHOST4}\"\n"
    [ -n "${VHOST6}" ] && vhost_lines="${vhost_lines}set vhost6 \"${VHOST6}\"\n"

    cat > "${botnick_conf}" <<EOF
#!/${EGGDROP_INSTALL_DIR}/eggdrop
# ===========================================================================
#  ${BOTNICK}.conf  -- auto-generated by PinoyChat Eggdrop+A&A Installer
#  Eggdrop ${EGGDROP_VER} | A&A (light) v0.04.00
#  Network: ${NETWORK} | ${BOTSERVER}:${BOTPORT}
# ===========================================================================

set botnet-nick "${BOTNICK}"
set username    "${BOTUSERNAME}"
set nick        "${BOTNICK}"
set altnick     "${ALTNICK}"
set realname    "${REALNAME}"

set chanserv(user) "${AA_CHANSERV_USER}"
set chanserv(pass) "${AA_CHANSERV_PASS}"

listen ${LISTEN_PORT} all

$(printf "%b" "${vhost_lines}")
set network "${AA_NETWORK}"
set net-type ${AA_NETTYPE}
set nick-len 12

set atempo(config_error)   [catch {source eggdrop.conf}  atempo(config_error_info)]
# the package's eggdrop.conf has its own built-in Undernet/other server list that would
# overwrite the server chosen above, so the chosen server is set AFTER it and always wins
set servers {
    ${BOTSERVER}:${BOTPORT}
}
set prefer-ipv6 ${PREFER_IPV6}
set atempo(settings_error) [catch {source settings.conf} atempo(settings_error_info)]
                            catch {source ascript/loader.tcl}
${DAL_SRC_LINE}
EOF

    ohai "[${tty_blue}Written${tty_reset}] ${tty_green}${botnick_conf}${tty_reset}"
    echo

    ohai "Patching ${tty_green}settings.conf${tty_reset}..."
    echo

    sed -i "s|set owner\t\t\t\"Edit_Me_Pls\"|set owner\t\t\t\"${BOTOWNER}\"|" "${settings_f}"
    sed -i "s|set admin\t\t\t\"Edit_Me_Pls\"|set admin\t\t\t\"${BOTOWNER}\"|" "${settings_f}"
    sed -i "s|set settings(suppchan)\t\t\"#Edit_Me_Pls\"|set settings(suppchan)\t\t\"${AA_SUPPCHAN}\"|" "${settings_f}"
    sed -i "s|set settings(homechan)\t\t\"#Edit_Me_Pls\"|set settings(homechan)\t\t\"${AA_HOMECHAN}\"|" "${settings_f}"
    sed -i "s|set settings(homepage)\t\t\"http://Edit_Me_Pls\"|set settings(homepage)\t\t\"${AA_HOMEPAGE}\"|" "${settings_f}"

    mkdir -p "${EGGDROP_INSTALL_DIR}/db"
    sed -i 's|^set store-path.*|set store-path\t"db/"\t\t\t\t;# folder where user, chan, note \& info files will be stored|' "${settings_f}"

    ohai "[${tty_blue}Patched${tty_reset}] ${tty_green}settings.conf${tty_reset} (all data files → db/)"
    echo
    # A&A: the package ships "prefer-ipv6 0" (IPv4 only) - set it to the chosen mode (1 = IPv6 first, 0 = IPv4)
    if [ -f "${EGGDROP_INSTALL_DIR}/eggdrop.conf" ]; then
        sed "s/^set prefer-ipv6 [01]/set prefer-ipv6 ${PREFER_IPV6}/" "${EGGDROP_INSTALL_DIR}/eggdrop.conf" > "${EGGDROP_INSTALL_DIR}/eggdrop.conf.new" \
            && mv "${EGGDROP_INSTALL_DIR}/eggdrop.conf.new" "${EGGDROP_INSTALL_DIR}/eggdrop.conf"
        ohai "[${tty_blue}Patched${tty_reset}] eggdrop.conf: prefer-ipv6 ${tty_green}${PREFER_IPV6}${tty_reset}"
    fi
    ohai "[${tty_blue}Note${tty_reset}] eggdrop.conf used as-is (network already set in ${BOTNICK}.conf)."
    echo
    ohai "A&A config patched and ready!"
    echo
}

# ---------------------------------------------------------------------------
# Eggdrop interactive config (BlackTools)
# ---------------------------------------------------------------------------

BOTNICK=""
ALTNICK=""
BOTUSERNAME=""
BOTOWNER=""
CHANNEL=""
LISTEN_PORT=""
REALNAME=""
VHOST4=""
VHOST6=""

BT_CHANSERV="X"
BT_CHANSERV_HOST=""
BT_AUTH_USER=""
BT_AUTH_PASS=""
BT_XHOST=""

# ---------------------------------------------------------------------------
# BlackTools interactive config
# ---------------------------------------------------------------------------

collect_bt_settings() {
    echo
    echo "    ${tty_green}============================================================${tty_reset}"
    ohai "BlackTools ${tty_green}ChanServ / Service Login${tty_reset} settings..."
    echo "    ${tty_green}============================================================${tty_reset}"
    echo
    echo "    These settings configure how your bot authenticates with"
    echo "    IRC network services (e.g. X on PinoyChat)."
    echo "    Leave auth user/pass empty if your network has no services."
    echo

    ohai "[${tty_blue}Setting${tty_reset}] ${tty_green}ChanServ nick${tty_reset}:"
    echo "    The nickname of the channel service bot on your network."
    echo "    e.g. ${tty_green}X${tty_reset} for PinoyChat/Undernet, ${tty_green}ChanServ${tty_reset} for DALnet/Libera"
    echo
    NOEMPTY=1; NUMERIC=0
    ask_for_setting_value "ChanServ nick" "X"
    BT_CHANSERV="${new_value}"

    echo
    ohai "[${tty_blue}Setting${tty_reset}] ${tty_green}ChanServ host${tty_reset}:"
    echo "    Full nick@host of the service bot."
    echo "    e.g. ${tty_green}x@channels.pinoychat.fun${tty_reset}"
    echo
    NOEMPTY=1; NUMERIC=0
    ask_for_setting_value "ChanServ host" "x@services.pinoychat.fun"
    BT_CHANSERV_HOST="${new_value}"

    echo
    ohai "[${tty_blue}Setting${tty_reset}] ${tty_green}service auth username${tty_reset}:"
    echo "    The network username your bot uses to auth with services."
    echo "    Leave empty to disable auto-login."
    echo
    NOEMPTY=0; NUMERIC=0
    ask_for_setting_value "auth username" ""
    BT_AUTH_USER="${new_value}"

    if [ -n "${BT_AUTH_USER}" ]; then
        echo
        ohai "[${tty_blue}Setting${tty_reset}] ${tty_green}service auth password${tty_reset}:"
        echo "    Password for ${tty_green}${BT_AUTH_USER}${tty_reset} to authenticate with services."
        echo
        NOEMPTY=1; NUMERIC=0
        ask_for_setting_value "auth password" ""
        BT_AUTH_PASS="${new_value}"

        echo
        ohai "[${tty_blue}Setting${tty_reset}] ${tty_green}hidden host suffix${tty_reset} (xhost):"
        echo "    Host suffix given to authed users with +x."
        echo "    e.g. ${tty_green}users.pinoychat.fun${tty_reset} → hostmask becomes ${tty_green}*!*@nick.users.pinoychat.fun${tty_reset}"
        echo "    Leave empty if your network does not use hidden hosts."
        echo
        NOEMPTY=0; NUMERIC=0
        ask_for_setting_value "xhost suffix" "users.pinoychat.fun"
        BT_XHOST="${new_value}"
    fi
}

# ---------------------------------------------------------------------------
# Patch BlackTools.tcl
# ---------------------------------------------------------------------------

patch_blacktools() {
    local bt="${EGGDROP_INSTALL_DIR}/scripts/BlackTools.tcl"

    ohai "Patching ${tty_green}BlackTools.tcl${tty_reset} for ${tty_green}${NETWORK}${tty_reset}..."
    echo

    sed -i "s|set black(homechan) .*|set black(homechan) \"${CHANNEL}\"|" "${bt}"
    sed -i "s|set black(chanserv) .*|set black(chanserv) \"${BT_CHANSERV}\"|" "${bt}"
    sed -i "s|set black(hostchanserv) .*|set black(hostchanserv) \"${BT_CHANSERV_HOST}\"|" "${bt}"

    local bt_domain
    bt_domain=$(echo "${BT_CHANSERV_HOST}" | sed 's/.*@//')
    sed -i "s|set black(chanserv:ignore_host) .*|set black(chanserv:ignore_host) \"*!*@${bt_domain}\"|" "${bt}"

    if [ -n "${BT_AUTH_USER}" ]; then
        sed -i "s|set black(username) .*|set black(username) \"${BT_AUTH_USER}\"|" "${bt}"
        sed -i "s|set black(password) .*|set black(password) \"${BT_AUTH_PASS}\"|" "${bt}"
        sed -i "s|set black(autologin) .*|set black(autologin) \"1\"|" "${bt}"
    else
        sed -i "s|set black(autologin) .*|set black(autologin) \"0\"|" "${bt}"
    fi

    if [ -n "${BT_XHOST}" ]; then
        sed -i "s|set black(hostadd) .*|set black(hostadd) \"*!*@%user%.${BT_XHOST}\"|" "${bt}"

        awk -v domain="${bt_domain}" -v xhost="${BT_XHOST}" '
            /^set black\(dns:host_excepts\) \{/{found=1}
            found && /^\}/{
                print "set black(dns:host_excepts) {"
                print "\"*." xhost "\""
                print "\"" domain "\""
                print "}"
                found=0; next
            }
            !found{print}
            found{next}
        ' "${bt}" > "${bt}.tmp" && mv "${bt}.tmp" "${bt}"

        awk -v domain="${bt_domain}" -v xhost="${BT_XHOST}" '
            /^set black\(noproxy:excepts\) \{/{found=1}
            found && /^\}/{
                print "set black(noproxy:excepts) {"
                print "\t\"*." xhost "\""
                print "\t\"" domain "\""
                print "}"
                found=0; next
            }
            !found{print}
            found{next}
        ' "${bt}" > "${bt}.tmp" && mv "${bt}.tmp" "${bt}"
    fi

    ohai "[${tty_blue}Patched${tty_reset}] ${tty_green}BlackTools.tcl${tty_reset} ready for ${tty_green}${NETWORK}${tty_reset}"
    echo
}

# ---------------------------------------------------------------------------
# Eggdrop settings collector (BlackTools)
# ---------------------------------------------------------------------------

eggdrop_setting_describe() {
    case "$1" in
        nick)       echo "    The primary ${tty_green}nickname${tty_reset} your bot will use on IRC." ;;
        altnick)    echo "    The alternate nickname used when ${tty_green}${BOTNICK}${tty_reset} is already taken on IRC." ;;
        username)   echo "    The ${tty_green}ident${tty_reset} (username) shown in your bot's IRC hostmask." ;;
        owner)      echo "    Your ${tty_green}owner${tty_reset} handle in eggdrop — this is how you control the bot." ;;
        realname)   echo "    The ${tty_green}realname${tty_reset} (GECOS) field for the bot, shown in /WHOIS." ;;
        server)     echo "    The IRC ${tty_green}server${tty_reset} the bot should connect to." ;;
        port)       echo "    The IRC ${tty_green}server port${tty_reset} to connect to. (default: 6667)" ;;
        channel)    echo "    The IRC ${tty_green}channel${tty_reset} the bot should join after connecting." ;;
        listen)     echo "    The ${tty_green}port number${tty_reset} > 1024 for incoming telnet/botnet connections." ;;
        vhost4)     echo "    The ${tty_green}IPv4 bind address${tty_reset} for outgoing IRC connections. Leave empty to skip." ;;
    esac
    echo
}

collect_eggdrop_settings() {
    echo
    ohai "Eggdrop settings..."
    echo

    ohai "[${tty_blue}Setting${tty_reset}] ${tty_green}nick${tty_reset}:"
    eggdrop_setting_describe "nick"
    NOEMPTY=1; NUMERIC=0
    ask_for_setting_value "nick" "PinoyBot"
    BOTNICK="${new_value}"

    echo
    ohai "[${tty_blue}Setting${tty_reset}] ${tty_green}altnick${tty_reset}:"
    eggdrop_setting_describe "altnick"
    NOEMPTY=1; NUMERIC=0
    ask_for_setting_value "altnick" "${BOTNICK}-"
    ALTNICK="${new_value}"

    echo
    ohai "[${tty_blue}Setting${tty_reset}] ${tty_green}username${tty_reset} (ident):"
    eggdrop_setting_describe "username"
    NOEMPTY=1; NUMERIC=0
    ask_for_setting_value "username" "$(whoami)"
    BOTUSERNAME="${new_value}"

    echo
    ohai "[${tty_blue}Setting${tty_reset}] ${tty_green}realname${tty_reset}:"
    eggdrop_setting_describe "realname"
    echo "    ${tty_bold}IRC Color Codes:${tty_reset}"
    echo "    ┌─────┬──────────────┬─────┬──────────────┐"
    echo "    │ ${tty_green}00${tty_reset}  │ White        │ ${tty_green}08${tty_reset}  │ Yellow       │"
    echo "    │ ${tty_green}01${tty_reset}  │ Black        │ ${tty_green}09${tty_reset}  │ Light Green  │"
    echo "    │ ${tty_green}02${tty_reset}  │ Navy Blue    │ ${tty_green}10${tty_reset}  │ Teal         │"
    echo "    │ ${tty_green}03${tty_reset}  │ Green        │ ${tty_green}11${tty_reset}  │ Cyan         │"
    echo "    │ ${tty_green}04${tty_reset}  │ Red          │ ${tty_green}12${tty_reset}  │ Blue         │"
    echo "    │ ${tty_green}05${tty_reset}  │ Brown        │ ${tty_green}13${tty_reset}  │ Magenta/Pink │"
    echo "    │ ${tty_green}06${tty_reset}  │ Purple       │ ${tty_green}14${tty_reset}  │ Grey         │"
    echo "    │ ${tty_green}07${tty_reset}  │ Orange       │ ${tty_green}15${tty_reset}  │ Light Grey   │"
    echo "    └─────┴──────────────┴─────┴──────────────┘"
    echo
    echo "    ${tty_bold}Formatting:${tty_reset}"
    echo "    ${tty_green}\\002${tty_reset} = Bold    ${tty_green}\\035${tty_reset} = Italic    ${tty_green}\\037${tty_reset} = Underline"
    echo
    echo "    ${tty_bold}Examples:${tty_reset}"
    echo "    ${tty_green}4 the legacy of me${tty_reset}         → red realname"
    echo "    ${tty_green}13 Clarity. Peace. Serenity${tty_reset} → magenta realname"
    echo "    ${tty_green}7 \\002Bold Orange Text${tty_reset}       → bold orange realname"
    echo
    NOEMPTY=1; NUMERIC=0
    ask_for_setting_value "realname" "Powered by PinoyChat - Arns®"
    REALNAME="$(colorize_realname "${new_value}")"

    echo
    ohai "[${tty_blue}Setting${tty_reset}] ${tty_green}owner${tty_reset}:"
    eggdrop_setting_describe "owner"
    NOEMPTY=1; NUMERIC=0
    ask_for_setting_value "owner" "$(whoami)"
    BOTOWNER="${new_value}"

    echo
    ohai "[${tty_blue}Setting${tty_reset}] ${tty_green}server${tty_reset}:"
    eggdrop_setting_describe "server"
    NOEMPTY=1; NUMERIC=0
    ask_for_setting_value "server" "${BOTSERVER}"
    BOTSERVER="${new_value}"

    echo
    ohai "[${tty_blue}Setting${tty_reset}] ${tty_green}port${tty_reset}:"
    eggdrop_setting_describe "port"
    NOEMPTY=1; NUMERIC=1
    ask_for_setting_value "port" "${BOTPORT}"
    BOTPORT="${new_value}"
    NUMERIC=0

    echo
    ohai "[${tty_blue}Setting${tty_reset}] ${tty_green}channel${tty_reset}:"
    eggdrop_setting_describe "channel"
    NOEMPTY=1; NUMERIC=0
    ask_for_setting_value "channel" "#pinoychat"
    CHANNEL="${new_value}"

    echo
    ohai "[${tty_blue}Setting${tty_reset}] ${tty_green}listen port${tty_reset}:"
    eggdrop_setting_describe "listen"
    getPort
    NOEMPTY=1; NUMERIC=1
    ask_for_setting_value "listen port" "${PORT}"
    LISTEN_PORT="${new_value}"
    NUMERIC=0

    if [ "${USE_WARP}" == "1" ] || [ "${USE_NATIVE6}" == "1" ]; then
        VHOST4=""; VHOST6=""
        echo
        ohai "Skipping vhost4/vhost6 (the installer sets this bot's IPv6 address)."
        return
    fi

    echo
    ohai "[${tty_blue}Setting${tty_reset}] ${tty_green}vhost4${tty_reset} (optional):"
    eggdrop_setting_describe "vhost4"
    getIPv4
    NOEMPTY=0; NUMERIC=0
    ask_for_setting_value "vhost4" "${IP4ADDRESS}"
    VHOST4="${new_value}"

    echo
    ohai "[${tty_blue}Setting${tty_reset}] ${tty_green}vhost6${tty_reset} (optional):"
    echo "    The ${tty_green}IPv6 bind address${tty_reset} for outgoing IRC connections. Leave empty to skip."
    echo
    getIPv6
    NOEMPTY=0; NUMERIC=0
    ask_for_setting_value "vhost6" "${IP6ADDRESS}"
    VHOST6="${new_value}"
}

# ---------------------------------------------------------------------------
# Write eggdrop.conf (BlackTools)
# ---------------------------------------------------------------------------

write_eggdrop_conf() {
    write_dalnet_script
    local conf="${EGGDROP_INSTALL_DIR}/${BOTNICK}.conf"
    mkdir -p "${EGGDROP_INSTALL_DIR}/logs"
    mkdir -p "${EGGDROP_INSTALL_DIR}/db"

    cat > "${conf}" <<EOF
#!/${EGGDROP_INSTALL_DIR}/eggdrop

# ===========================================================================
#  ${BOTNICK}.conf  --  auto-generated by PinoyChat Eggdrop+BlackTools Installer
#  Eggdrop ${EGGDROP_VER} | BlackTools | https://github.com/tclscripts/BlackTools-TCL
#  Network: ${NETWORK} | ${BOTSERVER}:${BOTPORT}
# ===========================================================================

set nick "${BOTNICK}"
set altnick "${ALTNICK}"
set botnet-nick "${BOTNICK}"
set username "${BOTUSERNAME}"
set owner "${BOTOWNER}"
set admin "${BOTOWNER}"
set network "${NETWORK}"
set realname "${REALNAME}"
set offset "+8"

${VHOST4:+set vhost4 "${VHOST4}"}
${VHOST6:+set vhost6 "${VHOST6}"}

listen ${LISTEN_PORT} all

set net-type "Other"
set servers "${BOTSERVER}:${BOTPORT}"

set timezone "UTC"
set env(TZ) "\$timezone+8"
set prefer-ipv6 ${PREFER_IPV6}
set max-logs 20
set max-logsize 0
set quick-logs 0
set raw-log 1
logfile mco * "logs/${BOTNICK}.log"
set log-time 1
set timestamp-format {[%H:%M:%S]}
set keep-all-logs 0
set logfile-suffix ".%d%b%Y"
set switch-logfiles-at 300
set quiet-save 0
set console "mkcoblxs"
set userfile "db/${BOTNICK}.user"
set help-path "help/"
set text-path "text/"
set motd "text/motd"
set telnet-banner "text/banner"
set userfile-perm 0600
set remote-boots 2
set share-unlinks 1
set protect-telnet 0
set dcc-sanitycheck 0
set ident-timeout 5
set require-p 1
set open-telnets 0
set stealth-telnets 1
set stealth-prompt "\n\nNickname.\n"
set use-telnet-banner 0
set connect-timeout 15
set dcc-flood-thr 3
set telnet-flood 5:60
set paranoid-telnet-flood 1
set ssl-capath "/etc/ssl/"
set ignore-time 15
set hourly-updates 00
set notify-newusers "\$owner"
set default-flags "hp"
set whois-fields "url birthday"
set must-be-owner 1
unbind dcc n simul *dcc:simul
set max-socks 100
set allow-dk-cmds 1
set dupwait-timeout 5
set strict-host 1
set cidr-support 0
set mod-path "modules/"
loadmodule blowfish
set blowfish-use-mode ecb
loadmodule channels
set chanfile "db/${BOTNICK}.chan"
set force-expire 0
set share-greet 0
set use-info 1
set allow-ps 0
set default-flood-chan 0:0
set default-flood-deop 0:0
set default-flood-kick 0:0
set default-flood-join 0:0
set default-flood-ctcp 0:0
set default-flood-nick 0:0
set default-aop-delay 0:0
set default-idle-kick 0
set default-chanmode ""
set default-stopnethack-mode 0
set default-revenge-mode 0
set default-ban-type 3
set default-ban-time 0
set default-exempt-time 60
set default-invite-time 60
set default-chanset {
        -autoop            -autovoice
        -bitch            +cycle
        -dontkickops    -dynamicbans
        +dynamicexempts +dynamicinvites
        -enforcebans    -greet
        -inactive        -nodesynch
        -protectfriends -protectops
        -revenge        -revengebot
        -secret            -seen
        +shared            -statuslog
        +userbans        +userexempts
        +userinvites    -protecthalfops
        -autohalfop        -static
}
loadmodule server
bind evnt - init-server evnt:init_server
proc evnt:init_server {type} {
  global botnick
  putquick "MODE \$botnick +i-ws"
}
set default-port ${BOTPORT}
set msg-rate 1
set keep-nick 1
set quiet-reject 1
set lowercase-ctcp 0
set answer-ctcp 3
set flood-msg 5:10
set flood-ctcp 3:60
set server-cycle-wait 60
set server-timeout 60
set check-stoned 1
set serverror-quit 1
set max-queue-msg 300
set trigger-on-ignore 0
set exclusive-binds 0
set double-mode 1
set double-server 1
set double-help 1
set optimize-kicks 0
set stack-limit 6
set nick-len 9
loadmodule ctcp
set ctcp-mode 1
loadmodule irc
set bounce-bans 0
set bounce-exempts 0
set bounce-invites 0
set bounce-modes 0
set max-bans 30
set max-exempts 20
set max-invites 20
set max-modes 30
set learn-users 0
set wait-split 1800
set wait-info 180
set mode-buf-length 200
unbind msg - hello *msg:hello
bind msg - hello *msg:hello
unbind msg - ident *msg:ident
unbind msg - addhost *msg:addhost
set opchars "@"
set no-chanrec-info 0
set prevent-mixing 1
set max-dloads 3
set dcc-block 0
set copy-to-tmp 1
set xfer-timeout 30
loadmodule notes
set notefile "db/${BOTNICK}.notes"
set max-notes 50
set note-life 60
set allow-fwd 0
set notify-users 0
set notify-onjoin 0
loadmodule console
set console-autosave 1
set force-channel 0
set info-party 0

channel add ${CHANNEL} {
  chanmode ""
  idle-kick 0
}

source scripts/BlackTools.tcl
${DAL_SRC_LINE}
EOF

    ohai "[${tty_blue}Written${tty_reset}] ${tty_green}${conf}${tty_reset}"
    echo
}

# ---------------------------------------------------------------------------
# Helper scripts (start.sh / stop.sh)
# ---------------------------------------------------------------------------

write_helpers() {
    local start_sh="${EGGDROP_INSTALL_DIR}/start.sh"
    local stop_sh="${EGGDROP_INSTALL_DIR}/stop.sh"

    cat > "${start_sh}" <<EOF
#!/bin/bash
cd "\$(dirname "\$0")"
if [ -f pid.file ] && kill -0 "\$(cat pid.file)" 2>/dev/null; then
    echo "Bot is already running (PID \$(cat pid.file))."
    exit 1
fi
./eggdrop -m ${BOTNICK}.conf
echo "Bot started. Check logs/${BOTNICK}.log for output."
EOF
    chmod +x "${start_sh}"

    cat > "${stop_sh}" <<EOF
#!/bin/bash
cd "\$(dirname "\$0")"
if [ -f pid.file ]; then
    PID=\$(cat pid.file)
    kill "\$PID" && echo "Bot (PID \${PID}) stopped." || echo "Failed to stop bot."
else
    echo "pid.file not found. Is the bot running?"
fi
EOF
    chmod +x "${stop_sh}"

    ohai "[${tty_blue}Created${tty_reset}] ${tty_green}start.sh${tty_reset} and ${tty_green}stop.sh${tty_reset}"
    echo

    write_systemd_service
}

write_helpers_aa() {
    local start_sh="${EGGDROP_INSTALL_DIR}/start.sh"
    local stop_sh="${EGGDROP_INSTALL_DIR}/stop.sh"

    cat > "${start_sh}" <<EOF
#!/bin/bash
cd "\$(dirname "\$0")"
if [ -f pid.file ] && kill -0 "\$(cat pid.file)" 2>/dev/null; then
    echo "Bot is already running (PID \$(cat pid.file))."
    exit 1
fi
./eggdrop -m ${BOTNICK}.conf
echo "Bot started. Check logs for output."
EOF
    chmod +x "${start_sh}"

    cat > "${stop_sh}" <<EOF
#!/bin/bash
cd "\$(dirname "\$0")"
if [ -f pid.${BOTNICK} ]; then
    PID=\$(cat pid.${BOTNICK})
    kill "\$PID" && echo "Bot (PID \${PID}) stopped." || echo "Failed to stop bot."
else
    echo "pid.${BOTNICK} not found. Is the bot running?"
fi
EOF
    chmod +x "${stop_sh}"

    ohai "[${tty_blue}Created${tty_reset}] ${tty_green}start.sh${tty_reset} and ${tty_green}stop.sh${tty_reset}"
    echo

    write_systemd_service
}

# ---------------------------------------------------------------------------
# systemd service
# ---------------------------------------------------------------------------

write_systemd_service() {
    local SVC_USER
    SVC_USER=$(whoami)
    local PID_FILE="${EGGDROP_INSTALL_DIR}/pid.${BOTNICK}"
    local SVC_NAME="eggdrop-${BOTNICK}"
    local SVC_FILE="/etc/systemd/system/${SVC_NAME}.service"

    if ! command -v systemctl >/dev/null 2>&1; then
        warn "systemd not found — skipping service creation."
        return
    fi

    if ! sudo -n true 2>/dev/null; then
        echo
        ohai "Sudo password required to create systemd service:"
        sudo true || {
            warn "Sudo failed — skipping systemd service. Create it manually later."
            return
        }
    fi

    ohai "Creating systemd service: ${tty_green}${SVC_NAME}${tty_reset}"

    sudo tee "${SVC_FILE}" > /dev/null <<SVCEOF
[Unit]
Description=Eggdrop IRC Bot - ${BOTNICK} (PinoyChat)
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
User=${SVC_USER}
Group=${SVC_USER}
WorkingDirectory=${EGGDROP_INSTALL_DIR}
PIDFile=${PID_FILE}
ExecStartPre=/bin/rm -f ${PID_FILE}
ExecStart=${EGGDROP_INSTALL_DIR}/eggdrop ${BOTNICK}.conf
ExecStop=/bin/kill -TERM \$MAINPID
Restart=always
RestartSec=30
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
SVCEOF

    if type resilience_attach_service >/dev/null 2>&1; then resilience_attach_service "${SVC_NAME}"; fi
    sudo systemctl daemon-reload
    sudo systemctl enable "${SVC_NAME}" > /dev/null 2>&1

    ohai "[${tty_blue}Enabled${tty_reset}] ${tty_green}${SVC_NAME}.service${tty_reset} — bot will auto-start on reboot"
    echo
    echo "    ${tty_bold}Manage your bot with:${tty_reset}"
    echo "    ${tty_green}sudo systemctl start   ${SVC_NAME}${tty_reset}"
    echo "    ${tty_green}sudo systemctl stop    ${SVC_NAME}${tty_reset}"
    echo "    ${tty_green}sudo systemctl restart ${SVC_NAME}${tty_reset}"
    echo "    ${tty_green}sudo systemctl status  ${SVC_NAME}${tty_reset}"
    echo
}

# ---------------------------------------------------------------------------
# Get eggdrop PID
# ---------------------------------------------------------------------------

EGG_STARTED=0
PID=""

get_eggdrop_pid() {
    PID=""
    local p1 p2
    p1=$(pgrep -u "$(id -u)" -f "eggdrop ${BOTNICK}.conf" 2>/dev/null | head -1)
    p2=$(pgrep -u "$(id -u)" -f "eggdrop -m ${BOTNICK}.conf" 2>/dev/null | head -1)
    [ -n "$p1" ] && PID=$p1
    [ -z "$PID" ] && [ -n "$p2" ] && PID=$p2
}

# ---------------------------------------------------------------------------
# start_bot — with reliable ownership auto-detection via log watching
# ---------------------------------------------------------------------------
#
# Fix summary:
#   OLD: watched only for userfile on disk — missed it during uhost refresh race
#   NEW: watches the eggdrop log for ownership confirmation strings, which are
#        written regardless of the bot's IRC activity (uhost refresh, rejoin, etc.)
#        Userfile + pidfile kept as secondary/tertiary fallbacks.
#        Live log tail shown in terminal so user sees exactly what's happening.
# ---------------------------------------------------------------------------

start_bot() {
    local input
    echo
    ohai "Do you want to start the bot now? (${tty_green}Y${tty_reset})es or (${tty_green}N${tty_reset})o"
    echo
    getc input
    if [[ "${input}" == 'y' ]]; then
        cd "${EGGDROP_INSTALL_DIR}"

        # -- WARP: build this bot's tunnel first. NEVER fall back to starting outside it.
        if [ "${USE_WARP}" == "1" ]; then
            if ! warp_prepare_bot; then
                echo "    Bot NOT started (so it cannot show your real IP). When ready, run:"
                echo "        ${tty_green}sudo warpfirst ${BOTNICK}${tty_reset}"
                echo
                return
            fi
        fi

        # -- own IPv6 address: create it and bind the bot's config to it before the first run
        if [ "${USE_NATIVE6}" == "1" ]; then
            if ! native6_prepare_bot; then
                echo "    Bot NOT started. When ready, run: ${tty_green}sudo botip6 --no-restart ${BOTNICK}${tty_reset}"
                echo "    then: cd ${EGGDROP_INSTALL_DIR} && ./eggdrop -m ${BOTNICK}.conf"
                echo
                return
            fi
        fi

        local logfile="${EGGDROP_INSTALL_DIR}/logs/${BOTNICK}.log"
        local userfile="${EGGDROP_INSTALL_DIR}/db/${BOTNICK}.user"
        if [ "${INSTALL_PACKAGE}" == "aa" ] && [ -n "${BOTUSERNAME:-}" ]; then
            # A&A names its files after the username (ident), which can differ from the nick
            logfile="${EGGDROP_INSTALL_DIR}/logs/${BOTUSERNAME}.log"
            userfile="${EGGDROP_INSTALL_DIR}/db/${BOTUSERNAME}.user"
        fi
        local pidfile="${EGGDROP_INSTALL_DIR}/pid.${BOTNICK}"
        local TAIL_PID=""
        local SETUP_PID=""

        # ── Cleanup helper — runs on Ctrl+C or normal exit ────────────────────
        # Kills the background tail and the eggdrop -m instance so no stale
        # pidfile is left behind to break systemd on the next step.
        _start_bot_cleanup() {
            [ -n "${TAIL_PID}" ]  && kill "${TAIL_PID}"  2>/dev/null; wait "${TAIL_PID}"  2>/dev/null
            [ -n "${SETUP_PID}" ] && kill "${SETUP_PID}" 2>/dev/null
            if [ -n "${SETUP_PID}" ] && kill -0 "${SETUP_PID}" 2>/dev/null; then
                sleep 2
                kill -9 "${SETUP_PID}" 2>/dev/null
            fi
            # an aborted first run leaves an EMPTY userfile; eggdrop then ignores -m and "hello" does nothing
            if [ "${START_USER_EXISTED:-1}" = "0" ] && [ "${START_OWNED_DONE:-0}" = "0" ]; then
                local _w=0
                while [ -n "${SETUP_PID}" ] && kill -0 "${SETUP_PID}" 2>/dev/null && [ "${_w}" -lt 8 ]; do
                    sleep 1; _w=$((_w + 1))
                done
                rm -f "${userfile}" 2>/dev/null
            fi
            rm -f "${pidfile}" 2>/dev/null
        }
        trap '_start_bot_cleanup; exit 1' INT TERM

        # ── Step 1: start in -m (make userfile / ownership claim) mode ────────
        echo
        ohai "Starting ${tty_green}${BOTNICK}${tty_reset} in setup mode ${tty_bold}(-m)${tty_reset}..."
        echo
        echo "    The bot is now connecting to ${tty_green}${BOTSERVER}${tty_reset}."
        echo "    ${tty_bold}On IRC, send this private message to claim ownership:${tty_reset}"
        echo
        echo "        ${tty_green}/msg ${BOTNICK} hello${tty_reset}"
        echo
        echo "    This installer will auto-detect the moment you complete it."
        echo

        # Remove stale pid file from any previous run
        rm -f "${pidfile}" 2>/dev/null
        START_USER_EXISTED=0; [ -f "${userfile}" ] && START_USER_EXISTED=1
        START_OWNED_DONE=0

        # Truncate log so we only scan NEW lines written from this run onward.
        # This is critical — the false-positive bug was caused by the grep
        # matching "owner" inside config lines that eggdrop echoes at startup
        # (e.g. "set owner tasing", "notify-newusers $owner").
        # Truncating first means only post-startup IRC activity is in the log.
        mkdir -p "${EGGDROP_INSTALL_DIR}/logs"
        : > "${logfile}" 2>/dev/null || true

        if [ "${USE_WARP}" == "1" ]; then
            warp_run_first_mode
        else
            ./eggdrop -m "${BOTNICK}.conf" > /dev/null 2>&1
        fi
        sleep 3

        # Verify it actually started
        get_eggdrop_pid
        if [ -z "$PID" ]; then
            trap - INT TERM
            ring_bell
            echo "${tty_red}Error:${tty_reset} Eggdrop failed to start in -m mode."
            echo "    Check ${tty_green}logs/${BOTNICK}.log${tty_reset} for errors."
            echo
            return
        fi
        SETUP_PID="${PID}"

        # A&A writes dated logs (BOT.log.04Oct2026): follow the newest log file and only scan NEW lines
        local _newlog _skip
        _newlog="$(ls -t "${EGGDROP_INSTALL_DIR}"/logs/*.log* 2>/dev/null | head -1)"
        [ -n "${_newlog}" ] && logfile="${_newlog}"
        _skip=$(( $(wc -l < "${logfile}" 2>/dev/null || echo 0) + 1 ))

        ohai "Bot running in setup mode. ${tty_bold}PID: ${tty_green}${SETUP_PID}${tty_reset}"
        echo
        echo "    Watching the bot log live — IRC activity will appear below as it connects."
        echo "    Go to IRC now and send: ${tty_green}/msg ${BOTNICK} hello${tty_reset}"
        echo
        echo "    ${tty_bold}─────────────────── live log ───────────────────${tty_reset}"
        echo

        # ── Step 2: watch log for ownership confirmation ──────────────────────
        #
        # IMPORTANT — what we look for and why:
        #
        # The false-positive bug: eggdrop echoes config lines into the log at
        # startup, including "set owner tasing" and "notify-newusers $owner".
        # Our old pattern matched "owner" anywhere, so it fired instantly on
        # those startup echoes before the user even typed hello.
        #
        # The fix: we only match strings that eggdrop writes DURING the hello
        # handshake, not during config load. These are:
        #
        #   "MSG * hello"        — eggdrop logs the /msg hello command itself
        #   "hello processed"    — eggdrop core after processing hello
        #   "Added * (owner)"    — eggdrop core when it writes the userfile entry
        #   "YOU ARE THE OWNER"  — BlackTools/A&A notice echoed back to the bot
        #   "don't need.*-m"     — eggdrop's "you no longer need -m" message
        #
        # Userfile creation on disk is a reliable secondary signal because
        # eggdrop only creates it after a successful hello — not at startup.
        #
        # The uhost refresh (bot parts/rejoins for +x cloak) happens AFTER
        # eggdrop already wrote these log entries, so it never blocks detection.

        local owned=0
        local watch_secs=0
        local MAX_WAIT=600   # 10 minutes max

        # Background tail so user sees live log output
        tail -n 0 -f "${logfile}" 2>/dev/null &
        TAIL_PID=$!

        while [ "${owned}" -eq 0 ] && [ "${watch_secs}" -lt "${MAX_WAIT}" ]; do
            sleep 2
            watch_secs=$(( watch_secs + 2 ))

            # Primary: scan log for hello-handshake-specific strings only.
            # These lines are written by eggdrop/BlackTools during the hello
            # exchange and cannot appear from config loading at startup.
            if [ -f "${logfile}" ]; then
                if tail -n "+${_skip}" "${logfile}" 2>/dev/null | grep -qiE \
                    "(MSG .* hello|hello processed|Added .+ \(owner\)|YOU ARE THE OWNER|don't need.*-m|no longer need.*-m)"; then
                    owned=1
                    break
                fi
            fi

            # Secondary: userfile appeared on disk — eggdrop only writes this
            # file after a successful hello, never at startup.
            if [ -f "${userfile}" ] && grep -qE '^[^#&$:@%!-][^ ]* +[^ ]+ +[a-zA-Z]*n[a-zA-Z]*( |$)' "${userfile}" 2>/dev/null; then
                owned=1
                break
            fi

            # Check bot is still alive; if it exited check for userfile
            if ! kill -0 "${SETUP_PID}" 2>/dev/null; then
                if [ -f "${userfile}" ] && grep -qE '^[^#&$:@%!-][^ ]* +[^ ]+ +[a-zA-Z]*n[a-zA-Z]*( |$)' "${userfile}" 2>/dev/null; then
                    owned=1
                    break
                fi
            fi
        done

        # Stop the live log tail cleanly
        kill "${TAIL_PID}" 2>/dev/null
        wait "${TAIL_PID}" 2>/dev/null
        TAIL_PID=""
        [ "${owned}" -eq 1 ] && START_OWNED_DONE=1

        echo
        echo "    ${tty_bold}────────────────────────────────────────────────${tty_reset}"
        echo

        if [ "${owned}" -eq 0 ]; then
            ring_bell
            echo "${tty_yellow}Warning:${tty_reset} Ownership was not auto-detected within 10 minutes."
            echo "    If you already sent ${tty_green}/msg ${BOTNICK} hello${tty_reset} and received the"
            echo "    ownership messages on IRC, your setup IS complete."
            echo "    Check ${tty_green}logs/${BOTNICK}.log${tty_reset} if you're unsure."
            echo
            read -r -p "    Press ENTER to continue or Ctrl+C to abort: " </dev/tty || true
            echo
        else
            ohai "${tty_green}✓ Ownership detected!${tty_reset} The hello phase is complete."
            echo
        fi

        # ── Step 3: grace period — set password, finish IRC setup ────────────
        # 3 minutes so the owner has time to set their password and do any
        # other first-run IRC steps before the bot restarts into normal mode.
        echo "    ${tty_bold}Set your bot password now if you haven't yet:${tty_reset}"
        echo "    ${tty_green}/msg ${BOTNICK} pass <your-password>${tty_reset}"
        echo
        echo "    Press ${tty_bold}ENTER${tty_reset} when done, or wait — this continues"
        echo "    automatically in ${tty_bold}3 minutes${tty_reset}."
        echo
        read -t 180 -r -p "    Waiting (press ENTER to continue now)... " </dev/tty || true
        echo
        ohai "Proceeding..."
        echo

        sleep 2

        # ── Step 4: stop the -m instance cleanly ─────────────────────────────
        ohai "Stopping setup mode instance..."
        get_eggdrop_pid
        SETUP_PID="${PID}"
        if [ -n "${SETUP_PID}" ]; then
            kill "${SETUP_PID}" 2>/dev/null
            sleep 3
            if kill -0 "${SETUP_PID}" 2>/dev/null; then
                kill -9 "${SETUP_PID}" 2>/dev/null
                sleep 1
            fi
        fi
        # safety net: make sure no setup-mode instance of THIS bot is left (it would hold the listen port)
        pkill -u "$(id -u)" -f "eggdrop -m ${BOTNICK}.conf" 2>/dev/null
        local _t=0
        while pgrep -u "$(id -u)" -f "eggdrop -m ${BOTNICK}.conf" >/dev/null 2>&1 && [ "${_t}" -lt 8 ]; do
            sleep 1; _t=$((_t + 1))
        done
        pkill -9 -u "$(id -u)" -f "eggdrop -m ${BOTNICK}.conf" 2>/dev/null
        rm -f "${pidfile}" 2>/dev/null
        SETUP_PID=""

        # Remove trap — cleanup no longer needed from this point
        trap - INT TERM

        # ── Step 5: hand off to systemd (or direct fallback) ─────────────────
        local SVC_NAME="eggdrop-${BOTNICK}"
        if command -v systemctl >/dev/null 2>&1 && (sudo -n true 2>/dev/null || sudo true 2>/dev/null); then
            ohai "Starting ${tty_green}${BOTNICK}${tty_reset} via systemd..."
            if [ "${USE_WARP}" == "1" ]; then
                if ! warp_attach_service "${SVC_NAME}"; then
                    ring_bell
                    echo "${tty_red}Error:${tty_reset} could not attach the bot to its WARP tunnel - NOT starting it."
                    echo "    Fix, then run: ${tty_green}sudo warpbot ${BOTNICK}${tty_reset}"
                    echo
                    return
                fi
            fi
            sudo systemctl start "${SVC_NAME}"
            sleep 3

            if sudo systemctl is-active --quiet "${SVC_NAME}"; then
                EGG_STARTED=1
                PID=$(pgrep -u "$(id -u)" -f "eggdrop ${BOTNICK}.conf" 2>/dev/null | head -1)
                if [ "${USE_WARP}" == "1" ]; then
                    WARP_IPV6="$(warp_egress_ip)"
                fi
                echo
                ohai "${tty_green}Bot is running via systemd!${tty_reset} PID: ${tty_green}${PID}${tty_reset}"
                echo
            else
                ring_bell
                echo "${tty_red}Error:${tty_reset} systemd failed to start the bot."
                echo "    Check: ${tty_green}sudo journalctl -u ${SVC_NAME} -n 30${tty_reset}"
                echo
            fi
        else
            ohai "Starting ${tty_green}${BOTNICK}${tty_reset} normally..."
            ./eggdrop "${BOTNICK}.conf" > /dev/null 2>&1
            sleep 2
            get_eggdrop_pid
            if [ -n "$PID" ]; then
                EGG_STARTED=1
                ohai "${tty_green}Bot started!${tty_reset} PID: ${tty_green}${PID}${tty_reset}"
                echo
            else
                ring_bell
                echo "${tty_red}Error:${tty_reset} Bot failed to start. Check ${tty_green}logs/${BOTNICK}.log${tty_reset}"
                echo
            fi
        fi

    elif [[ "${input}" == 'n' ]]; then
        echo
        ohai "Bot not started. To start manually:"
        echo
        if [ "${USE_WARP}" == "1" ]; then
            echo "    ${tty_bold}First run (inside its own WARP tunnel):${tty_reset}"
            echo "    ${tty_green}sudo warpfirst ${BOTNICK}${tty_reset}"
            echo
            echo "    ${tty_yellow}Do NOT run ./eggdrop or systemctl start before that - the bot would show your real IP.${tty_reset}"
        elif [ "${USE_NATIVE6}" == "1" ]; then
            echo "    ${tty_bold}1)${tty_reset} give it its own IPv6:  ${tty_green}sudo botip6 --no-restart ${BOTNICK}${tty_reset}"
            echo "    ${tty_bold}2)${tty_reset} first run only:        cd ${EGGDROP_INSTALL_DIR} && ./eggdrop -m ${BOTNICK}.conf"
            echo "    ${tty_bold}3)${tty_reset} afterwards:            ${tty_green}sudo systemctl start eggdrop-${BOTNICK}${tty_reset}"
        else
            echo "    ${tty_green}sudo systemctl start eggdrop-${BOTNICK}${tty_reset}"
            echo "    ${tty_bold}First run only:${tty_reset} cd ${EGGDROP_INSTALL_DIR} && ./eggdrop -m ${BOTNICK}.conf"
        fi
        echo
    else
        start_bot
    fi
}

# ---------------------------------------------------------------------------
# Show success summary (BlackTools)
# ---------------------------------------------------------------------------

show_success() {
    getIPv4
    echo
    echo "    ${tty_green}============================================================${tty_reset}"
    echo "    ${tty_bold}PinoyChat Eggdrop + BlackTools Installation Complete!${tty_reset}"
    echo "    ${tty_green}============================================================${tty_reset}"
    echo
    echo "    ${tty_bold}Network       :${tty_reset} ${NETWORK} (${BOTSERVER}:${BOTPORT})"
    echo "    ${tty_bold}Install dir   :${tty_reset} ${EGGDROP_INSTALL_DIR}"
    echo "    ${tty_bold}Config file   :${tty_reset} ${EGGDROP_INSTALL_DIR}/${BOTNICK}.conf"
    echo "    ${tty_bold}BlackTools    :${tty_reset} ${EGGDROP_INSTALL_DIR}/scripts/BlackTools.tcl"
    echo "    ${tty_bold}Logs          :${tty_reset} ${EGGDROP_INSTALL_DIR}/logs/${BOTNICK}.log"
    echo
    if [ "${EGG_STARTED}" == "1" ]; then
        echo "    ${tty_bold}Status        :${tty_reset} ${tty_green}Running${tty_reset} (PID: ${PID})"
        echo
        if [ "${USE_NATIVE6}" == "1" ]; then
            echo "    ${tty_bold}Bot IPv6      :${tty_reset} ${tty_green}${NATIVE6_ADDR}${tty_reset}  (its own address; compare with /whois ${BOTNICK})"
        fi
        if [ "${USE_WARP}" == "1" ]; then
            echo "    ${tty_bold}WARP address  :${tty_reset} ${tty_green}${WARP_IPV6:-unknown}${tty_reset}  (compare with /whois ${BOTNICK})"
            echo "    Partyline telnet is only reachable inside the bot's WARP tunnel - control it over IRC."
        else
            echo "    Partyline via telnet: ${tty_green}telnet ${IP4ADDRESS} ${LISTEN_PORT}${tty_reset}"
        fi
    else
        if [ "${USE_WARP}" == "1" ]; then
            echo "    ${tty_bold}FIRST RUN     :${tty_reset} ${tty_green}sudo warpfirst ${BOTNICK}${tty_reset}   (inside its WARP tunnel)"
            echo "    ${tty_yellow}Do NOT start it with ./eggdrop or systemctl before that (real IP would show).${tty_reset}"
        else
            echo "    ${tty_bold}Start bot     :${tty_reset} sudo systemctl start eggdrop-${BOTNICK}"
        fi
        echo "    ${tty_bold}Stop bot      :${tty_reset} sudo systemctl stop eggdrop-${BOTNICK}"
        echo "    ${tty_bold}Auto-start    :${tty_reset} ${tty_green}enabled${tty_reset} (starts on reboot automatically)"
        echo
        echo "    ${tty_yellow}First run tip:${tty_reset} The bot starts in ${tty_bold}-m${tty_reset} (make user) mode."
        echo "    Connect to IRC and send: ${tty_green}/msg ${BOTNICK} hello${tty_reset}"
        echo "    to claim ownership as ${tty_green}${BOTOWNER}${tty_reset}."
    fi
    echo
    echo "    ${tty_bold}BlackTools help:${tty_reset} Type ${tty_green}.h${tty_reset} on partyline"
    echo "    or ${tty_green}!help${tty_reset} in channel (once BT is configured)."
    echo
    echo "    ${tty_bold}Support:${tty_reset}"
    echo "    PinoyChat : ${tty_underline}https://pinoychat.fun/live${tty_reset}"
    echo "    Eggdrop   : ${tty_underline}https://www.eggheads.org${tty_reset}"
    echo "    BlackTools: ${tty_underline}https://github.com/tclscripts/BlackTools-TCL${tty_reset}"
    echo "                ${tty_underline}https://www.tclscripts.net${tty_reset}"
    echo
    printf "    Enjoy! \xF0\x9F\x8D\xBA\n"
    echo
}

# ---------------------------------------------------------------------------
# Show success summary (A&A)
# ---------------------------------------------------------------------------

show_success_aa() {
    getIPv4
    echo
    echo "    ${tty_green}============================================================${tty_reset}"
    echo "    ${tty_bold}PinoyChat Eggdrop + A&A (light) Installation Complete!${tty_reset}"
    echo "    ${tty_green}============================================================${tty_reset}"
    echo
    echo "    ${tty_bold}Network       :${tty_reset} ${NETWORK} (${BOTSERVER}:${BOTPORT})"
    echo "    ${tty_bold}Install dir   :${tty_reset} ${EGGDROP_INSTALL_DIR}"
    echo "    ${tty_bold}Config file   :${tty_reset} ${EGGDROP_INSTALL_DIR}/${BOTNICK}.conf"
    echo "    ${tty_bold}A&A scripts   :${tty_reset} ${EGGDROP_INSTALL_DIR}/ascript/"
    echo "    ${tty_bold}Settings      :${tty_reset} ${EGGDROP_INSTALL_DIR}/settings.conf"
    echo "    ${tty_bold}Data files    :${tty_reset} ${EGGDROP_INSTALL_DIR}/db/  (user/chan/notes/info)"
    echo "    ${tty_bold}Home channel  :${tty_reset} ${AA_HOMECHAN}"
    echo "    ${tty_bold}Supp channel  :${tty_reset} ${AA_SUPPCHAN}"
    echo
    if [ "${EGG_STARTED}" == "1" ]; then
        echo "    ${tty_bold}Status        :${tty_reset} ${tty_green}Running${tty_reset} (PID: ${PID})"
        echo
        echo "    ${tty_bold}Ownership already claimed${tty_reset} — your bot is fully set up and running."
        echo
        echo "    To authenticate on IRC:"
        echo "        ${tty_green}/msg ${BOTNICK} auth <your-password>${tty_reset}"
        echo
        if [ "${USE_NATIVE6}" == "1" ]; then
            echo "    ${tty_bold}Bot IPv6      :${tty_reset} ${tty_green}${NATIVE6_ADDR}${tty_reset}  (its own address; compare with /whois ${BOTNICK})"
        fi
        if [ "${USE_WARP}" == "1" ]; then
            echo "    ${tty_bold}WARP address  :${tty_reset} ${tty_green}${WARP_IPV6:-unknown}${tty_reset}  (compare with /whois ${BOTNICK})"
            echo "    Partyline telnet is only reachable inside the bot's WARP tunnel - control it over IRC."
        else
            echo "    Partyline via telnet: ${tty_green}telnet ${IP4ADDRESS} ${LISTEN_PORT}${tty_reset}"
        fi
    else
        if [ "${USE_WARP}" == "1" ]; then
            echo "    ${tty_bold}FIRST RUN     :${tty_reset} ${tty_green}sudo warpfirst ${BOTNICK}${tty_reset}   (inside its WARP tunnel)"
            echo "    ${tty_yellow}Do NOT start it with ./eggdrop or systemctl before that (real IP would show).${tty_reset}"
        else
            echo "    ${tty_bold}Start bot     :${tty_reset} sudo systemctl start eggdrop-${BOTNICK}"
        fi
        echo "    ${tty_bold}Stop bot      :${tty_reset} sudo systemctl stop eggdrop-${BOTNICK}"
        echo "    ${tty_bold}Auto-start    :${tty_reset} ${tty_green}enabled${tty_reset} (starts on reboot automatically)"
    fi
    echo
    echo "    ${tty_bold}A&A commands  :${tty_reset} ${tty_green}!help${tty_reset} in channel or partyline"
    echo "    ${tty_bold}A&A README    :${tty_reset} ${EGGDROP_INSTALL_DIR}/ascript.README/INFO"
    echo
    echo "    ${tty_bold}Support:${tty_reset}"
    echo "    PinoyChat : ${tty_underline}https://pinoychat.fun/live${tty_reset}"
    echo "    Eggdrop   : ${tty_underline}https://www.eggheads.org${tty_reset}"
    echo "    A&A       : ${tty_underline}http://ascript.name${tty_reset}"
    echo
    printf "    Enjoy! \xF0\x9F\x8D\xBA\n"
    echo
}

# ---------------------------------------------------------------------------
# Resilience toolkit: survive internet outages / unpaid bills / hard power loss
# ---------------------------------------------------------------------------
#   eggdrop-dbguard   before every start: recreate db/, restore damaged or missing userfiles
#   eggdrop-dbbackup  every 30 min: keep valid copies (48 half-hourly + 14 daily) in /var/backups/eggdrop
#   eggdrop-stagger   after a reboot: spread the bot starts out
#   eggdrop-doctor    one command to check/repair everything  (eggdrop-doctor --start)
#   warpns-watchdog   (rewritten) does NOTHING while the host has no internet
# Retrofit all existing bots:  ./installer.sh -r
# ---------------------------------------------------------------------------

install_resilience_toolkit() {
    if [ -z "${BT_ON_LINUX-}" ] || ! command -v systemctl >/dev/null 2>&1; then
        warn "Resilience toolkit needs Linux + systemd - skipped."
        return 0
    fi
    check_sudo
    ohai "Installing the ${tty_green}resilience toolkit${tty_reset} (backups, auto-repair, outage-safe watchdog)..."
    sudo tee /usr/local/bin/eggdrop-dbguard >/dev/null <<'RES_GUARD'
#!/bin/bash
# eggdrop-dbguard [BOTDIR]   (runs as root before every bot start; BOTDIR defaults to the current dir)
# 1. recreates a missing db/ folder
# 2. replaces a damaged/truncated .user/.chan file with the newest GOOD copy (~bak or hourly backup)
# 3. brings back db files that vanished completely (e.g. after rm -rf db)
# Never deletes anything: a damaged file is kept as FILE.broken.
dir=${1:-$(pwd)}; db="$dir/db"; bk=${EGG_BACKUP_DIR:-/var/backups/eggdrop}
log() { logger -t eggdrop-dbguard "$*" 2>/dev/null; echo "eggdrop-dbguard: $*"; }
valid() {
  [ -s "$1" ] || return 1
  case "$1" in
    *.user|*.user~bak) [ "$(head -c 4 "$1" 2>/dev/null)" = "#4v:" ] ;;
    *)                 [ "$(head -c 1 "$1" 2>/dev/null)" = "#" ] ;;
  esac
}
own=$(stat -c %U:%G "$dir" 2>/dev/null) || exit 0
if [ ! -d "$db" ]; then
  mkdir -p "$db" && chown "$own" "$db" && chmod 775 "$db"
  log "$dir: db/ was missing - recreated"
fi
# damaged files
for f in "$db"/*.user "$db"/*.chan; do
  [ -e "$f" ] || continue
  valid "$f" && continue
  key=$(printf '%s' "$f" | tr / _)
  good=""
  for c in $(ls -1t "$f~bak" "$bk/$key".h.* "$bk/$key".d.* 2>/dev/null); do
    if valid "$c"; then good=$c; break; fi
  done
  cp -p "$f" "$f.broken" 2>/dev/null
  if [ -n "$good" ]; then
    cp -p "$good" "$f" && chown "$own" "$f" && chmod 600 "$f" && log "$f was damaged - restored from $good"
  else
    log "$f is damaged and there is NO good copy"
  fi
done
# vanished files
prefix=$(printf '%s/' "$db" | tr / _)
for c in $(ls -1t "$bk/$prefix"* 2>/dev/null); do
  b=${c##*/}; rest=${b#"$prefix"}; name=${rest%%.[hd].*}
  [ -n "$name" ] && [ ! -e "$db/$name" ] || continue
  valid "$c" || continue
  cp -p "$c" "$db/$name" && chown "$own" "$db/$name" && chmod 600 "$db/$name" && log "$db/$name was missing - restored from $c"
done
exit 0
RES_GUARD
    sudo tee /usr/local/bin/eggdrop-dbbackup >/dev/null <<'RES_BACKUP'
#!/bin/bash
# eggdrop-dbbackup   (run by eggdrop-dbbackup.timer every 30 min)
# Saves every VALID userfile/chanfile: 48 half-hourly copies + 14 daily copies per file.
# A damaged file is never copied, so a good backup always survives.
bk=${EGG_BACKUP_DIR:-/var/backups/eggdrop}; homes=${EGG_HOMES:-/home}
mkdir -p "$bk"; chmod 700 "$bk"
stamp=$(date +%Y%m%d-%H%M); day=$(date +%Y%m%d)
valid() {
  [ -s "$1" ] || return 1
  case "$1" in
    *.user) [ "$(head -c 4 "$1")" = "#4v:" ] ;;
    *)      [ "$(head -c 1 "$1")" = "#" ] ;;
  esac
}
for f in "$homes"/*/*/db/*.user "$homes"/*/*/db/*.chan; do
  [ -f "$f" ] || continue
  valid "$f" || continue
  key=$(printf '%s' "$f" | tr / _)
  last=$(ls -1t "$bk/$key".h.* 2>/dev/null | head -1)
  if [ -z "$last" ] || ! cmp -s "$f" "$last"; then cp -p "$f" "$bk/$key.h.$stamp"; fi
  [ -e "$bk/$key.d.$day" ] || cp -p "$f" "$bk/$key.d.$day"
  ls -1t "$bk/$key".h.* 2>/dev/null | tail -n +49 | xargs -r rm -f
  ls -1t "$bk/$key".d.* 2>/dev/null | tail -n +15 | xargs -r rm -f
done
exit 0
RES_BACKUP
    sudo tee /usr/local/bin/eggdrop-stagger >/dev/null <<'RES_STAGGER'
#!/bin/bash
# eggdrop-stagger: right after a reboot, spread bot starts over ~90 s so dozens of bots
# do not hit the IRC server (and the WARP tunnels) in the same second.
up=$(cut -d. -f1 /proc/uptime)
[ "${up:-9999}" -lt 400 ] || exit 0
sleep $(( $(pwd | cksum | cut -d' ' -f1) % 90 ))
exit 0
RES_STAGGER
    sudo tee /usr/local/bin/eggdrop-doctor >/dev/null <<'RES_DOCTOR'
#!/bin/bash
# eggdrop-doctor [--start]
# One command to check and repair the whole shell server after an outage.
#   (no option)  check/repair userfiles, find duplicate bots, failed services, orphan services
#   --start      also start every enabled bot that is not running, one by one (20 s apart)
[ "$(id -u)" = 0 ] || exec sudo "$0" "$@"
echo "== 1. userfiles (damaged ones are restored from the newest good copy)"
n=0
for d in /home/*/*/db; do
  ls "$d"/*.user >/dev/null 2>&1 || continue
  eggdrop-dbguard "$(dirname "$d")"; n=$((n+1))
done
echo "   checked $n bot folders"
echo "== 2. bots running more than once"
dups=$(ps -eo user:20,args | awk '$2 ~ /eggdrop$/ {print $1, $NF}' | sort | uniq -d)
[ -n "$dups" ] && echo "$dups" || echo "   none"
echo "== 3. enabled bot services that are not running"
bad=0
for u in $(systemctl list-unit-files 'eggdrop-*.service' --no-legend | awk '$2=="enabled"{print $1}'); do
  s=$(systemctl is-active "$u")
  [ "$s" = active ] || { echo "   $u: $s"; bad=1; }
done
[ $bad = 0 ] && echo "   all running"
echo "== 4. services whose Linux user no longer exists"
orph=0
for f in /etc/systemd/system/*.service; do
  [ -f "$f" ] || continue
  u=$(sed -n 's/^User=//p' "$f" | head -1)
  [ -n "$u" ] && ! getent passwd "$u" >/dev/null && { echo "   $(basename "$f") (user '$u' is gone)"; orph=1; }
done
[ $orph = 0 ] && echo "   none"
if [ "${1:-}" = "--start" ]; then
  echo "== 5. starting stopped bots, one at a time"
  for u in $(systemctl list-unit-files 'eggdrop-*.service' --no-legend | awk '$2=="enabled"{print $1}'); do
    systemctl is-active -q "$u" && continue
    echo "   starting $u"; systemctl start "$u"; sleep 20
  done
fi
exit 0
RES_DOCTOR
    sudo tee /etc/systemd/system/eggdrop-dbbackup.service >/dev/null <<'RES_BKSVC'
[Unit]
Description=Back up Eggdrop userfiles and channel files
[Service]
Type=oneshot
Nice=19
ExecStart=/usr/local/bin/eggdrop-dbbackup
RES_BKSVC
    sudo tee /etc/systemd/system/eggdrop-dbbackup.timer >/dev/null <<'RES_BKTMR'
[Unit]
Description=Back up Eggdrop userfiles every 30 minutes
[Timer]
OnBootSec=5min
OnCalendar=*:0/30
Persistent=true
[Install]
WantedBy=timers.target
RES_BKTMR
    # outage-safe replacement for the old watchdog (only if the WARP toolkit is in use)
    if [ -f /usr/local/bin/warpns-watchdog ] || [ -d /etc/warpns ]; then
    sudo tee /usr/local/bin/warpns-watchdog >/dev/null <<'RES_WD'
#!/bin/bash
# Run every minute by warpns-watchdog.timer.
# Heals a dead WARP tunnel - but ONLY while this machine itself has internet.
# When the whole connection is down (overdue bill, router off) every tunnel looks dead; restarting
# them would kill all bots in the middle of saving their userfiles and shuffle UDP ports for nothing.
st=/run/warpns-watchdog; mkdir -p "$st"
ports=(4500 2408 500 1701)
host_online() {
  ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 || ping -c1 -W3 8.8.8.8 >/dev/null 2>&1 || \
    curl -4 -s -m 6 -o /dev/null https://1.1.1.1
}
alive() { ip netns exec "$1" curl -6 -s -m 8 -o /dev/null https://ipv6.icanhazip.com; }
now=$(date +%s)
if ! host_online; then
  [ -e "$st/offline" ] || logger -t warpns-watchdog "no internet on the host - leaving tunnels and bots alone"
  touch "$st/offline"; rm -f "$st"/*.fails "$st"/*.restarts; exit 0
fi
if [ -e "$st/offline" ]; then
  rm -f "$st/offline"; echo "$now" > "$st/back"
  logger -t warpns-watchdog "internet is back - waiting 5 minutes before touching any tunnel"
fi
if [ -e "$st/back" ] && [ $(( now - $(cat "$st/back") )) -lt 300 ]; then exit 0; fi
for f in /etc/warpns/*.conf; do
  [ -f "$f" ] || continue
  n=$(basename "$f" .conf)
  ip netns list | grep -qw "$n" || continue
  if alive "$n"; then rm -f "$st/$n.fails" "$st/$n.restarts"; continue; fi
  c=$(( $(cat "$st/$n.fails" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$st/$n.fails"
  [ "$c" -ge 3 ] || continue                                   # 3 failed checks in a row
  if [ -e "$st/$n.last" ] && [ $(( now - $(stat -c %Y "$st/$n.last") )) -lt 600 ]; then continue; fi  # 10 min cooldown
  touch "$st/$n.last"; echo 0 > "$st/$n.fails"
  r=$(( $(cat "$st/$n.restarts" 2>/dev/null || echo 0) + 1 )); echo "$r" > "$st/$n.restarts"
  logger -t warpns-watchdog "tunnel $n is dead (internet is up) - restarting it"
  systemctl restart "wgns@$n"; sleep 12
  if alive "$n"; then rm -f "$st/$n.restarts"; continue; fi
  if [ "$r" -ge 2 ]; then                                       # only change port after 2 failed restarts
    cur=$(grep -oE '^Endpoint = [0-9.]+:[0-9]+' "$f" | grep -oE '[0-9]+$')
    next=4500
    for i in 0 1 2 3; do [ "${ports[$i]}" = "$cur" ] && next=${ports[$(( (i+1) % 4 ))]}; done
    sed -i -E "s|^(Endpoint = [0-9.]+:)[0-9]+|\1$next|" "$f"
    logger -t warpns-watchdog "tunnel $n still dead - switching UDP port $cur -> $next"
    systemctl restart "wgns@$n"
  fi
done
exit 0
RES_WD
    fi
    sudo chmod +x /usr/local/bin/eggdrop-dbguard /usr/local/bin/eggdrop-dbbackup \
                  /usr/local/bin/eggdrop-stagger /usr/local/bin/eggdrop-doctor
    if [ -f /usr/local/bin/warpns-watchdog ] || [ -d /etc/warpns ]; then
        sudo chmod +x /usr/local/bin/warpns-watchdog
    fi
    sudo systemctl daemon-reload
    sudo systemctl enable --now eggdrop-dbbackup.timer >/dev/null 2>&1
    sudo systemctl start eggdrop-dbbackup.service >/dev/null 2>&1 || true
    ohai "Resilience toolkit ${tty_green}ready${tty_reset}.  Check everything any time with: ${tty_green}sudo eggdrop-doctor${tty_reset}"
    echo
}

# Attach the auto-repair + staggered start to one bot service  (name like eggdrop-Selene)
resilience_attach_service() {
    local s="${1%.service}"
    [ -f "/etc/systemd/system/${s}.service" ] || return 0
    sudo mkdir -p "/etc/systemd/system/${s}.service.d"
    sudo tee "/etc/systemd/system/${s}.service.d/resilience.conf" >/dev/null <<'RES_DROPIN'
[Service]
ExecStartPre=-+/usr/local/bin/eggdrop-dbguard
ExecStartPre=-+/usr/local/bin/eggdrop-stagger
TimeoutStartSec=300
TimeoutStopSec=60
RestartSec=30
RES_DROPIN
}

# ./installer.sh -r : add the toolkit to every bot that already exists on this server
resilience_retrofit_all() {
    install_resilience_toolkit || return 1
    local f n count=0
    for f in /etc/systemd/system/eggdrop-*.service; do
        [ -f "$f" ] || continue
        n="$(basename "$f" .service)"
        resilience_attach_service "$n"
        count=$((count + 1))
    done
    sudo systemctl daemon-reload
    ohai "Attached to ${tty_green}${count}${tty_reset} bot service(s). Active from each bot's next (re)start - nothing was restarted."
    echo "    Now run:  ${tty_green}sudo eggdrop-doctor${tty_reset}"
    echo
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
    echo
    echo "PinoyChat Eggdrop Installer (BlackTools or A&A)"
    echo "Usage: ./installer.sh [options]"
    echo "    -i              Install Eggdrop + your choice of BlackTools or A&A"
    echo "    -r              Retrofit resilience (backups, auto-repair) onto all existing bots"
    echo "    -h, --help      Display this message"
    echo
    exit "${1:-0}"
}

# ---------------------------------------------------------------------------
# Main installer
# ---------------------------------------------------------------------------

install_bot() {
    echo
    echo "    ${tty_green}============================================================${tty_reset}"
    echo "    ${tty_bold}  PinoyChat Eggdrop ${EGGDROP_VER} Installer${tty_reset}"
    echo "    ${tty_green}============================================================${tty_reset}"
    echo
    echo "    ${tty_bold}PinoyChat${tty_reset}  : https://pinoychat.fun/live"
    echo "    ${tty_bold}Eggdrop${tty_reset}    : https://www.eggheads.org"
    echo "    ${tty_bold}BlackTools${tty_reset} : https://github.com/tclscripts/BlackTools-TCL"
    echo "    ${tty_bold}A&A (light)${tty_reset}: http://ascript.name"
    echo
    echo "    This script will:"
    echo "      ${tty_green}1.${tty_reset} Check and install prerequisites"
    echo "      ${tty_green}2.${tty_reset} Choose your TCL script package (BlackTools or A&A)"
    echo "      ${tty_green}3.${tty_reset} Optionally give the bot its own Cloudflare WARP IPv6"
    echo "      ${tty_green}4.${tty_reset} Select IRC network"
    echo "      ${tty_green}5.${tty_reset} Auto-detect your installed Tcl"
    echo "      ${tty_green}6.${tty_reset} Download and compile Eggdrop ${EGGDROP_VER}"
    echo "      ${tty_green}7.${tty_reset} Download and install your chosen script package"
    echo "      ${tty_green}8.${tty_reset} Interactively configure the bot"
    echo "      ${tty_green}9.${tty_reset} Optionally start the bot and claim ownership"
    echo

    wait_for_user

    echo
    ohai "Detected ${tty_green}${SYSTEM}${tty_reset} system. Using ${tty_bold}${PKGMGR}${tty_reset} package manager."
    echo

    ask_for_prereq
    check_prereqs

    ask_for_package

    ask_for_install_dir
    mkdir -p "${EGGDROP_INSTALL_DIR}/logs"

    # -- optional: private Cloudflare WARP tunnel (own IPv6) for this bot
    ask_for_warp

    # -- backups, auto-repair, outage-safe watchdog
    install_resilience_toolkit

    download_eggdrop

    # ── BlackTools branch ─────────────────────────────────────────────────────
    if [ "${INSTALL_PACKAGE}" == "blacktools" ]; then

        install_blacktools
        collect_bt_settings
        ask_for_network
        collect_eggdrop_settings
        patch_blacktools
        write_eggdrop_conf
        write_helpers
        start_bot
        show_success

    # ── A&A branch ───────────────────────────────────────────────────────────
    elif [ "${INSTALL_PACKAGE}" == "aa" ]; then

        install_aa
        collect_aa_settings
        patch_aa
        write_helpers_aa
        start_bot
        show_success_aa

    fi
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if [[ $# -gt 0 ]]; then
    case "$1" in
        -h | --help) usage ;;
        -i) install_bot; exit 0 ;;
        -r) resilience_retrofit_all; exit 0 ;;
        *)
            warn "Unrecognized option: '$1'"
            usage 1
        ;;
    esac
fi

install_bot
