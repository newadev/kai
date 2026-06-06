# Komari Agent Installer (KAI)

KAI 是一个用于一键部署和守护 `komari-agent` 的 Shell 脚本。支持硬隔离系统用户运行、自动依赖准备、OpenRC/Systemd 适配、以及远程配置自动定时同步。

---

## 🚀 快速开始

必须以 `root` 权限运行以下安装指令：

*   **本地配置文件安装**：
    ```bash
    sudo bash kai.sh -c config.json
    ```
*   **远程配置 + 自动同步（如每 10 分钟同步一次）**：
    ```bash
    sudo bash kai.sh -c https://example.com/config.json --auto 10
    ```
*   **自动发现注册模式**：
    ```bash
    sudo bash kai.sh -e https://panel.example.com -a <DISCOVERY_KEY>
    ```
*   **指定 Token 直接接入**：
    ```bash
    sudo bash kai.sh -e https://panel.example.com -t <TOKEN>
    ```

---

## ⚙️ 命令行参数

| 参数 | 说明 |
| :--- | :--- |
| `-c <path\|url>` | 本地配置文件路径或远程配置 URL |
| `-e <url>` | 指定面板端点（例如 `https://panel.example.com`） |
| `-t <value>` | 指定 Agent 接入 Token |
| `-a <value>` | 自动发现密钥（用于未在面板手动添加服务器时自动注册） |
| `--auto [min\|d]` | 开启自动配置同步间隔（单位分钟；传入 `d` 代表禁用，默认关闭） |
| `--debug` | 输出 Shell 调试追踪信息 |
| `-log` | 实时查看运行日志及服务状态 |
| `-u` | 彻底卸载 Agent、守护程序、服务和低特权用户 |

---

## 📂 安装目录结构

```text
/opt/komari-agent/
├── bin/komari-agent          # 只读二进制文件 (root:komari 750)
├── config.json               # 核心配置文件 (komari:komari 600)
├── logs/komari-agent.log     # 运行日志 (komari:komari 750)
└── run/
    ├── komari-wrapper.sh     # 守护和热重载包装脚本 (root:komari 750)
    └── auto-update.conf      # 远程同步配置信息 (root:komari 640)
```

---

## 🔧 常用操作

```bash
# 查看服务状态 (Systemd)
sudo systemctl status komari-agent

# 查看服务状态 (OpenRC / Alpine)
sudo rc-service komari-agent status

# 查看实时运行日志
sudo bash kai.sh -log

# 卸载全部组件
sudo bash kai.sh -u
```

---

## 📝 配置规范 (`config.json`)

默认及优化的配置结构如下。可直接在 `/opt/komari-agent/config.json` 中修改：

| 配置项 | 类型 | 默认值 | 说明 |
| :--- | :--- | :--- | :--- |
| `endpoint` | `string` | `""` | 面板服务连接地址 (例如 `https://panel.example.com`) |
| `token` | `string` | `""` | 节点认证通信密钥 |
| `auto_discovery_key` | `string` | `""` | 自动发现密钥（动态注册） |
| `disable_web_ssh` | `bool` | `true` | **重要**。默认禁用 Web SSH 与远程指令执行，保障安全 |
| `disable_auto_update`| `bool` | `false`| 是否禁用 Agent 自动升级程序 |
| `interval` | `float`  | `5` | 性能指标采集上报间隔（秒） |
| `ignore_unsafe_cert` | `bool` | `false`| 强制忽略自签名 SSL 证书安全报错 |
| `max_retries` | `int` | `5` | 网络断开重连最大尝试次数 |
| `reconnect_interval` | `int` | `10` | 重连等待间隔（秒） |
| `info_report_interval`| `int` | `15` | 主机基础信息（如系统版本、IP等）上报间隔（分钟） |
| `include_nics` | `string` | `""` | 仅统计的网卡列表（英文逗号分隔，支持通配符 `*`） |
| `exclude_nics` | `string` | `""` | 统计中排除的网卡列表 |
| `include_mountpoints`| `string` | `""` | 磁盘统计挂载点白名单（英文分号分隔） |
| `month_rotate` | `int` | `1` | 流量统计月度重置日期（1-31，`0` 表示禁用自动重置） |
| `cf_access_client_id`| `string` | `""` | Cloudflare Access Client ID (Zero Trust) |
| `cf_access_client_secret`| `string`| `""` | Cloudflare Access Client Secret |
| `memory_include_cache`| `bool` | `true` | 内存统计是否包含系统 Cache 与 Buffer 缓存 |
| `memory_report_raw_used`| `bool` | `false`| 使用原始公式计算已用内存（Total - Free - Buffers - Cached） |
| `custom_dns` | `string` | `""` | 自定义 DNS 服务地址（默认留空，采用系统默认 DNS） |
| `enable_gpu` | `bool` | `false`| 开启详细的 GPU (如 NVIDIA) 状态采集 |
| `custom_ipv4`/`custom_ipv6`| `string`| `""` | 手动指定上报的 IP 地址以覆盖自动探测 |
| `get_ip_addr_from_nic`| `bool` | `false`| 是否绕过外部 API，直接从网卡接口读取 IP |
| `host_proc` | `string` | `""` | 宿主机 `/proc` 挂载路径（适用于 Docker 监控） |
| `protocol_version` | `int` | `2` | 数据上报协议版本 (v1 或 v2) |
| `disable_compression`| `bool` | `false`| 禁用 v2 数据流的 Gzip 网络压缩 |
