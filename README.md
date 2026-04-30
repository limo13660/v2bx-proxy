## V2bX / XrayR Nginx 反代与 HY2 443 伪装脚本

在原 XrayR Nginx 反代脚本基础上整理，支持：

- WS / gRPC + TLS 通用 Nginx 反代：`v2pr`
- V2bX Hysteria2 + TLS + Nginx 443 伪装：`v2hy2`
- HY2 用户连接入口端口支持单端口或端口段，例如：`10001-10099`

## HY2 端口结构

本版本按“多入口端口转发到 443”的方式工作：

```text
客户端 UDP 10001-10099
        ↓ iptables REDIRECT
本机 UDP 443：V2bX / Hysteria2 实际监听

客户端 TCP/HTTPS 443
        ↓
Nginx 伪装网站
```

也就是说：

- Nginx 只监听 `443/tcp`，用于伪装网站；
- V2bX / HY2 只监听 `443/udp`；
- `10001-10099/udp` 只是用户连接入口，会自动转发到 `443/udp`；
- 不再让 Nginx 监听整个 `10001-10099/tcp` 端口段。

## 一键安装

```shell
bash install.sh
```

安装完成后可运行：

```shell
v2pr
```

HY2 伪装运行：

```shell
v2hy2
```

HY2 默认用户连接入口端口段为：

```text
10001-10099
```

## 面板 / V2bX 配置重点

V2bX / 面板中的 Hysteria2 节点实际监听端口请设为：

```text
443
```

客户端或订阅可使用：

```text
10001-10099
```

如果面板只能填写一个端口，请填写 `443` 作为服务端监听端口，然后在订阅或客户端侧生成多个入口端口。

## 检查规则

```shell
iptables -t nat -S PREROUTING | grep REDIRECT
systemctl status v2hy2-port-forward.service
ss -lntup | grep ':443'
```

## XrayR 项目

https://github.com/XrayR-project/XrayR
