# arm_ros2_ws

在 x86_64 Ubuntu 24.04 上，为 ARM64(aarch64) 目标系统交叉编译 ROS2 Jazzy 功能包的工作空间。

ARM 系统的内存通常比较有限，直接在目标设备上编译激光雷达、导航这类包很容易内存不足。这个仓库用 Docker + QEMU 在电脑上运行 ARM64 编译环境，编译完成后只需要把 `install/` 推到 ARM 系统。

## 目录结构

```text
arm_ros2_ws/
├── install.sh          # 检测并安装交叉编译环境
├── build.sh            # 选择全部或单个包进行编译
├── clean.sh            # 清除全部或单个包的构建产物
├── push.sh             # 把 install/ 推送到 ARM 系统并覆盖远端 install
├── docker/
│   ├── Dockerfile      # ARM64 ROS2 Jazzy 编译镜像
│   └── entrypoint.sh
├── lib/
│   └── common.sh
└── src/                # 放你的 ROS2 功能包
```

## 环境要求

- Ubuntu 24.04，x86_64 或 aarch64
- Docker，普通用户能执行 `docker` 命令，或者能使用 `sudo docker`
- 建议至少 8GB 可用磁盘空间
- 能访问 Docker 镜像源和 apt 镜像源

## 快速开始

1. 把 ROS2 功能包放到 `src/` 下，每个包都要有 `package.xml`。

   仓库默认忽略 `src/` 下的内容，只保留 `src/.gitkeep`。如果想把某个包一起提交到 Git，使用 `git add -f src/你的包名`。

2. 安装交叉编译环境：

    ```bash
    ./install.sh
    ```

    第一次运行会拉取 `arm64v8/ros:jazzy-ros-base` 并构建编译镜像，通常需要 10-30 分钟。之后再运行会检测镜像是否已是最新，直接跳过。

3. 编译：

    ```bash
    ./build.sh
    ```

    脚本会列出 `src/` 里的所有 ROS 包，可以选择全部编译，也可以只编译其中一个。产物在仓库根目录的 `install/` 下。

4. 推送到 ARM 系统：

    ```bash
    ./push.sh -u user -i 192.168.x.xx -p "~/ros2_ws"
    ```

    也可以使用简写：

    ```bash
    ./push.sh -user -192.168.x.xx -"~/ros2_ws"
    ```

    推送完成后，在 ARM 系统上执行：

    ```bash
    source ~/ros2_ws/install/setup.bash
    ros2 pkg list
    ```

## 脚本说明

### install.sh

```bash
./install.sh [选项]
```

检查 CPU 架构、Ubuntu 版本、Docker、QEMU ARM64 支持和基础镜像，然后构建 `arm_ros2_ws:jazzy` 镜像。

| 选项 | 说明 |
| --- | --- |
| `-f, --force` | 强制重新构建镜像 |
| `--mirror` | 配置 Docker 国内镜像加速并重启 Docker |
| `--no-cache` | 构建镜像时不使用缓存 |
| `--ubuntu-mirror URL` | 指定 Ubuntu Ports 镜像，默认清华源 |
| `--ros-mirror URL` | 指定 ROS2 apt 镜像，默认清华源 |

国内网络如果拉取 Docker Hub 超时，先运行：

```bash
./install.sh --mirror
```

脚本会备份原有的 `/etc/docker/daemon.json`，写入 `docker.m.daocloud.io` 和 `docker.1ms.run` 两个加速源，然后重启 Docker。原来的其他配置会保留。

### build.sh

```bash
./build.sh [选项]
```

不带参数时会显示包选择菜单。`build.sh` 只负责编译，不会重新安装环境，也不会自动清理旧的编译结果；需要清理时使用 `clean.sh`。

| 选项 | 说明 |
| --- | --- |
| `-a, --all` | 编译全部包 |
| `-p, --package NAME` | 只编译指定包，可重复使用 |
| `--packages A,B` | 编译多个指定包 |
| `-j, --jobs N` | 并行任务数，默认 2 |
| `--debug` | 使用 Debug 构建，默认 Release |
| `--with-deps` | 连同 `src/` 中的依赖包一起编译 |
| `--list` | 只列出包名 |
| `--dry-run` | 只打印 Docker 命令，不执行 |
| `-y, --yes` | 跳过确认 |

编译使用独立的 `build/`、`install/`、`log/` 目录，默认不使用 `--symlink-install`，所以 `install/` 可以直接复制到 ARM 系统。

如果宿主机内存紧张，可以降低并行数：

```bash
./build.sh -j 1
```

### clean.sh

```bash
./clean.sh [选项]
```

不带参数时显示菜单，可以清除全部构建产物，也可以只清除某个包。

| 选项 | 说明 |
| --- | --- |
| `-a, --all` | 清除 `build/`、`install/`、`log/` |
| `-p, --package NAME` | 只清除指定包的构建和安装目录 |
| `-y, --yes` | 跳过确认 |

清除单个包时，会删除 `build/<包名>`、`install/<包名>` 以及该包对应的构建日志。

### push.sh

```bash
./push.sh -u 用户名 -i IP -p "远端路径"
```

把本地 `install/` 覆盖到 ARM 系统的 `<远端路径>/install`。用户名和路径分别用 `-u`、`-p` 指定，默认路径是 `~/ros2_ws`。

| 选项 | 说明 |
| --- | --- |
| `-u, --user NAME` | SSH 用户名 |
| `-i, --ip HOST` | ARM 系统的 IP 或主机名 |
| `-p, --path PATH` | 远端工作空间路径 |
| `-P, --port PORT` | SSH 端口，默认 22 |
| `-k, --key FILE` | SSH 私钥文件 |
| `-n, --dry-run` | 只打印计划，不连接 ARM 系统 |
| `-y, --yes` | 跳过确认 |

推送时优先使用 `rsync --delete`，远端没有 `rsync` 时使用 `tar`。两种方式都会覆盖远端原有的 `install/`。

建议先配置 SSH 免密登录：

```bash
ssh-copy-id user@192.168.x.xx
```

## 工作原理

- 基础镜像是 `arm64v8/ros:jazzy-ros-base`，已经包含 ROS2 Jazzy、colcon 和 rosdep。
- 在 x86_64 主机上通过 QEMU 运行 ARM64 容器。
- 编译时把当前仓库挂载到容器的 `/ws`，在容器里执行 `colcon build`。
- 容器内安装 `libpcl-dev`、`pcl_conversions`、`pcl_ros` 等常用依赖，适合激光雷达和导航相关包。

## 添加新的依赖

如果某个包需要额外的系统依赖或 ROS 包，编辑 `docker/Dockerfile`，在 `apt-get install` 列表中加上对应包，然后重建镜像：

```bash
./install.sh --force
```

## 常见问题

**提示 Docker Hub 连接超时**

```bash
./install.sh --mirror
```

**构建时报 `exec format error`**

QEMU ARM64 没有启用。重新运行：

```bash
./install.sh
```

**apt 下载很慢或失败**

默认使用清华源。也可以手动指定镜像：

```bash
./install.sh --ubuntu-mirror https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports \
             --ros-mirror https://mirrors.tuna.tsinghua.edu.cn/ros2/ubuntu
```

**编译时内存不足**

降低并行任务数：

```bash
./build.sh -j 1
```

**push.sh 提示找不到 install**

先执行 `./build.sh`。`push.sh` 只负责传输，不会自动编译。

**SSH 连接失败**

先手动确认能登录：

```bash
ssh user@192.168.x.xx
```

检查用户名、IP、网络和 SSH 密钥。使用密码登录时，脚本会在传输前提示输入密码。
