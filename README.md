# overleaf

`overleaf` 是局域网内自托管的 Overleaf 社区版（CE）部署骨架：`overleaf` + `mongo` + `redis` 三个容器，用 Podman + Quadlet 管理，供可信局域网用户协作编辑 LaTeX 项目。

当前设计目标（跟标准 overleaf-toolkit 相比做了两处减法，都是为了省内存/降低复杂度）：

- **不开 Sandboxed Compiles**：不挂载 `docker.sock`，不跑 sibling 容器。编译进程和 web 进程在同一个 `overleaf` 容器里，省掉了额外容器的常驻开销，代价是编译代码能访问 `overleaf` 容器内部——只适合可信局域网用户，见下面「内存与安全取舍」。
- **不部署 Nginx/TLS**：局域网内直接 HTTP 访问，省一个常驻的反代容器。

注册采用邀请制（社区版默认行为），不开放公开注册页。

## 目录结构

```text
/home/hupenghui/Documents/overleaf
├── README.md
├── variables.env.example
├── .gitignore
├── quadlet/
│   ├── overleaf-net.network
│   ├── mongo.container
│   ├── redis.container
│   └── overleaf.container
├── ops/
│   ├── README.md
│   └── service.manifest.json
└── scripts/
    ├── check_project.sh
    └── init_mongo_replica_set.sh
```

`data/`（`mongo` / `redis` / `overleaf` 三份持久化数据）不放进版本库，运行前在目标机器上手动创建，见下面安装步骤。

## 运行形态

- `Podman + Quadlet + systemd`（rootful，系统级，装到 `/etc/containers/systemd`，用 `sudo systemctl` 管理）
- 三个容器共享一个专用网络 `overleaf-net`，互相通过容器名（`mongo` / `redis` / `overleaf`）解析
- 对应 systemd 单元：`mongo.service` / `redis.service` / `overleaf.service`

依赖关系：`overleaf.service` 的 `[Unit]` 里写了 `After=` / `Requires=` `mongo.service redis.service`，所以 `systemctl start overleaf` 会先拉起 mongo/redis。但 Quadlet 没有 Docker Compose 那种「等 healthcheck 变 healthy 再启动下一个」的机制，只能保证「先启动」，保证不了「mongo 已经能处理请求」——这就是为什么还需要手动跑一次 mongo 副本集初始化（见下面步骤 2）。

## 端口与访问

- 只监听局域网网卡地址 `192.168.3.11:18437`，不绑定 `0.0.0.0`，也不会暴露到公网
- 同局域网内其他设备直接打开 `http://192.168.3.11:18437` 即可

## 配置文件

示例配置：

- [variables.env.example](/home/hupenghui/Documents/overleaf/variables.env.example)

实际部署前复制为真实配置：

```bash
cp /home/hupenghui/Documents/overleaf/variables.env.example /home/hupenghui/Documents/overleaf/variables.env
```

复制完 `variables.env` 之后，**唯一必须手动填的字段只有 `OVERLEAF_INVITE_TOKEN_SECRET`**（其余字段已经按这次部署的端口/IP 预填好，不用动）。改完保存文件即可，不需要额外"加载"——`overleaf.container` 里的 `EnvironmentFile=` 会在 `systemctl start overleaf.service` 时自动读取它。

- 生成 `OVERLEAF_INVITE_TOKEN_SECRET`（生成后不要再改，否则已发出的邀请链接会失效）：
  ```bash
  openssl rand -base64 32
  ```
  把结果填进 `variables.env` 的 `OVERLEAF_INVITE_TOKEN_SECRET=`
- 按需打开/填写 SMTP（不配也能用，管理员建号后把 Admin Panel 生成的邀请链接手动转发给对方即可）

不要把真实的 `variables.env` 提交到版本库（`.gitignore` 已覆盖）。

## Quadlet 文件

本项目提供四个 Quadlet 骨架：

- [quadlet/overleaf-net.network](/home/hupenghui/Documents/overleaf/quadlet/overleaf-net.network)
- [quadlet/mongo.container](/home/hupenghui/Documents/overleaf/quadlet/mongo.container)
- [quadlet/redis.container](/home/hupenghui/Documents/overleaf/quadlet/redis.container)
- [quadlet/overleaf.container](/home/hupenghui/Documents/overleaf/quadlet/overleaf.container)

设计要点：

- 三个容器都加入 `overleaf-net`，互相用容器名互访（`mongodb://mongo/sharelatex`、`redis:6379`）
- `mongo` 用 `--replSet overleaf` 启动（Overleaf 的文档操作历史依赖 Mongo 的 change streams/事务，单节点也必须是副本集）
- `mongo` / `redis` 都带了内存相关的启动参数（`--wiredTigerCacheSizeGB` / `--maxmemory`），把常驻内存占用限制在几百 MB 级别，而不是让 Mongo 按「宿主机内存的一半」自己去抢
- `overleaf` 容器本身也设了硬上限（`PodmanArgs=--memory=1536m --memory-swap=1536m`），防止编译大文档/多人并发编译时把宿主机内存吃满，影响这台机器上其他服务；超限会被 OOM kill，systemd 再自动拉起来
- `overleaf` 只发布到 `192.168.3.11:18437`
- 自动重启由 systemd 接管（`Restart=always`）

## 内存与安全取舍

这份骨架跟官方 `overleaf-toolkit` 的默认配置比，主动关掉了两个功能来省内存，都是可逆的：

| 功能 | 本骨架 | 官方默认 | 省下什么 / 代价是什么 |
|---|---|---|---|
| Sandboxed Compiles | 关 | 开（sibling 容器） | 省：每次编译不用额外起一个 TeX Live 容器的常驻/瞬时开销；代价：编译代码能访问 `overleaf` 容器内部，只适合可信用户 |
| Nginx/TLS | 关 | 开（可选） | 省：一个常驻的反代容器；代价：没有 HTTPS，局域网内明文 HTTP |

如果以后想打开 Sandboxed Compiles，需要：

1. 把宿主机的 `/var/run/docker.sock`（或 podman 的 socket）挂进 `overleaf.container`
2. 在 `variables.env` 里配置 `SANDBOXED_COMPILES=true` 和 `TEXLIVE_IMAGE=...`
3. 预先 `podman pull` 对应的 TeX Live 镜像

这会额外占用磁盘（TeX Live 镜像本身几个 GB）和编译时的瞬时内存，但常驻内存影响不大（容器编译完就停）。

## 与 all 面板的关系

本项目包含：

- [ops/service.manifest.json](/home/hupenghui/Documents/overleaf/ops/service.manifest.json)

这样 `all` 扫描 `/home/hupenghui/Documents/*/ops/service.manifest.json` 时，就能把它当作一个自定义服务纳入台账。

建议在正式启用前，先到 `all` 的"监听端口"页搜索 `18437`，确认没有冲突。

## 自检

项目自检脚本：

- [scripts/check_project.sh](/home/hupenghui/Documents/overleaf/scripts/check_project.sh)

可用于检查：

- JSON 语法
- `.gitignore` 是否覆盖 `variables.env` 和 `data/`
- manifest 是否疑似包含敏感字段
- Quadlet 骨架文件是否存在且格式基本正确

运行方式：

```bash
bash /home/hupenghui/Documents/overleaf/scripts/check_project.sh
```

## 实际安装命令清单

这一步我没有替你执行，下面只给推荐命令清单。

### 1. 准备目录和真实配置

```bash
mkdir -p /home/hupenghui/Documents/overleaf/data/{overleaf,mongo,redis}

cp /home/hupenghui/Documents/overleaf/variables.env.example \
   /home/hupenghui/Documents/overleaf/variables.env

# 生成 invite token secret，填进 variables.env
openssl rand -base64 32
```

### 2. 用 all 先检查端口是否冲突

```bash
ss -tulpn | rg ':18437\b'
```

### 3. 显式拉取镜像（可选，首次启动会自动拉）

同样是 rootful 部署，普通用户拉的镜像进的是用户自己的 rootless 存储，systemd 起的 rootful 容器看不到，等于白拉——要拉就得 `sudo`：

```bash
sudo podman pull docker.io/library/mongo:8.0
sudo podman pull docker.io/library/redis:7.4
sudo podman pull docker.io/sharelatex/sharelatex:6.3.0
```

### 4. 安装 Quadlet 文件

```bash
sudo install -d /etc/containers/systemd
sudo install -m 0644 /home/hupenghui/Documents/overleaf/quadlet/overleaf-net.network /etc/containers/systemd/
sudo install -m 0644 /home/hupenghui/Documents/overleaf/quadlet/mongo.container       /etc/containers/systemd/
sudo install -m 0644 /home/hupenghui/Documents/overleaf/quadlet/redis.container       /etc/containers/systemd/
sudo install -m 0644 /home/hupenghui/Documents/overleaf/quadlet/overleaf.container    /etc/containers/systemd/
sudo systemctl daemon-reload
```

说明：Quadlet 生成的 `*.service` 属于 generated unit，`daemon-reload` 后生成器会按各文件 `[Install]` 段自动处理开机启动关系，不需要再手动 `systemctl enable`。

### 5. 先起 mongo，初始化副本集

```bash
sudo systemctl start mongo.service
bash /home/hupenghui/Documents/overleaf/scripts/init_mongo_replica_set.sh
```

这一步只需要在**首次部署**时做一次；脚本本身是幂等的，重跑无副作用。

### 6. 起 redis 和 overleaf

```bash
sudo systemctl start redis.service
sudo systemctl start overleaf.service
```

### 7. 验证服务状态和日志

```bash
systemctl status mongo redis overleaf
journalctl -u overleaf -f
sudo podman ps --filter name=overleaf --filter name=mongo --filter name=redis
```

首次启动 Overleaf 应用本身需要一点时间（初始化数据库索引等），日志里看到监听 `3000`/`80` 端口相关的行再去浏览器访问。

### 8. 从局域网内测试访问

```text
http://192.168.3.11:18437
```

### 9. 创建第一个（管理员）账号

社区版是邀请制，没有公开注册页，第一个账号也要手动建：

```bash
sudo podman exec -it overleaf node modules/server-ce-scripts/scripts/create-user.mjs --email=你的邮箱@example.com
```

执行后会打印一个一次性的设置密码链接（如果没配 SMTP，链接不会发邮件，只会打印在命令输出里），拿这个链接去浏览器里设置密码。之后如果要邀请其他人，同样用这个命令加 `--email`，或者登录后台的 Admin Panel 里点 "New User"。

### 10. 如需停用或重载

```bash
sudo systemctl restart overleaf.service
sudo systemctl stop overleaf.service redis.service mongo.service
sudo systemctl disable overleaf.service redis.service mongo.service
```

## 升级怎么做

Overleaf 镜像版本写死在 `quadlet/overleaf.container` 的 `Image=` 里（当前 `sharelatex/sharelatex:6.3.0`）。升级流程：

1. 改 `quadlet/overleaf.container` 里的版本号
2. `sudo install` 覆盖 `/etc/containers/systemd/overleaf.container`
3. `sudo systemctl daemon-reload`
4. `sudo podman pull docker.io/sharelatex/sharelatex:<新版本>`
5. `sudo systemctl restart overleaf.service`

升级前建议看一下官方 [Server CE Release Notes](https://github.com/overleaf/overleaf/wiki)，个别大版本升级会有额外的一次性迁移步骤（比如老版本升级到 5.x 之后才需要副本集，这个骨架已经是按新版本来的，不用管这一条）。

## 备份怎么做

需要备份的只有 `data/` 目录（三个子目录都要）：

```bash
sudo systemctl stop overleaf.service redis.service mongo.service
sudo tar czf overleaf-backup-$(date +%Y%m%d).tar.gz -C /home/hupenghui/Documents/overleaf data
sudo systemctl start mongo.service redis.service overleaf.service
```

`variables.env` 也建议一起备份（里面有 `OVERLEAF_INVITE_TOKEN_SECRET`，丢了会让所有未使用的邀请链接失效，但不影响已注册用户）。

## 权限边界

- 读项目文件不需要 root
- 编辑 `variables.env` 不需要 root
- 安装 Quadlet 到系统目录需要 sudo
- `systemctl daemon-reload`、启停服务需要 sudo
- 任何 `podman` 命令（`exec`/`ps`/`pull`）只要是操作这三个容器，都需要 `sudo`——rootful 和 rootless Podman 是两套独立的容器存储，普通用户不加 sudo 直接看不到这些容器

## 后续建议

如果你下一步继续实施，优先顺序建议是：

1. 先建好 `data/` 目录和 `variables.env`（含 invite token secret）
2. 用 `all` 或 `ss` 检查端口 `18437` 是否被占用
3. 安装四个 Quadlet 文件，`daemon-reload`
4. 先起 `mongo`，跑一次 `init_mongo_replica_set.sh`
5. 再起 `redis`、`overleaf`
6. 建第一个管理员账号，浏览器验证登录和编译
7. 后续按需邀请其他局域网用户
