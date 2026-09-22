# network-lab

> 用 Linux **network namespace** 在一台 Ubuntu 上模拟出「二层交换机 + 终端 + 路由器」拓扑，
> 逐项验证 **VLAN 隔离 / 单臂路由 / 静态路由**，全部结论都可在命令行复现。

## 为什么不用 eNSP / Packet Tracer

eNSP 依赖 VirtualBox 5.2.x、需要关闭 Hyper-V，在 Win11 上装机成本很高；
而原理（802.1Q 打标、VLAN 隔离、三层转发、路由选路）在 netns 与厂商设备上是一致的 ——
**先把原理用可复现的方式跑通，再去熟悉厂商命令，顺序更合理。**

## 拓扑

```
        VLAN10              VLAN20
       h1   h2             h3   h4              h5
        |    |              |    |               |
        +----+----[ br-lab 交换机 ]----+          |
                        |  trunk(10,20)          |
                       r1 ====================== r2
                    10.0.10.1                172.16.1.1
                    10.0.20.1      10.0.99.0/30
```

| 网段 | 用途 | 成员 |
|---|---|---|
| 10.0.10.0/24 | VLAN10 | h1=.11　h2=.12　网关 10.0.10.1（r1 eth0.10） |
| 10.0.20.0/24 | VLAN20 | h3=.11　h4=.12　网关 10.0.20.1（r1 eth0.20） |
| 10.0.99.0/30 | r1↔r2 骨干 | r1=.1　r2=.2 |
| 172.16.1.0/24 | 远端网络 | r2=.1　h5=.100 |

## 三阶段验证

| 阶段 | 验证内容 | 关键配置 |
|---|---|---|
| **Phase 1** 二层隔离 | 同 VLAN 通、跨 VLAN 被交换机拦住 | bridge 开 `vlan_filtering`；access 口 `pvid + untagged` |
| **Phase 2** 单臂路由 | 跨 VLAN 互通 | r1 在 trunk 口建 `eth0.10` / `eth0.20` 子接口当网关 |
| **Phase 3** 静态路由 | 跨两跳到达远端网段 | r1 指 `172.16.1.0/24 → 10.0.99.2`，r2 写回程路由 |

## 运行

```bash
sudo bash netns-lab.sh          # 跑完整实验
sudo bash netns-lab.sh clean    # 清理环境
```

需要 root（要建网络命名空间）。依赖：`iproute2`、`iputils-ping`，内核需支持 bridge VLAN filtering。

## 实测结果

Ubuntu 22.04 上执行，**9 项连通性检查全部通过**：

```
检查点：通过 9    失败 0

r1 的路由表：
    10.0.10.0/24 dev eth0.10 proto kernel scope link src 10.0.10.1
    10.0.20.0/24 dev eth0.20 proto kernel scope link src 10.0.20.1
    10.0.99.0/30 dev eth1 proto kernel scope link src 10.0.99.1
    172.16.1.0/24 via 10.0.99.2 dev eth1

交换机端口 VLAN 表：
    port      vlan-id
    b-h1      10 PVID Egress Untagged      ← access 口：出口剥标签
    b-h2      10 PVID Egress Untagged
    b-h3      20 PVID Egress Untagged
    b-h4      20 PVID Egress Untagged
    b-r1      10                            ← trunk 口：标签带着走
              20
```

## 技术点

- **802.1Q VLAN 过滤**：`bridge vlan_filtering 1` + 端口 VLAN 表，用 Linux bridge 复现交换机的 access / trunk 行为
- **单臂路由**：一根物理线上用 802.1Q 子接口承载多个 VLAN 的三层网关
- **静态路由双向可达**：只配去程不通，回程路由是常见漏项
- **可观测性**：用 `bridge vlan show` / `ip route` / `tcpdump -e vlan` 直接看到标签与选路结果

## 环境

Ubuntu 22.04（VMware 虚拟机）

## 可扩展方向

ACL、NAT、OSPF、DHCP、链路聚合 —— 拓扑脚手架不用改，往上加 netns 和配置即可。
