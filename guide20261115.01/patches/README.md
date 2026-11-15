# 本地部署补丁（无域名模式必需）

上游仓库是"域名 + 正式证书"的默认配方。为了做到 **从 GitHub 拉源码 → 打补丁 → 编译 → 纯 IP 运行**，
本目录提供一个幂等的补丁脚本，替代手工改文件。

## 用法

```sh
# 打补丁（可重复执行，已打的会跳过）
python3 apply-local-patches.py --server /srv/dnf/ServerS5A3 --purplemagic /srv/dnf/PurpleMagic

# 只检查，不写入；必须 11/11
python3 apply-local-patches.py --server /srv/dnf/ServerS5A3 --purplemagic /srv/dnf/PurpleMagic --check
```

每次 `git pull` 后重新执行一次。退出码 0 表示 11 项补丁齐全。

## 补丁清单

### ServerS5A3

| # | 文件 | 改动 | 原因 |
| --- | --- | --- | --- |
| 1 | `deploy/docker/Dockerfile` | `FROM` 后加 `ENV GOPROXY=https://goproxy.cn,direct GOSUMDB=off` | 容器内 `go mod download` 访问 proxy.golang.org 会卡死 |
| 2 | `deploy/docker/manage.py` | 默认配置加 `player_proxy_secret`、`public_bootstrap`、`advertise_ip` | 网关代理身份 / 7001 局域网可达 / 公网通告 |
| 3 | `deploy/docker/manage.py` | `generate()` 下发 `DNFBRIDGE_PLAYER_PROXY_SECRET` | 网关转发玩家请求时要带 `X-Player-Proxy-Key` |
| 4 | `deploy/docker/manage.py` | 端口列表 `bootstrap_bind:7001` | 默认只绑 `127.0.0.1`，Windows 客户端连不上 |
| 5 | `deploy/docker/manage.py` | 计算 `bootstrap_bind` | 同上 |
| 6 | `deploy/docker/manage.py` | `DNFBRIDGE_SERVER_IP` 取 `advertise_ip` 或 `host_ip` | 云主机"私网绑定 + 公网通告"（NAT） |
| 7 | `deploy/docker/manage.py` | 设 `DNF_ALLOW_PUBLIC_HOST=1` 时允许 `--host-ip` 用公网地址 | 公网 IP 直接绑在网卡上的机器 |

### PurpleMagic

| # | 文件 | 改动 | 原因 |
| --- | --- | --- | --- |
| 8 | `deploy/selfhost/Dockerfile` | 加 `ENV GOPROXY=...` | 同上 |
| 9 | `deploy/selfhost/Dockerfile` | 最终阶段 Debian 源换清华 | 公网 apt 太慢/超时 |
| 10 | `deploy/selfhost/prepare.py` | 校验证书时 IP 用 `-checkip`、域名用 `-checkhost` | 上游只支持域名，纯 IP 会被拒 |
| 11 | `deploy/selfhost/prepare.py` | 增加 `_check_host_flag()` 辅助函数 | 同上 |

## 上游改动导致补丁失败时

脚本会打印 `anchor not found (upstream changed?)`。处理顺序：

1. 打开对应文件，手工找到相同逻辑的位置（脚本里的 `old` 字符串就是锚点）；
2. 按上表把改动重新加上；
3. 重新跑 `--check`，确认 11/11；
4. 再执行构建/部署，不要跳过补丁直接编译。

## 公网（可选）

- 云主机私网 + EIP/NAT：`instance.json` 里 `host_ip` 填私网 IP，`advertise_ip` 填公网 IP；`prepare --host-ip <私网IP>`，端口映射到私网。
- 公网 IP 直接绑网卡：`DNF_ALLOW_PUBLIC_HOST=1 sh deploy/docker/manage.sh prepare --host-ip <公网IP>`。

两种情况都仍然**不需要域名**：证书用 `IP:<地址>` SAN，登录器 `ApiUrl=https://<地址>:8443`。
