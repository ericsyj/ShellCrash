#!/bin/sh
# Copyright (C) Juewuy

# sing-box bridge 出站把 L3 包写入自己的 TUN（默认 bridge0），再由内核从该接口转发出去。
# 回注发生在 PREROUTING：没有以太网源 MAC，源地址仍是原始客户端，要到 POSTROUTING 才由 bridge 做源 NAT。
#
# 混合模式只把 UDP 标进 utun，TCP 在 NAT 里 redirect，局域网 TCP 不会进入 utun，因此到不了 bridge。
# 回注包仍会撞上独立的 UDP fwmark 链、TCP redirect 链和 DNS redirect 链，这些 PREROUTING 链都要按入接口放行。
# WireGuard/Tailscale 等 L3 入站即使在混合模式也可能把 TCP 送进 bridge。
# 纯 tun 模式 TCP 和 UDP 都标进 utun，同一条入接口放行同时覆盖两者。
#
# 放行必须早于黑白名单：
# 黑名单只写了 MAC 时，回注包没有以太网头，MAC 匹配失败，源 IP 又属于局域网，会被再次劫持；
# 白名单按源 IP 命中时，回注包源 IP 仍是客户端，会被当成新的放行设备再次劫持。

[ -n "$__FW_BRIDGE_LOADED" ] && return 0
__FW_BRIDGE_LOADED=1

bridge_enabled() {
    printf '%s' "$crashcore" | grep -q 'singbox' || return 1
    [ "$redir_mod" = "Mix" ] || [ "$redir_mod" = "Tun" ] || return 1
    return 0
}

bridge_valid_prefix() {
    printf '%s' "$1" | grep -Eq '^[A-Za-z][A-Za-z0-9_.:-]{0,12}$'
}

bridge_valid_ifname() {
    printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,14}$'
}

bridge_dedup() {
    printf '%s\n' "$1" | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

bridge_if_matches_prefix() {
    _ifn=$1
    _pre=$2
    [ -n "$_ifn" ] && [ -n "$_pre" ] || return 1
    case "$_ifn" in
        ${_pre}[0-9]*) ;;
        *) return 1 ;;
    esac
    _rest=${_ifn#"$_pre"}
    printf '%s' "$_rest" | grep -Eq '^[0-9]+$'
}

# 每个 bridge 出站输出一个前缀；未写 bridge_name 时用 sing-box 默认值 bridge。
# 只认和 "type": "bridge" 同一对象里的 bridge_name，避免把别的字段误当成接口前缀。
bridge_prefixes_from_text() {
    awk '
        function valid_prefix(s) {
            return s ~ /^[A-Za-z][A-Za-z0-9_.:-]{0,12}$/
        }
        function take_string(s) {
            if (!expect_value[depth]) {
                key[depth] = s
                return
            }
            if (key[depth] == "type" && s == "bridge") is_bridge[depth] = 1
            if (key[depth] == "bridge_name") bname[depth] = s
            expect_value[depth] = 0
        }
        BEGIN { depth = 0; in_str = 0; esc = 0; cur = "" }
        {
            line = $0
            n = length(line)
            for (i = 1; i <= n; i++) {
                c = substr(line, i, 1)
                if (in_str) {
                    if (esc) { esc = 0; cur = cur c; continue }
                    if (c == "\\") { esc = 1; continue }
                    if (c == "\"") { in_str = 0; if (depth > 0) take_string(cur); cur = ""; continue }
                    cur = cur c
                    continue
                }
                if (c == "\"") { in_str = 1; cur = ""; continue }
                if (c == "{") { depth++; is_bridge[depth] = 0; bname[depth] = ""; key[depth] = ""; expect_value[depth] = 0; continue }
                if (c == "}") {
                    if (depth > 0 && is_bridge[depth]) {
                        if (valid_prefix(bname[depth])) print bname[depth]
                        else print "bridge"
                    }
                    delete is_bridge[depth]
                    delete bname[depth]
                    delete key[depth]
                    delete expect_value[depth]
                    if (depth > 0) depth--
                    continue
                }
                if (c == ":" && depth > 0) expect_value[depth] = 1
                if ((c == "," || c == "]") && depth > 0) expect_value[depth] = 0
            }
        }
    '
}

bridge_ifs_from_nft_tables() {
    sed -n 's/^table[[:space:]][[:space:]]*inet[[:space:]][[:space:]]*sing-box-//p' | sed 's/[[:space:]].*$//' | while read -r _name; do
        [ "$_name" = "fullcone-probe" ] && continue
        bridge_valid_ifname "$_name" && printf '%s\n' "$_name"
    done
}

bridge_ifs_from_iptables() {
    sed -n 's/^-N sing-box-//p' | while read -r _name; do
        [ "$_name" = "fullcone-probe" ] && continue
        bridge_valid_ifname "$_name" && printf '%s\n' "$_name"
    done
}

# 只认默认路由表 2200-2453，并且接口名必须像 bridge TUN，避免误放行 br-lan / bridge0 这类局域网桥。
bridge_ifs_from_ip_rules() {
    _prefixes=$1
    awk -v prefixes="$_prefixes" '
        function name_ok(ifn,    i, n, pre, rest) {
            if (ifn ~ /^bridge[0-9]+$/) return 1
            n = split(prefixes, p, " ")
            for (i = 1; i <= n; i++) {
                pre = p[i]
                if (pre == "") continue
                if (index(ifn, pre) != 1) continue
                rest = substr(ifn, length(pre) + 1)
                if (rest ~ /^[0-9]+$/) return 1
            }
            return 0
        }
        {
            ifn = ""
            tbl = ""
            for (i = 1; i <= NF; i++) {
                if ($i == "iif") ifn = $(i + 1)
                if ($i == "lookup") tbl = $(i + 1)
            }
            if (ifn == "" || tbl !~ /^[0-9]+$/) next
            if (tbl + 0 < 2200 || tbl + 0 > 2453) next
            if (!name_ok(ifn)) next
            print ifn
        }
    '
}

bridge_next_index() {
    _pre=$1
    _sys=$2
    _max=-1
    for _ifn in $_sys; do
        bridge_if_matches_prefix "$_ifn" "$_pre" || continue
        _num=${_ifn#"$_pre"}
        [ "$_num" -gt "$_max" ] && _max=$_num
    done
    echo $((_max + 1))
}

# $1 配置里的前缀（可重复） $2 已经出现的接口 $3 系统现有接口
# 结果写到 bridge_ifs。缺的接口按 sing-tun CalculateInterfaceName 的规则预测成 prefix+序号。
bridge_plan_ifs() {
    _prefixes=$1
    _detected=$2
    _sysifs=$3
    bridge_ifs=$(bridge_dedup "$_detected")
    for _pre in $(bridge_dedup "$_prefixes"); do
        bridge_valid_prefix "$_pre" || continue
        _need=0
        for _item in $_prefixes; do
            [ "$_item" = "$_pre" ] && _need=$((_need + 1))
        done
        _have=0
        for _ifn in $bridge_ifs; do
            bridge_if_matches_prefix "$_ifn" "$_pre" && _have=$((_have + 1))
        done
        _missing=$((_need - _have))
        [ "$_missing" -le 0 ] && continue
        _idx=$(bridge_next_index "$_pre" "$_sysifs $bridge_ifs")
        while [ "$_missing" -gt 0 ]; do
            _name="${_pre}${_idx}"
            if bridge_valid_ifname "$_name"; then
                bridge_ifs=$(bridge_dedup "$bridge_ifs $_name")
            fi
            _idx=$((_idx + 1))
            _missing=$((_missing - 1))
        done
    done
    bridge_ifs=$(echo $bridge_ifs)
}

bridge_scan_prefixes() {
    # 运行中的配置在 TMPDIR/jsons。自定义文件会被链接进去，不能再扫一遍 CRASHDIR，否则同一个出站会被算两次。
    for _dir in "$TMPDIR/jsons" "$CRASHDIR/jsons"; do
        [ -d "$_dir" ] || continue
        _any=0
        for _file in "$_dir"/*.json; do
            [ -f "$_file" ] || continue
            _any=1
            bridge_prefixes_from_text <"$_file"
        done
        [ "$_any" = 1 ] && return 0
    done
    if [ -n "$core_config" ] && [ -f "$core_config" ]; then
        bridge_prefixes_from_text <"$core_config"
    fi
}

bridge_scan_live() {
    _prefixes=$1
    _found=""
    if command -v nft >/dev/null 2>&1; then
        _found="$_found $(nft list tables 2>/dev/null | bridge_ifs_from_nft_tables | tr '\n' ' ')"
    fi
    if command -v iptables >/dev/null 2>&1; then
        _found="$_found $(iptables -t mangle -S 2>/dev/null | bridge_ifs_from_iptables | tr '\n' ' ')"
        _found="$_found $(iptables -t filter -S 2>/dev/null | bridge_ifs_from_iptables | tr '\n' ' ')"
        _found="$_found $(iptables -t nat -S 2>/dev/null | bridge_ifs_from_iptables | tr '\n' ' ')"
    fi
    _found=$(echo $_found)
    # 已经从 nft/iptables 得到真实接口时，不再采信 ip rule，避免把无关的 bridge0 算进来。
    if [ -n "$_found" ]; then
        # shellcheck disable=SC2086
        printf '%s\n' $_found
        return 0
    fi
    if command -v ip >/dev/null 2>&1; then
        ip rule show 2>/dev/null | bridge_ifs_from_ip_rules "$_prefixes"
        ip -6 rule show 2>/dev/null | bridge_ifs_from_ip_rules "$_prefixes"
    fi
}

bridge_list_ifaces() {
    command -v ip >/dev/null 2>&1 || return 0
    ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | awk -F'@' '{print $1}'
}

bridge_read_saved() {
    [ -n "$TMPDIR" ] && [ -f "$TMPDIR/bridge.list" ] || return 0
    while read -r _name; do
        bridge_valid_ifname "$_name" && printf '%s\n' "$_name"
    done <"$TMPDIR/bridge.list"
}

bridge_save_list() {
    [ -n "$TMPDIR" ] || return 0
    mkdir -p "$TMPDIR" 2>/dev/null || return 0
    : >"$TMPDIR/bridge.list"
    for _ifn in $bridge_ifs; do
        bridge_valid_ifname "$_ifn" && printf '%s\n' "$_ifn" >>"$TMPDIR/bridge.list"
    done
    [ -s "$TMPDIR/bridge.list" ] || rm -f "$TMPDIR/bridge.list"
}

bridge_delete_forward_rules() {
    _ipt=iptables
    _ip6=ip6tables
    [ -n "$iptable" ] && _ipt=$iptable
    [ -n "$ip6table" ] && _ip6=$ip6table
    for _ifn in "$@"; do
        bridge_valid_ifname "$_ifn" || continue
        if command -v nft >/dev/null 2>&1 && nft list chain inet fw4 forward >/dev/null 2>&1; then
            nft -a list chain inet fw4 forward 2>/dev/null | while read -r _line; do
                printf '%s\n' "$_line" | grep -Fq "iifname \"$_ifn\"" || printf '%s\n' "$_line" | grep -Fq "oifname \"$_ifn\"" || continue
                _handle=$(printf '%s\n' "$_line" | sed -n 's/.*# handle \([0-9][0-9]*\).*/\1/p')
                [ -n "$_handle" ] && nft delete rule inet fw4 forward handle "$_handle" 2>/dev/null
            done
        fi
        if command -v iptables >/dev/null 2>&1; then
            _n=0
            # shellcheck disable=SC2086
            while [ "$_n" -lt 5 ] && $_ipt -D FORWARD -i "$_ifn" -j ACCEPT 2>/dev/null; do _n=$((_n + 1)); done
            _n=0
            # shellcheck disable=SC2086
            while [ "$_n" -lt 5 ] && $_ipt -D FORWARD -o "$_ifn" -j ACCEPT 2>/dev/null; do _n=$((_n + 1)); done
        fi
        if command -v ip6tables >/dev/null 2>&1; then
            _n=0
            # shellcheck disable=SC2086
            while [ "$_n" -lt 5 ] && $_ip6 -D FORWARD -i "$_ifn" -j ACCEPT 2>/dev/null; do _n=$((_n + 1)); done
            _n=0
            # shellcheck disable=SC2086
            while [ "$_n" -lt 5 ] && $_ip6 -D FORWARD -o "$_ifn" -j ACCEPT 2>/dev/null; do _n=$((_n + 1)); done
        fi
    done
}

bridge_clear_forward() {
    _saved=$(bridge_read_saved | tr '\n' ' ')
    # shellcheck disable=SC2086
    [ -n "$_saved" ] && bridge_delete_forward_rules $_saved
    [ -n "$TMPDIR" ] && rm -f "$TMPDIR/bridge.list"
}

collect_bridge_ifs() {
    bridge_clear_forward
    bridge_ifs=
    bridge_enabled || return 0
    _prefixes=$(bridge_scan_prefixes | tr '\n' ' ')
    _detected=$(bridge_scan_live "$_prefixes" | tr '\n' ' ')
    _sysifs=$(bridge_list_ifaces | tr '\n' ' ')
    bridge_plan_ifs "$_prefixes" "$_detected" "$_sysifs"
    bridge_save_list
}

bridge_filter_routes() {
    if [ -z "$bridge_ifs" ]; then
        cat
        return 0
    fi
    awk -v ifs="$bridge_ifs" '
        BEGIN { n = split(ifs, a, " ") }
        {
            dev = ""
            for (i = 1; i <= NF; i++) if ($i == "dev" && i < NF) dev = $(i + 1)
            skip = 0
            for (i = 1; i <= n; i++) if (a[i] != "" && dev == a[i]) skip = 1
            if ($1 ~ /^192\.0\.2\./ || $1 ~ /^2001:db8:/) skip = 1
            if (!skip) print
        }
    '
}

bridge_nft_return() {
    _chain=$1
    [ -n "$_chain" ] || return 0
    for _ifn in $bridge_ifs; do
        bridge_valid_ifname "$_ifn" || continue
        nft add rule inet shellcrash "$_chain" iifname "\"$_ifn\"" return
    done
}

bridge_ipt_return() {
    _bin=$1
    _w=$2
    _table=$3
    _chain=$4
    [ -n "$_bin" ] && [ -n "$_chain" ] || return 0
    for _ifn in $bridge_ifs; do
        bridge_valid_ifname "$_ifn" || continue
        # shellcheck disable=SC2086
        "$_bin" $_w -t "$_table" -A "$_chain" -i "$_ifn" -j RETURN
    done
}

bridge_nft_forward() {
    [ -n "$bridge_ifs" ] || return 0
    nft list chain inet fw4 forward >/dev/null 2>&1 || return 0
    for _ifn in $bridge_ifs; do
        bridge_valid_ifname "$_ifn" || continue
        nft list chain inet fw4 forward 2>/dev/null | grep -Fq "iifname \"$_ifn\"" || nft insert rule inet fw4 forward iifname "\"$_ifn\"" accept
        nft list chain inet fw4 forward 2>/dev/null | grep -Fq "oifname \"$_ifn\"" || nft insert rule inet fw4 forward oifname "\"$_ifn\"" accept
    done
}

bridge_ipt_forward() {
    [ -n "$bridge_ifs" ] || return 0
    for _ifn in $bridge_ifs; do
        bridge_valid_ifname "$_ifn" || continue
        if [ -n "$iptable" ]; then
            $iptable -S FORWARD 2>/dev/null | grep -Fq -- "-i $_ifn -j ACCEPT" || $iptable -I FORWARD -i "$_ifn" -j ACCEPT
            $iptable -S FORWARD 2>/dev/null | grep -Fq -- "-o $_ifn -j ACCEPT" || $iptable -I FORWARD -o "$_ifn" -j ACCEPT
        fi
        if [ -n "$ip6table" ]; then
            $ip6table -S FORWARD 2>/dev/null | grep -Fq -- "-i $_ifn -j ACCEPT" || $ip6table -I FORWARD -i "$_ifn" -j ACCEPT
            $ip6table -S FORWARD 2>/dev/null | grep -Fq -- "-o $_ifn -j ACCEPT" || $ip6table -I FORWARD -o "$_ifn" -j ACCEPT
        fi
    done
}
