#!/usr/bin/env bash
# ============================================================
#  netns 网络实验 —— VLAN 隔离 / VLAN 间路由 / 静态路由
#
#  用 Linux network namespace 在一台 Ubuntu 上模拟出：
#    * 1 台二层交换机   (bridge + 802.1Q VLAN filtering)
#    * 4 台终端         (2 台在 VLAN10，2 台在 VLAN20)
#    * 2 台路由器       (r1 做 VLAN 间路由，r1-r2 之间跑静态路由)
#
#  拓扑：
#
#        VLAN10              VLAN20
#       h1   h2             h3   h4              h5
#        |    |              |    |               |
#        +----+----[ br-lab 交换机 ]----+          |
#                        |  trunk(10,20)          |
#                       r1 ====================== r2
#                    10.0.10.1                172.16.1.1
#                    10.0.20.1      10.0.99.0/30
#
#  地址规划：
#    VLAN10   10.0.10.0/24    h1=.11  h2=.12   网关 10.0.10.1 (r1 eth0.10)
#    VLAN20   10.0.20.0/24    h3=.11  h4=.12   网关 10.0.20.1 (r1 eth0.20)
#    骨干     10.0.99.0/30    r1=.1   r2=.2
#    远端     172.16.1.0/24   r2=.1   h5=.100
#
#  用法：
#    sudo bash netns-lab.sh          # 跑完整实验
#    sudo bash netns-lab.sh clean    # 只清理环境
# ============================================================

set -u

BR="br-lab"
ACCESS_NS="h1 h2 h3 h4"
ROUTER_NS="r1 r2"
ALL_NS="$ACCESS_NS $ROUTER_NS h5"

PASS=0
FAIL=0

B=$'\033[1;34m'; G=$'\033[1;32m'; R=$'\033[1;31m'; Y=$'\033[1;33m'; N=$'\033[0m'

step() { echo; echo -e "${B}============================================================${N}"; echo -e "${B}  $*${N}"; echo -e "${B}============================================================${N}"; }
info() { echo -e "    $*"; }
pass() { echo -e "  ${G}[OK]${N}    $*"; PASS=$((PASS+1)); }
bad()  { echo -e "  ${R}[FAIL]${N}  $*"; FAIL=$((FAIL+1)); }
warn() { echo -e "  ${Y}[WARN]${N}  $*"; }

# ------------------------------------------------------------
#  前置检查
# ------------------------------------------------------------
if [ "${1:-}" = "clean" ]; then
    if [ "$(id -u)" -ne 0 ]; then echo -e "${R}请用 sudo：sudo bash $0 clean${N}"; exit 1; fi
    for n in $ALL_NS; do ip netns del "$n" 2>/dev/null; done
    ip link del "$BR" 2>/dev/null
    for i in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^(v|b|p)-'); do
        ip link del "$i" 2>/dev/null
    done
    echo "已清理。"
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${R}本脚本需要 root，请用：sudo bash $0${N}"
    exit 1
fi

for c in ip bridge ping awk sed grep; do
    if ! command -v "$c" >/dev/null 2>&1; then
        echo -e "${R}缺少命令：$c"
        echo -e "先装依赖：sudo apt update && sudo apt install -y iproute2 iputils-ping${N}"
        exit 1
    fi
done

modprobe 8021q 2>/dev/null || true

echo
info "系统：$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}" )"
info "内核：$(uname -r)"
info "用户：$(whoami)"

# ------------------------------------------------------------
#  小工具
# ------------------------------------------------------------
setip() { ip netns exec "$1" ip addr add "$3" dev "$2"; }
fwd_on() { ip netns exec "$1" sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1; }

# 建一台"终端"：eth0 接交换机，access 口，指定 VLAN
mk_access() {
    local ns=$1 vid=$2
    ip netns add "$ns"
    ip link add "v-$ns" type veth peer name "b-$ns"
    ip link set "v-$ns" netns "$ns"
    ip netns exec "$ns" ip link set "v-$ns" name eth0
    ip link set "b-$ns" master "$BR"
    ip link set "b-$ns" up
    bridge vlan add dev "b-$ns" vid "$vid" pvid untagged
    bridge vlan del dev "b-$ns" vid 1 2>/dev/null
    ip netns exec "$ns" ip link set eth0 up
    ip netns exec "$ns" ip link set lo up
}

# 建一台"路由器/三层设备"：eth0 接交换机，trunk 口，放通指定 VLAN
mk_trunk() {
    local ns=$1; shift
    ip netns add "$ns"
    ip link add "v-$ns" type veth peer name "b-$ns"
    ip link set "v-$ns" netns "$ns"
    ip netns exec "$ns" ip link set "v-$ns" name eth0
    ip link set "b-$ns" master "$BR"
    ip link set "b-$ns" up
    for vid in "$@"; do
        bridge vlan add dev "b-$ns" vid "$vid"
    done
    bridge vlan del dev "b-$ns" vid 1 2>/dev/null
    ip netns exec "$ns" ip link set eth0 up
    ip netns exec "$ns" ip link set lo up
}

# 建一台"孤立设备"（不接交换机）
mk_plain() {
    ip netns add "$1"
    ip netns exec "$1" ip link set lo up
}

# 在两台 netns 之间拉一根直连网线
patch() {
    local A=$1 IA=$2 B=$3 IB=$4
    ip link add "p-$A$IA" type veth peer name "p-$B$IB"
    ip link set "p-$A$IA" netns "$A"
    ip netns exec "$A" ip link set "p-$A$IA" name "$IA"
    ip link set "p-$B$IB" netns "$B"
    ip netns exec "$B" ip link set "p-$B$IB" name "$IB"
    ip netns exec "$A" ip link set "$IA" up
    ip netns exec "$B" ip link set "$IB" up
}

# 连通性检查：check <ns> <目标IP> <描述> <ok|fail>
check() {
    local ns=$1 dst=$2 desc=$3 expect=$4
    if ip netns exec "$ns" ping -c 2 -W 2 "$dst" >/dev/null 2>&1; then
        if [ "$expect" = "ok" ]; then pass "$desc"; else bad "$desc  —— 预期不通，实际通了"; fi
    else
        if [ "$expect" = "fail" ]; then pass "$desc"; else bad "$desc  —— 预期通，实际不通"; fi
    fi
}

clean_env() {
    for n in $ALL_NS; do ip netns del "$n" 2>/dev/null; done
    ip link del "$BR" 2>/dev/null
    for i in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^(v|b|p)-'); do
        ip link del "$i" 2>/dev/null
    done
}

# ============================================================
#  Phase 0 / 搭建拓扑
# ============================================================
step "Phase 0 / 搭建拓扑"
clean_env
info "旧环境已清理"

# 交换机：开 802.1Q VLAN 过滤
if ! ip link add "$BR" type bridge 2>/dev/null; then
    echo -e "${R}无法创建网桥，内核可能缺 bridge 模块${N}"; exit 1
fi
if ! ip link set "$BR" type bridge vlan_filtering 1 2>/dev/null; then
    warn "这台内核不支持 bridge vlan_filtering —— VLAN 隔离无法演示"
    warn "换一台标准 Ubuntu（20.04 及以上）再跑"
    ip link del "$BR" 2>/dev/null
    exit 1
fi
ip link set "$BR" up
info "交换机 $BR 已就绪（802.1Q VLAN 过滤已开启）"

mk_access h1 10
mk_access h2 10
mk_access h3 20
mk_access h4 20
info "终端接入：h1 h2 -> VLAN10      h3 h4 -> VLAN20"

mk_trunk r1 10 20
info "三层设备 r1 经 trunk 口上联（放通 VLAN10 / VLAN20）"

mk_plain r2
mk_plain h5
patch r1 eth1 r2 eth0
patch r2 eth1 h5 eth0
info "r1 ==r2== h5 已串成一条链路"

setip h1 eth0 10.0.10.11/24
setip h2 eth0 10.0.10.12/24
setip h3 eth0 10.0.20.11/24
setip h4 eth0 10.0.20.12/24
setip r1 eth1 10.0.99.1/30
setip r2 eth0 10.0.99.2/30
setip r2 eth1 172.16.1.1/24
setip h5 eth0 172.16.1.100/24
info "地址已下发"
echo
info "注意：此刻 r1 上还没有任何三层配置，也没有 VLAN 子接口"
echo
echo "  交换机各端口的 VLAN 归属："
bridge vlan show 2>/dev/null | sed 's/^/      /'

# ------------------------------------------------------------
#  Phase 1：二层交换 —— 同 VLAN 通，跨 VLAN 隔离
# ------------------------------------------------------------
step "Phase 1 / VLAN 隔离验证（二层交换机行为）"
echo "  要验证的纯粹是二层隔离，所以先在 h1 / h3 上各加一条直连路由，"
echo "  让它们跳过网关、直接在本链路上发 ARP。此时链路上没有任何三层转发。"
echo
ip netns exec h1 ip route add 10.0.20.0/24 dev eth0
ip netns exec h3 ip route add 10.0.10.0/24 dev eth0
info "h1 / h3 临时直连路由已加（不经网关，纯二层 ARP）"
echo
check h1 10.0.10.12 "h1 -> h2   同 VLAN10 内互通"                   ok
check h3 10.0.20.12 "h3 -> h4   同 VLAN20 内互通"                   ok
check h1 10.0.20.11 "h1 -> h3   跨 VLAN 被交换机拦住（预期不通）"    fail

# ------------------------------------------------------------
#  Phase 2：VLAN 间路由 —— r1 起 VLAN 子接口当网关
# ------------------------------------------------------------
step "Phase 2 / VLAN 间路由（单臂路由）"
echo "  在 r1 的 trunk 接口上建 VLAN 子接口当网关，终端配上默认网关，"
echo "  跨 VLAN 的流量就能被 r1 转发了。"
echo

ip netns exec h1 ip route del 10.0.20.0/24 dev eth0 2>/dev/null
ip netns exec h3 ip route del 10.0.10.0/24 dev eth0 2>/dev/null
info "临时直连路由已撤掉"

fwd_on r1
ip netns exec r1 ip link add link eth0 name eth0.10 type vlan id 10 2>/dev/null
ip netns exec r1 ip link add link eth0 name eth0.20 type vlan id 20 2>/dev/null

if ! ip netns exec r1 ip link show eth0.10 >/dev/null 2>&1; then
    warn "VLAN 子接口没建起来 —— 内核可能缺 8021q 模块"
    warn "手动试一下：sudo modprobe 8021q   然后重跑"
    exit 1
fi

setip r1 eth0.10 10.0.10.1/24
setip r1 eth0.20 10.0.20.1/24
ip netns exec r1 ip link set eth0.10 up
ip netns exec r1 ip link set eth0.20 up
info "r1 已建 eth0.10 = 10.0.10.1/24 ，eth0.20 = 10.0.20.1/24"

for n in h1 h2; do ip netns exec "$n" ip route add default via 10.0.10.1; done
for n in h3 h4; do ip netns exec "$n" ip route add default via 10.0.20.1; done
info "四台终端默认网关已指向 r1"
echo

check h1 10.0.10.1  "h1 -> r1 网关地址可达"                      ok
check h1 10.0.20.11 "h1 -> h3   跨 VLAN 现在通了"                ok
check h2 10.0.20.12 "h2 -> h4   VLAN10 到 VLAN20 通了"           ok

# ------------------------------------------------------------
#  Phase 3：静态路由 —— 让 h1 能摸到远端 172.16.1.0/24
# ------------------------------------------------------------
step "Phase 3 / 静态路由（跨网段互通）"
echo "  172.16.1.0/24 挂在 r2 后面，r1 的路由表里没有它。"
echo "  在 r1 上写一条静态路由指过去，回程也在 r2 上写好，"
echo "  两个网段就打通了。"
echo

fwd_on r1
fwd_on r2

ip netns exec r1 ip route add 172.16.1.0/24 via 10.0.99.2
ip netns exec r2 ip route add 10.0.10.0/24 via 10.0.99.1
ip netns exec r2 ip route add 10.0.20.0/24 via 10.0.99.1
ip netns exec h5 ip route add default via 172.16.1.1
info "r1：172.16.1.0/24 -> 10.0.99.2"
info "r2：10.0.10.0/24 -> 10.0.99.1 ，10.0.20.0/24 -> 10.0.99.1"
echo

check h1 172.16.1.100 "h1 -> h5   VLAN10 跨两跳到达远端网段"      ok
check h3 172.16.1.100 "h3 -> h5   VLAN20 也能到远端"             ok
check h5 10.0.10.11   "h5 -> h1   回程路由生效"                  ok

# ------------------------------------------------------------
#  汇总
# ------------------------------------------------------------
step "实验汇总"
echo -e "  检查点：${G}通过 $PASS${N}     ${R}失败 $FAIL${N}"
echo
echo "  r1 的路由表："
ip netns exec r1 ip route | sed 's/^/      /'
echo
echo "  r1 的三层接口："
ip netns exec r1 ip -br addr show 2>/dev/null | sed 's/^/      /'
echo
echo "  交换机端口 VLAN 表："
bridge vlan show 2>/dev/null | sed 's/^/      /'
echo
echo "  想自己进去玩："
echo "      sudo ip netns list"
echo "      sudo ip netns exec h1 ping -c 3 172.16.1.100"
echo "      sudo ip netns exec r1 ip route"
echo "      sudo ip netns exec r1 tcpdump -i eth0 -nn -e vlan    # 看 VLAN 标记"
echo
echo "  玩完了清理："
echo "      sudo bash $0 clean"
echo
if [ "$FAIL" -eq 0 ]; then
    echo -e "  ${G}全部通过。把这一屏截图存下来，简历和面试都用得上。${N}"
else
    echo -e "  ${Y}有 $FAIL 项没过，把这一屏发给生生。${N}"
fi
echo
