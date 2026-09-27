#!/bin/sh
# 覆盖 bridge 接口识别：配置解析、回环排除名单、以及不能误伤 br-lan。
cd "$(dirname "$0")/.." || exit 1
. ./scripts/starts/fw_bridge.sh

fail=0
check() {
    name=$1
    got=$2
    want=$3
    if [ "$got" = "$want" ]; then
        printf 'ok  %s\n' "$name"
    else
        printf 'FAIL %s\n  got:  [%s]\n  want: [%s]\n' "$name" "$got" "$want"
        fail=1
    fi
}

sort_words() {
    # shellcheck disable=SC2086
    printf '%s\n' $1 | awk 'NF && !seen[$0]++' | sort | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

prefixes=$(printf '%s\n' '{
  "outbounds": [
    {"type": "direct", "tag": "DIRECT", "bridge_name": "decoy"},
    {"type": "bridge", "tag": "plain"},
    {"type": "bridge", "tag": "named", "bridge_name": "sbx"},
    {"type": "selector", "tag": "x", "outbounds": ["bridge"]}
  ]
}' | bridge_prefixes_from_text | tr '\n' ' ' | sed 's/[[:space:]]*$//')
check "json prefixes ignore decoy and nested strings" "$prefixes" "bridge sbx"

prefixes=$(printf '%s\n' '{"outbounds":[{"bridge_name":"sbx","type":"bridge"},{"type":"bridge"}]}' | bridge_prefixes_from_text | tr '\n' ' ' | sed 's/[[:space:]]*$//')
check "compact json keeps object-local bridge_name" "$prefixes" "sbx bridge"

detected=$(printf '%s\n' 'table inet shellcrash
table inet sing-box-bridge0
table inet sing-box-fullcone-probe
table ip filter' | bridge_ifs_from_nft_tables | tr '\n' ' ' | sed 's/[[:space:]]*$//')
check "nft table name" "$detected" "bridge0"

detected=$(printf '%s\n' '-N sing-box-sbx0
-A sing-box-sbx0 -i sbx0 -j MARK --set-xmark 0x40000000/0x40000000
-N sing-box-fullcone-probe' | bridge_ifs_from_iptables | tr '\n' ' ' | sed 's/[[:space:]]*$//')
check "iptables chain name" "$detected" "sbx0"

rules='0:	from all lookup local
100:	from all iif bridge0 lookup main
101:	from all iif bridge0 lookup 2200
102:	from all to 192.0.2.1 lookup main
100:	from all iif br-lan lookup 2200
100:	from all iif bridge0 lookup 100
100:	from all iif sbx0 lookup 2200
100:	from all iif eth0 lookup 2200'
detected=$(printf '%s\n' "$rules" | bridge_ifs_from_ip_rules "sbx" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
check "ip rule only bridge tun tables" "$(sort_words "$detected")" "bridge0 sbx0"

bridge_plan_ifs "bridge" "" "lo br-lan bridge0"
check "physical bridge0 makes sing-box use bridge1" "$bridge_ifs" "bridge1"

bridge_plan_ifs "bridge bridge" "bridge0" "lo br-lan bridge0"
check "second bridge predicts the next index" "$bridge_ifs" "bridge0 bridge1"

bridge_plan_ifs "br" "" "lo br-lan"
check "prefix br does not swallow br-lan" "$bridge_ifs" "br0"

bridge_plan_ifs "sbx" "sbx0" "lo br-lan sbx0"
check "live interface satisfies the configured prefix" "$bridge_ifs" "sbx0"

bridge_plan_ifs "" "bridge0" "bridge0"
check "nft detection works without config" "$bridge_ifs" "bridge0"

bridge_ifs="bridge0"
routes=$(printf '%s\n' '192.168.1.0/24 dev br-lan scope link src 192.168.1.1
192.0.2.1 dev bridge0 scope link
2001:db8::1 dev bridge0 metric 256
10.0.0.0/8 dev br-lan scope link' | bridge_filter_routes)
want=$(printf '%s\n' '192.168.1.0/24 dev br-lan scope link src 192.168.1.1
10.0.0.0/8 dev br-lan scope link')
check "lan discovery skips bridge port routes" "$routes" "$want"

bridge_ifs=
routes=$(printf '%s\n' '192.0.2.1 dev bridge0 scope link' | bridge_filter_routes)
check "no bridge means routes stay untouched" "$routes" "192.0.2.1 dev bridge0 scope link"

if ! bridge_if_matches_prefix "br-lan" "br"; then
    printf 'ok  br-lan is not a br TUN\n'
else
    printf 'FAIL br-lan matched prefix br\n'
    fail=1
fi
if bridge_if_matches_prefix "bridge10" "bridge"; then
    printf 'ok  bridge10 matches prefix bridge\n'
else
    printf 'FAIL bridge10 did not match prefix bridge\n'
    fail=1
fi

tmp=$(mktemp -d)
mkdir -p "$tmp/run" "$tmp/src"
printf '%s\n' '{"outbounds":[{"type":"bridge","bridge_name":"sbx"}]}' >"$tmp/run/outbounds.json"
printf '%s\n' '{"outbounds":[{"type":"bridge","bridge_name":"sbx"}]}' >"$tmp/src/outbounds.json"
TMPDIR=$tmp CRASHDIR=$tmp/src
# bridge_scan_prefixes reads $TMPDIR/jsons then $CRASHDIR/jsons
mkdir -p "$tmp/jsons"
cp "$tmp/run/outbounds.json" "$tmp/jsons/outbounds.json"
mkdir -p "$tmp/src/jsons"
cp "$tmp/src/outbounds.json" "$tmp/src/jsons/outbounds.json"
prefixes=$(bridge_scan_prefixes | tr '\n' ' ' | sed 's/[[:space:]]*$//')
check "runtime jsons are not counted twice" "$prefixes" "sbx"
rm -rf "$tmp"

exit $fail
