# CertRelay

CertRelay（证书接力）：为 Traefik 提供轻量的证书、动态配置及通用目录分发与热加载。

项目目录为 `E:\work\code\cert-relay`，GitHub 仓库为 `vincywindy/cert-relay`。

## 多组源目录 → 目标目录

除了下文保留的证书校验/版本化模式，现在也支持任意文件的多目录对单向同步：

```yaml
environment:
  SYNC_MODE: folders
  SYNC_PAIRS: |
    /source/certs|/local/certs
    /source/dynamic|/local/dynamic
  SYNC_INTERVAL_SECS: "60"
  SYNC_MIN_AGE_SECS: "10"
  SYNC_RELOAD_FILE: /local/dynamic/tls.yml
```

目录模式使用 `cmp` 比较内容，跳过近期修改的源/目标文件，临时文件刷新后原子替换；证书变化后可触发指定现有动态配置的重载。它不解析业务文件，也不删除目标额外文件，保证单文件原子性，不保证跨文件事务。

完整说明见 [`FOLDER_SYNC.md`](FOLDER_SYNC.md)，Swarm 示例见 [`examples/folders-stack.yml`](examples/folders-stack.yml)。本来的 JSON `{name, cert, key}` 模式、证书配对校验和版本化发布继续保留。`SYNC_MODE` 默认为 `auto`：JSON 数组选择 `certificates`，`源|目标` 行格式选择 `folders`；也可显式指定。一个实例选择一种模式，目录模式本身就可以同时分发证书和配置。

下面的证书专用配置说明对应 `SYNC_MODE=certificates`。

基于 **`traefik:3.7.18`**，使用 shell 定时把统一 ACME 客户端签发的 PEM 证书从 NFS 复制到各节点本地，通过更新 Traefik File Provider 动态配置热加载。支持多组证书，不包含 ACME 签发功能。

```text
单实例 ACME 客户端 → NFS 证书目录（只读挂载到 Traefik 容器）
                         ↓ 每个节点独立定时拉取
              本地版本化证书目录 + 本地动态配置 → Traefik 热加载
```

## 保留原来的 Traefik 配置方式

镜像保留官方 `/entrypoint.sh`，通过 `"$@"` 原样传入原有参数，不拼接、不解析重写原有的 `command`，不覆盖 `TRAEFIK_*` 或业务环境变量。以下方式继续有效：

```yaml
command:
  - --entrypoints.web.address=:80
  - --entrypoints.websecure.address=:443
  # 这里保留你原来的其他参数
```

也支持 `command: ["traefik", "--configFile=/etc/traefik/traefik.yml"]`，或原有的纯 `TRAEFIK_*` 环境变量配置。Traefik 自身选择静态配置来源的规则不变，本项目不会合并 CLI、环境变量和配置文件中的静态配置。

`version`、`--help`、`healthcheck`、`sh` 等命令直接交给官方入口，不要求提供证书配置。`SYNC_ENABLED=false` 完全关闭同步，直接执行官方入口。

需要注意：

- 不要在 stack 中自定义 `entrypoint`，否则会绕过同步和进程管理。
- 若已配置 File Provider，保留原有配置，将 `SYNC_DYNAMIC_FILE` 放进其监听目录即可。原有路由、中间件等文件不会被修改。
- 若只配置了 `providers.file.filename`，需要自行切换成 `directory`，把原来的动态配置一起放入该目录。本程序不自动修改静态配置。
- 若尚未启用 File Provider，请在**当前使用的静态配置方式**中添加它；不要仅为了同步切换整个 Traefik 配置方式。
- 外部统一签发后，自行移除相应路由/入口的 `certResolver`、不再使用的 ACME resolver 和 `defaultGeneratedCert` 配置，避免 Traefik 继续申请证书。本镜像不会擅自删除原有参数。

CLI 示例：

```yaml
command:
  # 原有参数保留……
  - --providers.file.directory=/etc/traefik/dynamic
  - --providers.file.watch=true
```

静态 YAML 示例：

```yaml
providers:
  file:
    directory: /etc/traefik/dynamic
    watch: true
```

纯环境变量配置对应 `TRAEFIK_PROVIDERS_FILE_DIRECTORY` 和 `TRAEFIK_PROVIDERS_FILE_WATCH`。

## 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `SYNC_ENABLED` | `true` | `false`/`0` 关闭；`true`/`1` 开启 |
| `SYNC_PAIRS` | 必填 | JSON 数组，每组包含 `name`、`cert`、`key`，最多 256 组 |
| `SYNC_INTERVAL_SECS` | `300` | 一轮完成后等待的秒数；范围 1～31536000，不并发补跑 |
| `SYNC_MIN_AGE_SECS` | **`10`** | 源证书和私钥距离最后修改时间都必须达到此秒数；0 表示不等待，未来时间戳仍跳过 |
| `SYNC_IO_TIMEOUT_SECS` | `30` | 每组读取、复制、校验的执行时限；范围 1～86400，TERM 后最多再等 5 秒发送 KILL |
| `SYNC_MAX_FILE_BYTES` | `1048576` | 单个源文件大小上限，默认 1 MiB，最大 16 MiB |
| `SYNC_STATE_DIR` | `/var/lib/traefik-cert-sync` | **节点本地**状态和证书版本目录，必须可写 |
| `SYNC_DYNAMIC_FILE` | `/etc/traefik/dynamic/cert-sync.yml` | 专属生成文件，必须在 File Provider 监听目录内，以 `.yml`/`.yaml` 结尾 |

示例：

```yaml
environment:
  SYNC_PAIRS: >-
    [{"name":"example-com","cert":"/nfs-certs/example.com/fullchain.pem","key":"/nfs-certs/example.com/privkey.pem"},
     {"name":"example-net","cert":"/nfs-certs/example.net/fullchain.pem","key":"/nfs-certs/example.net/privkey.pem"}]
  SYNC_INTERVAL_SECS: "300"
  SYNC_MIN_AGE_SECS: "10"
```

`name` 是本地标识，不要求与域名一致，但必须唯一：1～64 个字母、数字、下划线或连字符，首字符必须是字母或数字。`cert`/`key` 使用容器内绝对路径，可以含空格，不能含控制字符或 `..` 路径段。证书使用包含中间证书的 `fullchain.pem`，私钥使用未加密 PEM；支持 RSA、EC 等 OpenSSL 可解析的密钥。不要把 `acme.json` 当作 PEM 输入。

## 发布和故障处理

1. 启动时立即同步，之后按间隔串行运行。证书和私钥分别检查默认 10 秒稳定期。
2. 每组复制到本地暂存目录，比较复制前后的 inode、大小、修改时间和状态变更时间。源文件变化则丢弃候选。
3. 使用 `cmp -s` 比较候选与本地当前版本。内容相同时不计算摘要、不重新运行 OpenSSL、不更新动态配置。
4. 发生变化时，检查 PEM 证书链可解析、叶证书未过期、私钥有效、证书和私钥的公钥一致。校验是格式/有效期/配对检查，不代替 CA 信任链验证。
5. 将这一对文件放入独立版本目录，生成所有组的完整 `tls.certificates` 配置，最后在动态配置所在目录原子重命名替换生成文件。

配置文件采用 JSON 语法的 YAML，Traefik 可以直接读取；使用 JSON 序列化可正确处理路径中的引号等字符。仅修改 `SYNC_DYNAMIC_FILE`，不要把它设置为已有的路由配置文件。

**异常时保留当前版本：** 某组源不可读、不稳定、超时或校验失败，会记录原因，继续使用该组上一份本地副本，其他已有组仍可更新。任何配置中的组如果从未成功初始化，则整份动态配置暂不替换；首次启动会失败，交给 Swarm 重试，避免在缺证书的情况下悄悄启动。

移除 `SYNC_PAIRS` 中某一组会在下一次完整发布时移除其动态条目，不自动删除历史文件。空数组不允许；若要关闭所有同步，设置 `SYNC_ENABLED=false`，并根据需要手动移除生成的动态配置。

历史版本刻意保留，避免 Traefik 异步加载期间读到已删除文件，也便于排查和回退。证书通常体积很小、续签频率低；如需清理，应先停同步服务，仅删除确认未被动态配置和各组 `current` 引用的版本。异常断电留下的 `.stage.*`/`.round.*` 可在服务停止后清理。原子重命名保证正常运行时的完整发布，不承诺机器掉电时整个多文件事务持久化。

旧副本在 NFS 故障期间仍可服务，但不会延长其有效期，应继续监控实际对外证书到期时间。10 秒稳定期不是写入事务：最好由 ACME 客户端的成功部署钩子发布完整证书组，避免长时间停在更新一半的状态。

## NFS 和权限

- NFS 仅作为**源**，只读挂载；不在 NFS 上加锁，也不依赖远程文件通知。
- `SYNC_STATE_DIR` 和动态配置目录必须放在**各节点本地磁盘/本地 Docker volume**。不要让多节点共享这两个输出目录。
- 动态配置必须挂载整个父目录，不能单文件 bind mount。Traefik 监听父目录，才能收到替换文件产生的事件。
- 支持源证书软链接（如 Certbot 的 `live → archive`）；挂载范围必须覆盖软链接实际指向的文件。
- 私钥、配置和状态文件默认只允许当前用户访问；同步和 Traefik 使用同一容器用户。使用非 root `user:` 时，应预先配置本地目录和源文件的 UID/GID 权限。
- NFS `root_squash`、ACL 或读权限错误会跳过该组。确保运行用户实际有权读取私钥。
- 本地 `flock` 防止同时执行的同步轮次互相覆盖。一个本地输出目录只供一个 Traefik 任务使用。
- NFS `hard` 挂载发生内核不可中断 I/O 时，用户态 `timeout`/SIGKILL 不保证立即生效；服务端和挂载可用性仍需运维保障，脚本不能修复失联挂载。

## Swarm 部署

完整示例见 [`examples/stack.yml`](examples/stack.yml)。示例采用 host 模式发布 80/443、每个符合条件的 manager 节点运行一份；这与 `network_mode: host` 是两回事。若原部署已正确获取客户端 IP，保留原有网络方式即可。

在所有准备运行 Traefik 的节点上：

```sh
# /mnt/acme-certs 已通过系统配置挂载 NFS。
mkdir -p /var/lib/traefik-cert-sync /etc/traefik/dynamic
```

在 manager 上：

```sh
docker network create --driver overlay --attachable proxy
docker node update --label-add traefik=true YOUR_MANAGER_NODE

# 使用实际 GitHub 仓库对应的镜像路径；私有 GHCR 镜像先 docker login ghcr.io。
export TRAEFIK_SYNC_IMAGE=ghcr.io/vincywindy/cert-relay:12345678901
docker stack deploy --with-registry-auth -c examples/stack.yml edge
docker service logs -f edge_traefik
```

如果 `proxy` 网络已经存在，跳过创建。编辑示例中的域名证书路径、节点标签、网络名和镜像名。示例为 manager 约束，因为它直接使用本机 Docker socket 查询 Swarm；若现有部署使用远程 API/socket proxy，沿用原配置和相应 placement。

host 端口同节点不能被新旧任务同时占用，因此示例使用 `stop-first`、一次更新一个节点。不要对每个节点的动态配置目录挂只读卷或不可变 Docker Config；脚本需要写入自己的生成文件。原有其他动态文件可继续放在该目录中。

## 构建和 GitHub Actions

本地构建：

```sh
docker build -t cert-relay:3.7.18 .
docker run --rm cert-relay:3.7.18 version
```

默认底包精确为 `traefik:3.7.18`，也可显式传 `--build-arg TRAEFIK_IMAGE=...`。升级底包需重新验证入口和热加载行为；当前容器集成测试检查版本 3.7.18。

[`.github/workflows/container.yml`](.github/workflows/container.yml) 包含：

- PR、`main`/`master` 推送、`v*` 标签及手动运行触发。
- ShellCheck、在实际 Alpine 镜像中执行行为测试、启动真实 Traefik 验证 CLI/环境变量/静态配置文件兼容、TLS 证书热加载、信号退出和同步进程故障退出。
- 检查通过后构建 `linux/amd64`、`linux/arm64`，非 PR 推送到 `ghcr.io/<仓库所有者>/<仓库名>`，使用自动提供的 `GITHUB_TOKEN`，不需要自建仓库密码 secret。
- 镜像仅使用 GitHub build/run ID：`ghcr.io/vincywindy/cert-relay:${{ github.run_id }}`。不再发布 `latest`、分支或 semver 标签；同一 run 重试沿用同一个 ID。PR 只构建，不推送。

仓库需要允许 workflow 写入 Packages。新建的 GHCR 包可能是私有的，Swarm 节点需登录或自行将包改为公开。项目只提供工作流，不会自动创建 GitHub 仓库或执行发布。

## 验证和排障

Linux/Docker 上执行完整测试：

```sh
shellcheck scripts/*.sh tests/*.sh
docker build -t cert-relay:test .
docker run --rm --entrypoint /bin/sh -v "$PWD/tests:/tests:ro" \
  cert-relay:test /tests/sync.sh /usr/local/bin/cert-sync
python3 tests/container.py cert-relay:test
docker stack config -c examples/stack.yml
```

Windows 安装了 WSLC 时，也可以用 `wslc build -t cert-relay:test .` 构建，再执行
`python tests/container.py --runtime wslc cert-relay:test`。该测试使用临时 Linux volume，不依赖 Windows 文件系统提供文件监听，结束后清理测试容器和 volume。

单独手动触发一轮（容器名替换为实际 task container）：

```sh
docker exec YOUR_CONTAINER /usr/local/bin/cert-sync --once
```

退出码：`0` 成功，`2` 某些组跳过但旧版本可用，`1` 存在没有本地版本的组或发布失败，`64` 配置无效，`75` 本地同步锁冲突。手工触发与后台轮次撞锁时，等待后重试即可。

日志以 `cert-sync:` 开头，不输出私钥内容。Traefik 日志和原有日志级别保持不变。需要确认热加载结果时，使用域名 SNI 检查对外证书：

```sh
openssl s_client -connect YOUR_NODE_IP:443 -servername example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -serial -dates
```

容器使用 `tini` 和一个 shell supervisor：转发 TERM/INT、回收子进程；Traefik 或同步循环意外退出时停止整个容器，交给 Swarm 重启。启动后的单组读写失败不会停止代理。脚本不会另加健康检查覆盖你的原有定义；示例的 ping 检查仅检查 Traefik，不证明证书续签成功。

资源方面：空闲时只有休眠和阻塞等待，没有忙轮询；同一时间只处理一组证书，未变化时不运行 OpenSSL，不维护全目录文件索引。证书较小时，默认 300 秒间隔足够低开销；实际 CPU/RSS 包含 Traefik 流量处理，应在你的节点上测量，不预设统一的资源上限。

## 参考

- [Traefik File Provider：目录监听及 bind mount 限制](https://doc.traefik.io/traefik/providers/file/)
- [Traefik 动态 TLS 证书配置](https://doc.traefik.io/traefik/reference/routing-configuration/http/tls/tls-certificates/)
- [fsnotify：NFS 不提供远程文件变更通知](https://github.com/fsnotify/fsnotify/blob/main/README.md)
- [Docker 官方 GitHub Actions](https://docs.docker.com/build/ci/github-actions/)
