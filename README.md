## 一键安装

远程一键安装命令保持为：

```shell
bash <(curl -fsSL https://raw.githubusercontent.com/limo13660/v2bx-proxy/main/install.sh)
```

如果是下载 zip 后本地安装，则执行：

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


## 更新脚本

更新通用反代脚本：

```shell
v2pr update
```

更新 HY2 伪装脚本：

```shell
v2hy2 update
```

也可以重新执行一键安装命令覆盖安装：

```shell
bash <(curl -fsSL https://raw.githubusercontent.com/limo13660/v2bx-proxy/main/install.sh)
```

## 检查规则

```shell
iptables -t nat -S PREROUTING | grep REDIRECT
systemctl status v2hy2-port-forward.service
ss -lntup | grep ':443'
```
