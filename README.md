# nft-forward

基于 nftables 的交互式端口转发管理工具。支持**单端口转发**（目标端口可自定义重映射）和**端口范围同范围转发**（端口保持不变，1:1，如 `30000-30100 → 目标:30000-30100`），并支持**同一端口的 TCP / UDP 分别转发到不同目标**。

## 特性

- 单端口 DNAT 转发，目标端口可自定义（默认与本机端口相同）
- **端口范围同范围转发**：输入 `起-止`（如 `30000-30100`），自动 1:1 转发到目标同一范围，端口不变
- **协议可拆分**：同一本机端口的 TCP 与 UDP 可分别转发到不同目标 IP/端口，也可只转发 TCP 或只转发 UDP
- **流量统计**：每条转发规则自动启用 nftables counter，可在列表中查看累计包数与字节数
- **备注管理**：新增/修改转发时可填写备注，列表中直接显示用途说明
- **在线修改**：支持直接修改已有转发的本机端口、协议、目标地址、目标端口和备注
- TCP + UDP 一并转发，自动 SNAT 回源（保证回程走本机出口 IP）
- 自动开启 IPv4 转发，不接管 BBR/sysctl 网络优化参数
- 自动适配并放行防火墙：firewalld / UFW / iptables（范围分隔符自动转换）
- 规则持久化到 `/etc/nftables.d/`，重启自动恢复
- 内置诊断 / 自检、备份、一键清空

## 环境要求

- root 权限
- Debian/Ubuntu、RHEL/CentOS/Fedora 或 Arch（自动识别包管理器安装 nftables）

## BBR / sysctl 说明

本脚本只负责 nftables 端口转发和必要的 IPv4 转发开关，不再写入 `net.ipv4.tcp_congestion_control`、`net.core.default_qdisc` 等 BBR/sysctl 网络优化参数。

如需 BBR、队列、RPS、conntrack、TFO、nofile 等极致网络优化，请使用独立脚本：

```bash
sudo bash -c 'bash <(curl -fsSL https://raw.githubusercontent.com/GHUNLIL/network-bbr-optimizer/main/bbr.sh)'
```

## 使用

一键拉取运行：

```bash
curl -fsSL https://raw.githubusercontent.com/GHUNLIL/nft-forward/main/nftables.sh -o nftables.sh \
  && chmod +x nftables.sh && sudo ./nftables.sh
```

或本地：

```bash
sudo bash nftables.sh
```

菜单：

```text
1) 安装 nftables
2) 查看现有端口转发 / 流量统计
3) 新增端口转发（单端口 / 端口范围同范围）
4) 修改端口转发
5) 删除端口转发
6) 一键清空所有转发
7) 诊断/自检
8) 退出
```

新增转发时，先填本机端口（或范围），再选择协议：

```text
1) TCP + UDP → 同一目标 (默认)
2) TCP + UDP → 各自不同目标
3) 仅 TCP
4) 仅 UDP
```

- 单端口：本机端口填 `8080`，再填目标 IP 与目标端口（默认同端口）
- 端口范围：本机端口填 `30000-30100`，填目标 IP 后**回车即同范围转发**（端口保持不变，不再询问目标端口）
- **TCP/UDP 分流**：选 `2`，依次填 TCP 目标与 UDP 目标，即可让同一端口的 TCP、UDP 走不同 IP（例如 DNS `53`：TCP 转发到一台、UDP 转发到另一台）。同一端口的 `tcp` 与 `udp` 规则互不冲突，也可分两次新增（先加仅 TCP，再加仅 UDP）
- **端口范围同样支持分流**：本机端口填 `30000-30100` 后选 `2`，TCP、UDP 整段各自 1:1 转发到不同 IP（端口保持不变，如 `tcp 30000-30100 → A`、`udp 30000-30100 → B`）
- 新增转发时可填写备注，例如 `游戏服`, `DNS UDP`, `备用入口`；修改菜单可随时更新备注
- 查看列表会显示每条规则的累计流量统计；端口范围规则显示该范围的合计流量，旧规则首次启用 counter 后会从当前时刻重新累计
- 选择 `修改端口转发` 后，直接回车可保留原值，适合只改目标 IP、端口或备注

生成的 nftables 规则示例（范围段，端口保持型 DNAT）：

```nft
table ip port_forward {
    chain prerouting {
        type nat hook prerouting priority -100; policy accept;
        tcp dport 30000-30100 counter dnat to 10.0.0.5
        udp dport 30000-30100 counter dnat to 10.0.0.5
    }
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        ip daddr 10.0.0.5 tcp dport 30000-30100 ct status dnat counter snat to $LOCAL_IP
        ip daddr 10.0.0.5 udp dport 30000-30100 ct status dnat counter snat to $LOCAL_IP
    }
}
```

> 同范围转发采用 nft 省略目标端口的写法（`dnat to <IP>`），即端口原样保持（30000→30000、30100→30100），是确定的 1:1 端口保持转发。

同一端口 TCP / UDP 分流到不同目标的规则示例（端口 `53`，TCP→`9.9.9.9`、UDP→`8.8.8.8`）：

```nft
table ip port_forward {
    chain prerouting {
        type nat hook prerouting priority -100; policy accept;
        tcp dport 53 counter dnat to 9.9.9.9:53
        udp dport 53 counter dnat to 8.8.8.8:53
    }
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        ip daddr 9.9.9.9 tcp dport 53 ct status dnat counter snat to $LOCAL_IP
        ip daddr 8.8.8.8 udp dport 53 ct status dnat counter snat to $LOCAL_IP
    }
}
```
