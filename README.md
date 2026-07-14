# HydroJudge Docker 评测机

本项目在同一个 Docker 容器中运行 `go-judge` 沙箱和 `hydrojudge`，用于连接远端 Hydro 服务并执行评测任务。

## 1. 准备 Hydro

在 Hydro 中创建专用评测账号，并为该账号授予 `PRIV_JUDGE` 权限。

普通 Hydro 独立评测机使用的语言配置由 Hydro 服务端下发，因此还需要在服务端正确配置可用语言。具体说明见“语言配置”章节。

## 2. 配置环境变量

复制示例配置并填写实际信息：

```bash
cp .env.example .env
nano .env
chmod 600 .env
```

以下配置为必填项：

- `HYDRO_SERVER_URL`：Hydro 站点地址；
- `HYDRO_JUDGE_UNAME`：评测账号用户名；
- `HYDRO_JUDGE_PASSWORD`：评测账号密码。

建议为 4 核 CPU、8 GB 内存的单副本评测机使用以下配置：

```env
CONTAINER_CPUS=4.0
CONTAINER_MEMORY_LIMIT=8g
CONTAINER_MEMORY_SWAP_LIMIT=8g
CONTAINER_SHM_SIZE=2g

HYDRO_MEMORY_MAX=2048m
HYDRO_CONCURRENCY=3
HYDRO_PARALLELISM=3
GOJUDGE_PARALLELISM=3
```

这些配置表示：

- 单个评测容器最多使用 4 核 CPU 和 8 GB 内存；
- HydroJudge 最多同时处理 3 个任务；
- 单个评测任务允许的最大内存为 2048 MB；
- 剩余资源用于编译器、输出缓冲区、Node.js 和沙箱本身。

如果题目内存占用较大，应优先降低并发数：

```env
HYDRO_CONCURRENCY=2
HYDRO_PARALLELISM=2
GOJUDGE_PARALLELISM=2
```

## 3. 一键安装

安装脚本适用于使用 systemd 的 Linux 服务器。运行前需要安装并启动：

- Docker；
- Docker Compose 插件；
- Python 3.9 或更高版本；
- `flock`（通常由 `util-linux` 提供）；
- systemd。

填写当前目录中的 `.env` 后执行：

```bash
sudo ./install.sh install
```

为了兼容旧用法，首次安装时也可以直接执行 `sudo ./install.sh`。

也可以指定其他配置文件：

```bash
sudo ./install.sh install --env-file /path/to/production.env
```

安装脚本将自动完成以下操作：

1. 检查 Linux、systemd、Docker、Docker Compose 和 Python；
2. 验证 Hydro 地址、评测账号和密码；
3. 将程序安装到 `/opt/hydrojudge-docker`；
4. 将账号配置保存到 `/etc/hydrojudge-docker/hydrojudge.env`，权限设置为 `0600`；
5. 运行自动扩容算法测试；
6. 构建并启动评测容器；
7. 安装并启动 `hydrojudge-autoscale.service`；
8. 设置自动扩容服务开机启动。

常用安装选项：

| 选项 | 说明 |
| --- | --- |
| `--install-dir PATH` | 修改程序安装目录 |
| `--env-file FILE` | 使用指定的环境配置文件 |
| `--skip-build` | 跳过镜像构建，使用已有的 `hydrojudge-worker:local` |
| `--no-autoscale` | 不安装或启用自动扩容服务 |

重复执行安装脚本可以覆盖更新程序文件。除非显式传入 `--env-file`，已有的 `/etc/hydrojudge-docker/hydrojudge.env` 会被保留。

安装完成后，同一个 `install.sh` 也是统一管理入口：

| 命令 | 用途 |
| --- | --- |
| `install` | 安装或覆盖安装评测机 |
| `uninstall` | 安全卸载评测机 |
| `update-version` | 自动更新到最新 go-judge/HydroJudge 并重建镜像 |
| `update-config` | 读取默认位置的 `.env` 并应用配置 |

查看完整帮助：

```bash
sudo /opt/hydrojudge-docker/install.sh help
```

查看自动扩容服务状态和日志：

```bash
systemctl status hydrojudge-autoscale.service
journalctl -u hydrojudge-autoscale.service -f
```

## 4. 手动构建并启动

```bash
docker compose up -d --build
docker compose logs -f hydrojudge
```

查看容器状态：

```bash
docker compose ps hydrojudge
```

## 5. 手动调整副本数

扩容到两个评测容器：

```bash
./scale.sh 2
```

恢复为一个评测容器：

```bash
./scale.sh 1
```

不传参数时，脚本使用 `.env` 中的 `WORKER_REPLICAS`：

```bash
./scale.sh
```

副本数必须是非负整数。设置为 `0` 可以停止所有评测副本，但不会删除镜像和数据卷。

## 6. 自动扩容

`autoscale.py` 运行在 Docker 宿主机上，定期读取所有 HydroJudge 容器的 CPU 和内存使用率，并根据总负载计算所需副本数。

自动扩容具有以下保护机制：

- 连续多个采样周期达到压力条件后才扩容；
- 每次只增加有限数量的副本；
- 两次扩容之间存在冷却时间；
- 根据宿主机资源和单副本资源限制计算安全上限；
- 使用进程锁，防止同时启动多个自动扩容器；
- Docker 短暂异常不会导致监控进程退出；
- 默认只自动扩容，不自动缩容，避免终止正在运行的评测任务。

运行自动扩容器需要宿主机已经安装：

- Python 3；
- Docker；
- Docker Compose 插件。

### 只读演练

采集一次状态并显示扩容决策，但不创建或删除容器：

```bash
./autoscale.py --once --dry-run
```

### 持续运行

在前台持续监控：

```bash
./autoscale.py
```

生产环境建议使用 `systemd`、`supervisord` 或其他宿主机进程管理器保持脚本运行。同一个项目目录中只能运行一个自动扩容器。

修改自动扩容参数、容器 CPU 限制或容器内存限制后，需要重启 `autoscale.py`。

### 自动扩容参数

| 配置项 | 默认值 | 说明 |
| --- | ---: | --- |
| `AUTOSCALE_MIN_REPLICAS` | `1` | 保持运行的最少副本数 |
| `AUTOSCALE_MAX_REPLICAS` | `4` | 允许扩充到的最大副本数 |
| `AUTOSCALE_TARGET_CPU_PERCENT` | `70` | 每个副本的目标 CPU 利用率 |
| `AUTOSCALE_TARGET_MEMORY_PERCENT` | `70` | 每个副本的目标内存利用率 |
| `AUTOSCALE_SCALE_UP_SAMPLES` | `2` | 扩容前需要连续满足条件的采样次数 |
| `AUTOSCALE_INTERVAL_SECONDS` | `15` | 状态采样间隔，单位为秒 |
| `AUTOSCALE_COOLDOWN_SECONDS` | `60` | 两次扩容之间的最短间隔 |
| `AUTOSCALE_MAX_STEP` | `1` | 单次最多增加的副本数 |
| `AUTOSCALE_ENFORCE_HOST_CAPACITY` | `true` | 是否根据宿主机容量限制副本数 |
| `AUTOSCALE_HOST_HEADROOM_PERCENT` | `10` | 为宿主机和其他服务预留的资源比例 |
| `AUTOSCALE_DRY_RUN` | `false` | 是否只输出决策而不执行扩容 |

容量保护会同时参考：

- Docker 宿主机的 CPU 和内存总量；
- `CONTAINER_CPUS`；
- `CONTAINER_MEMORY_LIMIT`；
- `AUTOSCALE_HOST_HEADROOM_PERCENT`；
- `AUTOSCALE_MAX_REPLICAS`。

例如，单副本限制为 4 核 CPU、8 GB 内存时，只有约 8 GB 内存的 Docker 宿主机会被限制为最多一个副本。若要安全运行多个副本，应使用更大的宿主机，或者同步降低单副本资源限制和评测并发数。

不建议关闭宿主机容量保护，否则多个容器的资源上限可能超过宿主机容量并触发 OOM。

当前实现只负责单台宿主机上的 Docker Compose 扩容。跨多台服务器的自动扩容需要 Kubernetes、Docker Swarm 等容器编排系统。

## 7. 更新评测机版本

直接更新到两个组件的最新稳定版：

```bash
sudo /opt/hydrojudge-docker/install.sh update-version
```

脚本会在每次执行时查询：

- go-judge 官方 GitHub 仓库的最新稳定 Release；
- npm Registry 中 `@hydrooj/hydrojudge` 的 `latest` 版本。

查询成功后，脚本会自动更新正式配置中的 `GOJUDGE_VERSION` 和 `HYDROJUDGE_VERSION`。如果外部版本接口暂时无法访问，可以手动指定两个版本作为回退：

```bash
sudo /opt/hydrojudge-docker/install.sh update-version \
  --gojudge-version v1.12.1 \
  --hydrojudge-version 4.0.5
```

版本更新将执行以下操作：

1. 从默认位置 `/etc/hydrojudge-docker/hydrojudge.env` 读取现有配置；
2. 查询并校验最新稳定版本；
3. 将新版本安全写回正式配置；
4. 暂停自动扩容操作；
5. 根据新版本无缓存重建镜像；
6. 保留当前正在运行的副本数，且不会自动缩容；
7. 使用新镜像重建评测容器；
8. 重启自动扩容服务并显示容器状态。

版本更新会重建容器，可能中断正在执行的评测任务，应在维护时间执行。

## 8. 更新评测机配置

直接修改默认位置的正式配置，然后应用：

```bash
sudoedit /etc/hydrojudge-docker/hydrojudge.env
sudo /opt/hydrojudge-docker/install.sh update-config
```

`update-config` 默认只读取 `/etc/hydrojudge-docker/hydrojudge.env`，不再自动读取源码目录中的 `.env`。如需从其他文件导入，仍可显式指定：

```bash
sudo /opt/hydrojudge-docker/install.sh update-config \
  --env-file /path/to/production.env
```

配置更新会：

1. 先在临时文件中验证 Hydro 地址、账号、密码和 Compose 配置；
2. 防止意外修改 `COMPOSE_PROJECT_NAME` 而创建第二套容器；
3. 将正式配置权限固定为 `0600`；
4. 暂停自动扩容并通过 Compose 应用配置；
5. 保留当前副本数，允许按新的 `WORKER_REPLICAS` 扩容，但不会自动缩容；
6. 重启自动扩容服务，使新的自动扩容参数立即生效。

`update-config` 不重建镜像。如果修改了 `GOJUDGE_VERSION` 或 `HYDROJUDGE_VERSION`，脚本会拒绝继续并提示使用 `update-version`。修改容器资源、环境变量等设置时，Compose 可能重建容器，因此也建议在维护时间执行。

## 9. 一键卸载

使用安装目录中的卸载脚本：

```bash
sudo /opt/hydrojudge-docker/install.sh uninstall
```

卸载前会显示将要删除的内容并要求确认。默认执行以下操作：

- 停止并删除自动扩容 systemd 服务；
- 停止并删除评测容器和 Compose 网络；
- 删除项目数据卷；
- 删除 `hydrojudge-worker:local` 镜像；
- 删除 `/opt/hydrojudge-docker`；
- 保留 `/etc/hydrojudge-docker/hydrojudge.env`，方便重新安装。

完整卸载并删除评测账号配置：

```bash
sudo /opt/hydrojudge-docker/install.sh uninstall --purge
```

无人值守完整卸载：

```bash
sudo /opt/hydrojudge-docker/install.sh uninstall --purge --yes
```

保留数据卷或镜像：

```bash
sudo /opt/hydrojudge-docker/install.sh uninstall --keep-data --keep-image
```

`--keep-data` 主要用于故障排查。项目使用的匿名数据卷在重新安装后不会自动重新挂载，长期保留前应手动记录卷名或完成数据备份。

卸载脚本只会在安装目录存在 `.hydrojudge-install` 标记时开始清理，并拒绝 `/`、`/opt`、`/usr` 等危险路径。因此，从源码目录误执行卸载脚本不会删除同名服务、卷或镜像。

## 10. 手动停止服务

停止并删除评测容器：

```bash
docker compose down
```

如需同时删除评测缓存和临时数据卷：

```bash
docker compose down -v
```

`down -v` 会永久删除缓存数据，执行前请确认不再需要这些内容。

## 11. 检查资源限制

查看当前资源使用情况：

```bash
docker compose stats --no-stream hydrojudge
```

查看 Docker 实际应用的资源限制：

```bash
docker inspect $(docker compose ps -q hydrojudge) \
  --format 'NanoCpus={{.HostConfig.NanoCpus}} Memory={{.HostConfig.Memory}} MemorySwap={{.HostConfig.MemorySwap}} ShmSize={{.HostConfig.ShmSize}}'
```

使用默认配置时，单个副本的核心限制应为：

```text
NanoCpus=4000000000
Memory=8589934592
MemorySwap=8589934592
ShmSize=2147483648
```

## 12. 语言配置

镜像内固定安装以下运行环境：

- GCC/G++ 15；
- Java 21；
- Python 3.12；
- PyPy3。

镜像不会安装 Go 编译器。`go-judge` 是评测沙箱的名称，并不表示启用了 Go 语言评测。

系统中的 `gcc`、`g++`、`cc` 和 `c++` 命令均指向 GCC/G++ 15。

### 普通 Hydro 模式

普通 Hydro 独立评测机的语言命令由 Hydro 服务端通过 WebSocket 下发。当前 HydroJudge 不读取评测机上的 `~/.hydro/langs.yaml`。

因此需要在 Hydro 服务端的语言设置中：

- 删除或禁用 Go 语言；
- C/C++ 使用 `/usr/bin/gcc`、`/usr/bin/g++`，或者显式使用 `/usr/bin/gcc-15`、`/usr/bin/g++-15`；
- Python 使用 `/usr/bin/python3`，或者显式使用 `/usr/bin/python3.12`。

项目中的 `langs.yaml` 可以作为 Hydro 服务端语言配置的参考。

### vj4 模式

使用 `HYDRO_HOST_TYPE=vj4` 时，镜像通过以下变量直接加载项目内的语言配置：

```env
VJ4_LANGS=/opt/langs.yaml
```

更新 `langs.yaml` 后，需要重新构建并重建容器：

```bash
docker compose build --no-cache hydrojudge
docker compose up -d --force-recreate hydrojudge
```

验证编译器和运行时：

```bash
docker compose exec hydrojudge bash -lc 'gcc --version && g++ --version && javac -version && java -version && python3.12 --version && pypy3 --version && ! command -v go'
```

## 13. 安全与运行注意事项

- go-judge 需要创建受限执行环境，因此容器必须使用 `privileged: true`；
- 启动脚本会把评测配置写入 `/root/.hydro/judge.yaml`，并设置为 `0600` 权限；
- `entrypoint.sh` 会自动为缺少结尾 `/` 的 `HYDRO_SERVER_URL` 补全斜杠；
- URL、用户名和密码在写入 YAML 前会进行安全转义；
- `.env` 包含评测账号密码，已经从 Docker 构建上下文和 Git 中排除，但仍不应上传或放入共享压缩包；
- 一键安装后的正式配置位于 `/etc/hydrojudge-docker/hydrojudge.env`；
- 如果 `.env` 或原始压缩包曾经公开，应立即更换评测账号密码；
- 启用新的语言前，必须同时在 Dockerfile 中安装相应编译器，并在 Hydro 服务端配置对应命令；
- 自动扩容只使用资源利用率作为负载信号，不等同于读取 Hydro 服务端的任务队列长度。

## 14. 配置与脚本校验

检查 Compose 配置：

```bash
docker compose config --quiet
```

运行自动扩容算法测试：

```bash
python3 -m unittest discover -s tests -v
```

检查 Shell 脚本语法：

```bash
bash -n entrypoint.sh scale.sh update.sh install.sh uninstall.sh
```
