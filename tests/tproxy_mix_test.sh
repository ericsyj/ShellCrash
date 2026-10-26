#!/bin/sh
# TproxyMix：TCP redirect，UDP tproxy，且两条链都保留 CN 绕过和设备黑白名单。
# 用 dash 运行：sh tests/tproxy_mix_test.sh

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
fail() {
    echo "FAIL: $*" >&2
    exit 1
}
assert_contains() {
    grep -F -- "$1" "$2" >/dev/null || fail "missing [$1]"
}
assert_not_contains() {
    if grep -F -- "$1" "$2" >/dev/null; then
        fail "unexpected [$1]"
    fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
BIN=$TMP/bin
mkdir -p "$BIN" "$TMP/crash/configs" "$TMP/bindir"
export PATH="$BIN:$PATH"

cat >"$BIN/nft" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$NFT_LOG"
exit 0
EOF
cat >"$BIN/iptables" <<'EOF'
#!/bin/sh
help=0
for a in "$@"; do
    [ "$a" = "-h" ] && help=1
done
if [ "$help" = 1 ]; then
    if [ "${IPT_HAVE_TPROXY:-1}" = 0 ]; then
        echo "--to-ports --set-mark"
    else
        echo "--on-port --to-ports --set-mark"
    fi
    exit 0
fi
printf '%s %s\n' "$(basename "$0")" "$*" >> "$IPT_LOG"
exit 0
EOF
cp "$BIN/iptables" "$BIN/ip6tables"
chmod 755 "$BIN/nft" "$BIN/iptables" "$BIN/ip6tables"

modprobe() {
    [ "${MODPROBE_FAIL:-0}" = 1 ] && return 1
    return 0
}
lsmod() {
    return 0
}
logger() {
    printf '%s\n' "$*" >> "$LOG"
}
ckcmd() {
    command -v "$1" >/dev/null 2>&1
}

echo '1.2.3.0/24' >"$TMP/bindir/cn_ip.txt"
echo '2001:db8::/32' >"$TMP/bindir/cn_ipv6.txt"
printf '%s\n' 'aa:bb:cc:dd:ee:ff' >"$TMP/crash/configs/mac"
printf '%s\n' '10.9.8.7' >"$TMP/crash/configs/ip_filter"

export CRASHDIR=$TMP/crash
export BINDIR=$TMP/bindir
fwmark=7892
redir_port=7892
tproxy_port=7893
mix_port=7890
dns_port=1053
dns_redir_port=1053
routing_mark=7894
table=100
reserve_ipv4='0.0.0.0/8'
reserve_ipv6='fe80::/10'
host_ipv4='192.168.1.0/24'
host_ipv6='fd00::/64'
local_ipv4='10.0.0.8'
dns_mod=redir_host
cn_ip_route=ON
common_ports=OFF
firewall_area=4
fw_wan=OFF
systype=container
vm_redir=OFF
quic_rj=ON
ipv6_redir=ON
lan_proxy=true
local_proxy=false
tun_statu=false
unset ports

run_nft() {
    NFT_LOG=$1
    LOG=$1
    export NFT_LOG LOG
    : >"$NFT_LOG"
    (
        # shellcheck disable=SC1091
        . "$ROOT/scripts/starts/fw_nftables.sh"
        start_nftables
    )
}

run_ipt() {
    IPT_LOG=$1
    LOG=$1
    export IPT_LOG LOG
    : >"$IPT_LOG"
    (
        # shellcheck disable=SC1091
        . "$ROOT/scripts/starts/fw_iptables.sh"
        start_iptables
    )
}

# --- nft TproxyMix：黑名单 ---
redir_mod=TproxyMix
macfilter_type=黑名单
MODPROBE_FAIL=0
run_nft "$TMP/nft-mix-black.log"
assert_contains 'meta l4proto udp mark set 7892 tproxy to :7893' "$TMP/nft-mix-black.log"
assert_contains 'meta l4proto tcp mark set 7893' "$TMP/nft-mix-black.log"
assert_contains 'mark 7893 meta l4proto tcp redirect to 7892' "$TMP/nft-mix-black.log"
assert_contains 'ip daddr @cn_ip return' "$TMP/nft-mix-black.log"
assert_contains 'ip6 daddr @cn_ip6 return' "$TMP/nft-mix-black.log"
assert_contains 'ether saddr {aa:bb:cc:dd:ee:ff, } return' "$TMP/nft-mix-black.log"
assert_contains 'ip saddr {10.9.8.7, } return' "$TMP/nft-mix-black.log"
assert_not_contains 'meta l4proto {tcp, udp} mark set 7892 tproxy' "$TMP/nft-mix-black.log"
assert_not_contains 'oifname "utun"' "$TMP/nft-mix-black.log"
cn_line=$(grep -n 'ip daddr @cn_ip return' "$TMP/nft-mix-black.log" | head -n 1 | cut -d: -f1)
tp_line=$(grep -n 'meta l4proto udp mark set 7892 tproxy to :7893' "$TMP/nft-mix-black.log" | head -n 1 | cut -d: -f1)
mac_line=$(grep -n 'ether saddr {aa:bb:cc:dd:ee:ff, } return' "$TMP/nft-mix-black.log" | head -n 1 | cut -d: -f1)
[ "$cn_line" -lt "$tp_line" ] || fail "nft CN return is after udp tproxy"
[ "$mac_line" -lt "$tp_line" ] || fail "nft mac blacklist is after udp tproxy"
mark_line=$(grep -n 'meta l4proto tcp mark set 7893' "$TMP/nft-mix-black.log" | head -n 1 | cut -d: -f1)
[ "$cn_line" -lt "$mark_line" ] || fail "nft CN return is after tcp mark"
[ "$mac_line" -lt "$mark_line" ] || fail "nft mac blacklist is after tcp mark"

# --- nft 本机：UDP 只给 mark_out 做 tproxy，TCP 仍走 output redirect ---
local_proxy=true
run_nft "$TMP/nft-mix-local.log"
assert_contains 'add rule inet shellcrash mark_out meta mark 7892 meta l4proto udp tproxy to :7893' "$TMP/nft-mix-local.log"
assert_contains 'add rule inet shellcrash output_mixtcp mark 7893 meta l4proto tcp redirect to 7892' "$TMP/nft-mix-local.log"
assert_not_contains 'meta l4proto {tcp, udp} tproxy to :7893' "$TMP/nft-mix-local.log"
local_proxy=false

# --- nft TproxyMix：白名单 ---
macfilter_type=白名单
run_nft "$TMP/nft-mix-white.log"
assert_contains 'ether saddr != {aa:bb:cc:dd:ee:ff, } ip saddr != {10.9.8.7, } return' "$TMP/nft-mix-white.log"
assert_not_contains 'ether saddr {aa:bb:cc:dd:ee:ff, } return' "$TMP/nft-mix-white.log"
white_line=$(grep -n 'ether saddr != {aa:bb:cc:dd:ee:ff, }' "$TMP/nft-mix-white.log" | head -n 1 | cut -d: -f1)
tp_line=$(grep -n 'meta l4proto udp mark set 7892 tproxy to :7893' "$TMP/nft-mix-white.log" | head -n 1 | cut -d: -f1)
[ "$white_line" -lt "$tp_line" ] || fail "nft whitelist return is after udp tproxy"

# --- nft 缺少 nft_tproxy 时仍保留 TCP redirect ---
MODPROBE_FAIL=1
macfilter_type=黑名单
run_nft "$TMP/nft-mix-notp.log"
assert_contains '仅启动 TCP Redirect' "$TMP/nft-mix-notp.log"
assert_contains 'mark 7893 meta l4proto tcp redirect to 7892' "$TMP/nft-mix-notp.log"
assert_not_contains 'tproxy to :7893' "$TMP/nft-mix-notp.log"
MODPROBE_FAIL=0

# --- nft 纯 Tproxy / Mix 不被 TproxyMix 规则污染 ---
redir_mod=Tproxy
run_nft "$TMP/nft-tproxy.log"
assert_contains 'meta l4proto {tcp, udp} mark set 7892 tproxy to :7893' "$TMP/nft-tproxy.log"
assert_not_contains 'redirect to 7892' "$TMP/nft-tproxy.log"

redir_mod=Mix
tun_statu=true
run_nft "$TMP/nft-tunmix.log"
assert_contains 'meta l4proto udp mark set 7892' "$TMP/nft-tunmix.log"
assert_contains 'mark 7893 meta l4proto tcp redirect to 7892' "$TMP/nft-tunmix.log"
assert_not_contains 'tproxy to :7893' "$TMP/nft-tunmix.log"
tun_statu=false

# --- iptables TproxyMix：黑名单，TCP redirect + UDP tproxy ---
redir_mod=TproxyMix
macfilter_type=黑名单
IPT_HAVE_TPROXY=1
export IPT_HAVE_TPROXY
run_ipt "$TMP/ipt-mix-black.log"
assert_contains 'iptables -t nat -A shellcrash -m set --match-set cn_ip dst -j RETURN' "$TMP/ipt-mix-black.log"
assert_contains 'iptables -t nat -A shellcrash -m mac --mac-source aa:bb:cc:dd:ee:ff -j RETURN' "$TMP/ipt-mix-black.log"
assert_contains 'iptables -t nat -A shellcrash -s 10.9.8.7 -j RETURN' "$TMP/ipt-mix-black.log"
assert_contains 'iptables -t nat -A shellcrash -p tcp -s 192.168.1.0/24 -j REDIRECT --to-ports 7892' "$TMP/ipt-mix-black.log"
assert_contains 'iptables -t mangle -A shellcrash_mark -m set --match-set cn_ip dst -j RETURN' "$TMP/ipt-mix-black.log"
assert_contains 'iptables -t mangle -A shellcrash_mark -m mac --mac-source aa:bb:cc:dd:ee:ff -j RETURN' "$TMP/ipt-mix-black.log"
assert_contains 'iptables -t mangle -A shellcrash_mark -s 10.9.8.7 -j RETURN' "$TMP/ipt-mix-black.log"
assert_contains 'iptables -t mangle -A shellcrash_mark -p udp -s 192.168.1.0/24 -j TPROXY --on-port 7893 --tproxy-mark 7892' "$TMP/ipt-mix-black.log"
assert_contains 'ip6tables -t nat -A shellcrashv6 -m set --match-set cn_ip6 dst -j RETURN' "$TMP/ipt-mix-black.log"
assert_contains 'ip6tables -t mangle -A shellcrashv6_mark -m set --match-set cn_ip6 dst -j RETURN' "$TMP/ipt-mix-black.log"
assert_contains 'iptables -I INPUT -p udp --dport 443 -m set ! --match-set cn_ip dst -j REJECT' "$TMP/ipt-mix-black.log"
assert_not_contains 'iptables -t mangle -A shellcrash_mark -p tcp -s 192.168.1.0/24 -j TPROXY' "$TMP/ipt-mix-black.log"
assert_not_contains 'iptables -I FORWARD -o utun -j ACCEPT' "$TMP/ipt-mix-black.log"
nat_cn=$(grep -n 'iptables -t nat -A shellcrash -m set --match-set cn_ip dst -j RETURN' "$TMP/ipt-mix-black.log" | head -n 1 | cut -d: -f1)
nat_jump=$(grep -n 'iptables -t nat -A shellcrash -p tcp -s 192.168.1.0/24 -j REDIRECT --to-ports 7892' "$TMP/ipt-mix-black.log" | head -n 1 | cut -d: -f1)
man_cn=$(grep -n 'iptables -t mangle -A shellcrash_mark -m set --match-set cn_ip dst -j RETURN' "$TMP/ipt-mix-black.log" | head -n 1 | cut -d: -f1)
man_jump=$(grep -n 'iptables -t mangle -A shellcrash_mark -p udp -s 192.168.1.0/24 -j TPROXY' "$TMP/ipt-mix-black.log" | head -n 1 | cut -d: -f1)
[ "$nat_cn" -lt "$nat_jump" ] || fail "iptables CN return is after tcp redirect"
[ "$man_cn" -lt "$man_jump" ] || fail "iptables CN return is after udp tproxy"

# --- iptables 白名单只放行名单内设备 ---
macfilter_type=白名单
run_ipt "$TMP/ipt-mix-white.log"
assert_contains 'iptables -t nat -A shellcrash -p tcp -m mac --mac-source aa:bb:cc:dd:ee:ff -j REDIRECT --to-ports 7892' "$TMP/ipt-mix-white.log"
assert_contains 'iptables -t nat -A shellcrash -p tcp -s 10.9.8.7 -j REDIRECT --to-ports 7892' "$TMP/ipt-mix-white.log"
assert_contains 'iptables -t mangle -A shellcrash_mark -p udp -m mac --mac-source aa:bb:cc:dd:ee:ff -j TPROXY --on-port 7893 --tproxy-mark 7892' "$TMP/ipt-mix-white.log"
assert_contains 'iptables -t mangle -A shellcrash_mark -p udp -s 10.9.8.7 -j TPROXY --on-port 7893 --tproxy-mark 7892' "$TMP/ipt-mix-white.log"
assert_not_contains 'iptables -t nat -A shellcrash -m mac --mac-source aa:bb:cc:dd:ee:ff -j RETURN' "$TMP/ipt-mix-white.log"
assert_not_contains 'iptables -t nat -A shellcrash -p tcp -s 192.168.1.0/24 -j REDIRECT --to-ports 7892' "$TMP/ipt-mix-white.log"

# --- 没有 tproxy 模块时 TCP redirect 仍在 ---
IPT_HAVE_TPROXY=0
macfilter_type=黑名单
run_ipt "$TMP/ipt-mix-notp.log"
assert_contains 'iptables -t nat -A shellcrash -p tcp -s 192.168.1.0/24 -j REDIRECT --to-ports 7892' "$TMP/ipt-mix-notp.log"
assert_contains '已放弃启动 UDP Tproxy' "$TMP/ipt-mix-notp.log"
assert_not_contains 'TPROXY --on-port 7893' "$TMP/ipt-mix-notp.log"
IPT_HAVE_TPROXY=1

# --- 旧模式名在读配置时归一成 TproxyMix ---
mkdir -p "$TMP/crash/configs"
: >"$TMP/crash/configs/command.env"
printf '%s\n' 'redir_mod=Tproxy混合' >"$TMP/crash/configs/ShellCrash.cfg"
(
    unset redir_mod
    # shellcheck disable=SC1091
    . "$ROOT/scripts/libs/get_config.sh"
    [ "$redir_mod" = "TproxyMix" ] || exit 1
) || fail "legacy redir_mod=Tproxy混合 was not mapped to TproxyMix"

echo "tproxy mix tests passed"
