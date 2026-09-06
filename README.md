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

- 绑定 `0.0.0.0:18437`（所有网络接口都能进来，包括本机 `127.0.0.1`，方便同机的 `cloudflared` 之类本地进程访问）；这本身不等于暴露到公网——是否对外，取决于路由器有没有做端口转发、有没有配 Cloudflare Tunnel 之类的东西指过来
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
- `overleaf` 发布到 `0.0.0.0:18437`（所有接口，见上面"端口与访问"一节）
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

首次启动 Overleaf 应用本身需要一点时间（初始化数据库索引、启动内部各个子服务等），日志里会有很多重试/迁移相关的输出，正常现象，不用一行行盯。判断"真的起来了没"，用它自带的健康检查接口更准：

```bash
curl http://192.168.3.11:18437/status
```

返回 `web is alive (web)` 就说明起来了，可以进行第 9 步；返回连接被拒绝/超时就是还没好，回去看 `journalctl -u overleaf -f` 里有没有报错。

### 8. 从局域网内测试访问

```text
http://192.168.3.11:18437
```

### 9. 创建第一个（管理员）账号

社区版是邀请制，没有公开注册页，第一个账号也要手动建。镜像里 `WORKDIR` 是 `/overleaf`（monorepo 根目录），但这个脚本在 `/overleaf/services/web/modules/...` 下面，所以要先 `cd services/web` 再跑，直接跑会报 `ERR_MODULE_NOT_FOUND`。第一个账号建议加 `--admin`，这样能登进后台管理面板：

```bash
sudo podman exec -it overleaf bash -c "cd services/web && node modules/server-ce-scripts/scripts/create-user.mjs --admin --email=你的邮箱@example.com"
```

**成功判据**：看到这样的输出就是成功了——

```
Successfully created 你的邮箱@example.com as an admin user.

Please visit the following URL to set a password for 你的邮箱@example.com and log in:

  http://192.168.3.11:18437/user/password/set?passwordResetToken=...
```

复制那个 `Please visit...` 后面的链接，去浏览器打开设置密码。之后邀请其他人（不加 `--admin`），同样用这个命令换个邮箱，或者登录后台 Admin Panel 里点 "New User"。

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

## 补充 TeX Live 包（缺 .sty 报错，比如 breakurl）

镜像里的 TeX Live 只装了 `scheme-basic`（省体积），碰到某些模板 `.cls` 要求的包没装上时会报类似这样的错：

```
! LaTeX Error: File 'breakurl.sty' not found.
```

解决办法：进容器用 `tlmgr` 补包，再把改动固化成新镜像，让 `overleaf.container` 指向它。

### 1. 进容器装包

```bash
sudo podman exec -it overleaf bash
```

```bash
# 推荐：一次装全套，以后少踩坑（几个 GB，装几分钟到十几分钟）
tlmgr install scheme-full
tlmgr path add
```

只想解决当前这一个报错，磁盘/带宽紧张的话：

```bash
tlmgr install breakurl
tlmgr path add
```

**注意**：每次 `tlmgr install` 之后都要执行 `tlmgr path add`，否则新装的东西不会正确链接进系统路径。装完 `exit` 退出容器。

### 2. 固化改动（必须做，否则下次重建容器就丢）

上面的改动只在 `overleaf` 容器的可写层里，`podman pull` 新镜像或者以后升级替换镜像时会被冲掉。用 `podman commit` 存成新镜像：

```bash
sudo podman commit overleaf localhost/overleaf-texlive-full:6.3.0
```

然后把 `quadlet/overleaf.container` 里的：

```
Image=docker.io/sharelatex/sharelatex:6.3.0
```

改成：

```
Image=localhost/overleaf-texlive-full:6.3.0
```

再应用并重启：

```bash
sudo install -m 0644 /home/hupenghui/Documents/overleaf/quadlet/overleaf.container /etc/containers/systemd/overleaf.container
sudo systemctl daemon-reload
sudo systemctl restart overleaf.service
```

`systemctl restart` 会按新的 `Image=` 重新创建容器，新装的包就在新容器里持续生效了。

### 3. 以后升级时要重做一遍

升级 Overleaf 版本（见上面「升级怎么做」）拉的是干净的官方镜像，之前装的包不会带过去。每次升级后要重复一遍「进容器装包 → `podman commit` → 改 `Image=`」。

### 4. `tlmgr install` 连不上 CTAN 时：走代理

这台机器如果只能通过 SSH 转发的代理上网（比如本机反向转发了一个 `7890` 端口），会遇到两层坑：

1. **SSH `-R` 远程转发默认只绑定服务器自己的回环地址**（`127.0.0.1` / `[::1]`），`sudo ss -tulpn | grep 7890` 能看到监听者是 `sshd` 而不是真正的代理进程。
2. 容器是独立网络命名空间，访问宿主机要用 Podman 提供的 `host.containers.internal`（解析到 `overleaf-net` 网桥的网关地址，比如 `10.89.2.1`），这个地址连不到宿主机的 `127.0.0.1:7890`。

解法：在宿主机上用 `socat` 搭一个中继，监听在网桥网关地址上，转发到宿主机自己的回环地址——这样只有 `overleaf-net` 里的容器能用到这个代理，不会把 7890 暴露给整个局域网：

```bash
# 查一下容器看到的网关地址（一般跟 host.containers.internal 解析结果一致）
sudo podman exec -it overleaf getent hosts host.containers.internal

# 装 socat（没有的话）
sudo apt-get install -y socat

# 起中继：把 <网关IP> 换成上一步查到的地址
sudo socat TCP-LISTEN:7890,bind=<网关IP>,fork,reuseaddr TCP:127.0.0.1:7890
```

新开一个终端测试连通性：

```bash
sudo podman exec -it overleaf curl -x http://host.containers.internal:7890 -I https://mirror.ctan.org
```

能返回状态码就说明通了，然后带着代理环境变量进容器装包：

```bash
sudo podman exec -it \
  -e http_proxy=http://host.containers.internal:7890 \
  -e https_proxy=http://host.containers.internal:7890 \
  overleaf bash

tlmgr install scheme-full
tlmgr path add
exit
```

装完把 socat 进程杀掉（临时中继，不需要常驻）：

```bash
sudo pkill -f 'socat TCP-LISTEN:7890'
```

不建议把代理配置长期写进 `overleaf.container` 的 `Environment=`——那样 Overleaf 应用本身所有对外请求（以后配的 SMTP、遥测等）也会被迫走代理，没必要为了偶尔装包背这个长期负担。

### 5. 另一种方式：直接让 sshd 支持 GatewayPorts（本机实际采用的方式）

上面第 4 步的 `socat` 中继是绕开限制的做法；也可以从根上解决——让 SSH 的 `-R` 远程转发本身就绑定到 `0.0.0.0`，不再局限于服务器的回环地址。

在服务器的 `/etc/ssh/sshd_config` 里加一行（或改已有的）：

```
GatewayPorts clientspecified
```

用 `clientspecified` 而不是 `yes`：`yes` 会让所有 `-R` 转发都强制绑定 `0.0.0.0`；`clientspecified` 则是由发起转发的一方（`ssh -R` 命令里）决定绑定地址，默认还是回环，只有显式写 `0.0.0.0:` 前缀时才对外开放——更保险，不会误伤其他你不想公开的转发端口。

改完重启 sshd：

```bash
sudo systemctl restart ssh
```

**注意服务名跟系统有关**：这台机器是 Ubuntu，systemd 单元名是 `ssh`（`systemctl status ssh` 能看到），不是 `sshd`——`sshd` 是 RHEL/CentOS/Fedora 那一系的叫法，在 Ubuntu 上直接 `systemctl restart sshd` 会报 `Unit sshd.service not found`。如果哪天换到别的发行版上部署，记得把这条命令换回 `sshd`。

然后在发起转发的那一端（运行实际代理软件的机器上），把原来的：

```bash
ssh -R 7890:127.0.0.1:7890 hupenghui@<服务器地址>
```

改成显式指定绑定地址：

```bash
ssh -R 0.0.0.0:7890:127.0.0.1:7890 hupenghui@<服务器地址>
```

重新连上之后再查一遍，应该能看到监听地址变成了 `0.0.0.0`：

```bash
sudo ss -tulpn | grep 7890
```

这样容器就能直接用宿主机的真实地址访问代理，不用再起 `socat` 中继：

```bash
sudo podman exec -it \
  -e http_proxy=http://host.containers.internal:7890 \
  -e https_proxy=http://host.containers.internal:7890 \
  overleaf bash
```

**权衡**：这种方式把 `7890` 端口暴露给了服务器的所有网络接口，包括局域网——比第 4 步 `socat` 只绑定到 `overleaf-net` 网桥网关（只有容器能访问）范围更大。如果这台服务器的局域网内还有不完全可信的设备，建议：

- 用防火墙（`ufw`/`nftables`）限制 `7890` 端口只允许来自 `localhost` 和容器网段（`overleaf-net` 的网段，一般是 `10.89.x.0/24`）的连接；或者
- 干脆继续用第 4 步的 `socat` 方案，不改 `sshd_config`——两种方式二选一即可，没必要同时开着。

### 6. 验证部署是否成功

`podman commit` + 改 `Image=` + 重启之后，别只看 `systemctl status` 是 `active` 就当成功了——换了底层镜像，容易在别的地方悄悄出问题。按下面几层由浅到深确认一遍：

**① 容器确实用上了新镜像**

```bash
sudo podman ps --filter name=overleaf --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"
```

`IMAGE` 列要显示新的 `localhost/overleaf-texlive-full:6.3.0`，不是旧的 `docker.io/sharelatex/sharelatex:6.3.0`。如果还是旧镜像，说明 `/etc/containers/systemd/overleaf.container` 没被真正覆盖，或者 `daemon-reload` 没跑，回去重新走一遍第 2 步。

**② 服务本身健康**

```bash
curl http://192.168.3.11:18437/status
```

应返回 `web is alive (web)`。不通就看日志：

```bash
journalctl -u overleaf -f
```

**③ 包确实装进了这个新容器**

```bash
sudo podman exec -it overleaf kpsewhich breakurl.sty
```

能打印出一个路径（如 `/usr/local/texlive/.../breakurl.sty`）说明包在；返回空说明 commit 的时候顺序不对，或者装错了容器。

**④ 真实编译回归测试（最关键，前三层都过了也不能跳过）**

1. 打开之前报 `breakurl.sty not found` 的那个项目，重新编译，确认不再报错、能正常出 PDF
2. **再测一个跟这次改动无关的普通项目**（比如空白默认模板），确认换镜像没有意外改坏别的东西——这一步最容易漏
3. 如果是多人协作的场景，找另一个账号也登录编译一次，排除只是自己浏览器缓存的假象

**⑤ 数据库层没受影响**

这次只换了 `overleaf` 容器，`mongo`/`redis` 不应该跟着重启过：

```bash
sudo podman ps --filter name=mongo --filter name=redis
```

两个容器的 `STATUS` 应该是持续 `Up`，没有最近才重启的痕迹（如果 `Up` 后面的时间比 `overleaf` 短很多，说明它们也被重启了，得回头查为什么）。

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
