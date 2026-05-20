# nft-forward

基于 nftables 的交互式端口转发管理工具。支持**单端口转发**（目标端口可自定义重映射）和**端口范围同范围转发**（端口保持不变，1:1，如 `30000-30100 → 目标:30000-30100`）。

## 特性

- 单端口 DNAT 转发，目标端口可自定义（默认与本机端口相同）
- **端口范围同范围转发**：输入 `起-止`（如 `30000-30100`），自动 1:1 转发到目标同一范围，端口不变
- TCP + UDP 一并转发，自动 SNAT 回源（保证回程走本机出口 IP）
- 自动开启 IPv4 转发、BBR + fq
- 自动适配并放行防火墙：firewalld / UFW / iptables（范围分隔符自动转换）
- 规则持久化到 `/etc/nftables.d/`，重启自动恢复
- 内置诊断 / 自检、备份、一键清空

## 环境要求

- root 权限
- Debian/Ubuntu、RHEL/CentOS/Fedora 或 Arch（自动识别包管理器安装 nftables）

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
2) 查看现有端口转发
3) 新增端口转发（单端口 / 端口范围同范围）
4) 删除端口转发
5) 一键清空所有转发
6) 诊断/自检
7) 退出
```

新增转发时：

- 单端口：本机端口填 `8080`，再填目标 IP 与目标端口（默认同端口）
- 端口范围：本机端口填 `30000-30100`，填目标 IP 后**回车即同范围转发**（端口保持不变，不再询问目标端口）

生成的 nftables 规则示例（范围段，端口保持型 DNAT）：

```nft
table ip port_forward {
    chain prerouting {
        type nat hook prerouting priority -100; policy accept;
        tcp dport 30000-30100 dnat to 10.0.0.5
        udp dport 30000-30100 dnat to 10.0.0.5
    }
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        ip daddr 10.0.0.5 tcp dport 30000-30100 ct status dnat snat to $LOCAL_IP
        ip daddr 10.0.0.5 udp dport 30000-30100 ct status dnat snat to $LOCAL_IP
    }
}
```

> 同范围转发采用 nft 省略目标端口的写法（`dnat to <IP>`），即端口原样保持（30000→30000、30100→30100），是确定的 1:1 端口保持转发。
