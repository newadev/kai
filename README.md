# Komari Agent Installer (KAI)

KAI 是一个用于部署和守护 `komari-agent` 的安装脚本。它会创建低权限系统用户，准备依赖，下载 agent 二进制，生成配置文件，并按当前系统自动安装 systemd 或 OpenRC 服务。

## 快速开始

安装必须使用 root 权限。本地或远程配置必须包含有效的 `endpoint`，并且至少包含 `token` 或 `auto_discovery_key` 之一。仓库内的 `config.json` 是模板，需先填写后再用于安装。

```bash
sudo bash kai.sh -c config.json
```

使用自动发现注册：

```bash
sudo bash kai.sh -e https://panel.example.com -a <DISCOVERY_KEY>
```

使用 Token 直接接入：

```bash
sudo bash kai.sh -e https://panel.example.com -t <TOKEN>
```

使用远程配置并每 10 分钟同步一次：

```bash
sudo bash kai.sh -c https://example.com/config.json --auto 10
```

## 命令行参数

| 参数 | 说明 |
| :--- | :--- |
| `-c <path\|url>` | 本地配置文件路径或远程配置 URL |
| `-e <url>` | 面板端点，例如 `https://panel.example.com` |
| `-t <value>` | Agent 接入 Token |
| `-a <value>` | 自动发现密钥，用于自动注册节点 |
| `--auto [min\|d]` | 启用远程配置同步；`min` 为同步间隔分钟数，`d` 表示禁用 |
| `--debug` | 输出 Shell 调试追踪 |
| `-log` | 查看服务状态并追踪最近日志 |
| `-u, --uninstall` | 卸载服务和文件；仅删除由 KAI 创建的低权限用户 |

## 安全与校验

默认下载 `komari-agent` 的 latest release。生产环境建议固定版本并提供 SHA256：

```bash
sudo KAI_AGENT_VERSION=v1.2.3 \
  KAI_AGENT_SHA256=<64位sha256> \
  bash kai.sh -e https://panel.example.com -t <TOKEN>
```

也可以按架构分别提供校验和：

```bash
sudo KAI_AGENT_VERSION=v1.2.3 \
  KAI_AGENT_SHA256_AMD64=<amd64_sha256> \
  KAI_AGENT_SHA256_ARM64=<arm64_sha256> \
  bash kai.sh -c config.json
```

如需强制必须提供校验和：

```bash
sudo KAI_REQUIRE_BINARY_SHA256=1 \
  KAI_AGENT_VERSION=v1.2.3 \
  KAI_AGENT_SHA256=<64位sha256> \
  bash kai.sh -c config.json
```

未提供 SHA256 时，KAI 仍会校验下载结果是否为 ELF 二进制，但这不能替代完整的供应链校验。

## 安装目录

```text
/opt/komari-agent/
├── bin/komari-agent          # agent 二进制文件 (root:komari 750)
├── config.json               # agent 配置文件 (komari:komari 600)
├── logs/komari-agent.log     # 运行日志
└── run/
    ├── komari-wrapper.sh     # 守护、热重载、配置同步包装脚本
    └── auto-update.conf      # 远程同步配置 (root:komari 640)
```

## 运行特性

- agent 以 `komari` 低权限用户运行，默认无登录 shell、无 home。
- 如果系统中已存在 `komari` 用户，KAI 会复用该用户；卸载时不会删除预先存在的用户。
- systemd 环境会启用沙箱限制，并保留 `CAP_NET_RAW`，以支持上游 ICMP ping 任务。
- 默认禁用 Web SSH 和远程命令执行：`disable_web_ssh=true`。
- 远程配置同步会先校验 JSON、`endpoint` 和认证字段，通过后才会替换本地配置。
- `enable_gpu=true` 可能需要额外设备访问权限；在严格 systemd 沙箱下，详细 GPU 数据可能需要本地 override。

## 常用操作

```bash
# 查看 systemd 服务
sudo systemctl status komari-agent

# 查看 OpenRC 服务
sudo rc-service komari-agent status

# 查看实时日志
sudo bash kai.sh -log

# 卸载 KAI 安装的组件
sudo bash kai.sh -u
```

## 配置模板

KAI 的默认配置是偏安全和低噪声的推荐值，不完全等同于上游 `komari-agent` CLI 默认值。

| 配置项 | 类型 | KAI 默认值 | 说明 |
| :--- | :--- | :--- | :--- |
| `endpoint` | `string` | `""` | 面板连接地址 |
| `token` | `string` | `""` | 节点认证 Token |
| `auto_discovery_key` | `string` | `""` | 自动发现注册密钥 |
| `disable_web_ssh` | `bool` | `true` | 禁用 Web SSH 和远程命令执行 |
| `disable_auto_update` | `bool` | `false` | 禁用 agent 自更新 |
| `interval` | `float` | `5` | 指标采集间隔，单位秒 |
| `ignore_unsafe_cert` | `bool` | `false` | 忽略不安全 TLS 证书 |
| `max_retries` | `int` | `5` | 网络重试次数 |
| `reconnect_interval` | `int` | `10` | 重连间隔，单位秒 |
| `info_report_interval` | `int` | `15` | 基础信息上报间隔，单位分钟 |
| `include_nics` | `string` | `""` | 仅统计的网卡，逗号分隔 |
| `exclude_nics` | `string` | `""` | 排除统计的网卡，逗号分隔 |
| `include_mountpoints` | `string` | `""` | 磁盘挂载点白名单，分号分隔 |
| `month_rotate` | `int` | `1` | 流量统计月度重置日，`0` 表示禁用 |
| `cf_access_client_id` | `string` | `""` | Cloudflare Access Client ID |
| `cf_access_client_secret` | `string` | `""` | Cloudflare Access Client Secret |
| `memory_include_cache` | `bool` | `true` | 内存统计包含 cache/buffer |
| `memory_report_raw_used` | `bool` | `false` | 使用原始 used 内存公式 |
| `custom_dns` | `string` | `""` | 自定义 DNS 服务器 |
| `enable_gpu` | `bool` | `false` | 启用详细 GPU 监控 |
| `custom_ipv4` | `string` | `""` | 手动指定 IPv4 |
| `custom_ipv6` | `string` | `""` | 手动指定 IPv6 |
| `get_ip_addr_from_nic` | `bool` | `false` | 从网卡读取 IP |
| `host_proc` | `string` | `""` | 容器场景下宿主机 `/proc` 路径 |
| `protocol_version` | `int` | `2` | 上报协议版本 |
| `disable_compression` | `bool` | `false` | 禁用 v2 压缩 |
