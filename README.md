## V2bX / XrayR Nginx 反代与 HY2 伪装脚本

在原 XrayR Nginx 反代脚本基础上整理，支持：

- WS / gRPC + TLS 通用 Nginx 反代：`v2pr`
- V2bX Hysteria2 + TLS + Nginx 伪装：`v2hy2`
- HY2 用户连接端口支持单端口或端口段，例如：`443`、`10001-10099`

## 一键安装

```shell
bash <(curl -fsSL https://raw.githubusercontent.com/limo13660/v2bx-proxy/main/install.sh)
```

安装完成后可运行：

```shell
v2pr
```

HY2 伪装运行：

```shell
v2hy2
```

HY2 默认连接端口段为：

```text
10001-10099
```

脚本会让 Nginx 监听该端口段的 TCP 端口作为伪装站，同时放行同端口段 UDP 给 V2bX / Hysteria2 使用。

## 直接运行

```shell
bash <(curl -fsSL https://raw.githubusercontent.com/limo13660/v2bx-proxy/main/v2pr.sh)
```

```shell
bash <(curl -fsSL https://raw.githubusercontent.com/limo13660/v2bx-proxy/main/hy2.sh)
```

## XrayR 项目

https://github.com/XrayR-project/XrayR
