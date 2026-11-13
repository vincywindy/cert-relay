# CertRelay：通用多目录同步模式

这是 CertRelay 的 `SYNC_MODE=folders` 使用说明。原有证书校验/版本化模式见 `README.md`，两种模式都保留官方 Traefik 参数和诊断命令入口。

基于 Traefik 的容器，用 Bash + 系统工具定时同步多组「源目录 → 目标目录」。适合统一 ACME 签发后，把 NFS 上的证书和动态配置分发到各 Swarm 节点本地，并触发 Traefik 热加载。同步器也可以独立运行，不限定文件类型。

## 行为

- 递归、单向、新增和覆盖；**不删除**目标多出的文件，不跟随符号链接，也不复制设备、FIFO、socket。
- 默认每轮结束后等待 60 秒，启动立即执行；只有一个同步工作进程，不重叠扫描。
- 源文件或目标文件最后修改距当前不足 **10 秒**，以及时间在未来的文件，跳过，下一轮重试。
- 默认 `cmp -s` 内容比较：分块读取，发现不同即停止，不把整个文件读进内存。`metadata` 模式只比较大小及修改时间。
- 写入目标同目录的随机临时文件，刷新到文件系统，检查源和目标状态未变后原子重命名。单文件异常不终止其他文件或目录对。
- 文件名可含空格和中文。根路径不可含 `|` 或换行；树内带换行的文件跳过。`.folder-sync-*` 是保留前缀。
- 支持普通挂载路径，包括 NFS。程序不挂载 NFS，不要求 NFS 文件锁服务。并发工作进程锁放在本地 `/run`。
- 保留文件修改时间；新文件权限为 `0600`，新目录通常为 `0700`，不复制属主、ACL、扩展属性或源权限。镜像内 Traefik 和同步器以同一 UID 运行。共享给其他用户时需自行安排访问权限。

## 配置

`SYNC_PAIRS` 每行一对绝对路径，使用 `|` 分隔，按顺序处理。例如：

```yaml
environment:
  SYNC_MODE: folders
  SYNC_PAIRS: |
    /source/certs|/local/certs
    /source/dynamic|/local/dynamic
    /source/extra|/local/extra
  SYNC_INTERVAL_SECS: "60"
  SYNC_MIN_AGE_SECS: "10"
  SYNC_RELOAD_FILE: /local/dynamic/tls.yml
```

| 环境变量 | 默认值 | 说明 |
| --- | --- | --- |
| `SYNC_MODE` | `auto` | 建议显式设为 `folders`；自动模式也能识别行格式 |
| `SYNC_PAIRS` | 必填 | 一行一个 `源绝对目录\|目标绝对目录`，最多 256 对 |
| `SYNC_INTERVAL_SECS` | `60` | 一轮完成到下一轮的等待秒数，至少 1 |
| `SYNC_MIN_AGE_SECS` | `10` | 源/目标文件的最短稳定时间；0 关闭年龄限制，未来时间仍跳过 |
| `SYNC_COMPARE` | `content` | `content` 精确内容比较，或 `metadata` 大小＋mtime |
| `SYNC_RELOAD_FILE` | 空 | 有文件更新后，原子重写此现有动态配置以触发监听；内容保持不变 |
| `SYNC_IO_TIMEOUT_SECS` | `30` | 单次比较、复制、刷新等工具的超时；大文件/慢 NFS 应调大 |
| `SYNC_FILE_DELAY_MS` | `0` | 每个常规文件处理后的额外等待，降低扫描瞬间压力 |
| `SYNC_MAX_DEPTH` | `128` | 相对路径最大组件数；超出跳过，限制遍历资源 |
| `SYNC_LOG_LIMIT` | `20` | 每轮最多打印多少条异常/跳过详情；总数仍汇总 |
| `SYNC_STATE_DIR` | `/run/folder-sync` | 本地工作锁、心跳和待重载标记；不得与同步目录重叠 |
| `SYNC_HEALTH_GRACE_SECS` | `300` | 目录模式健康检查允许的额外无进展时间，按最长扫描耗时调整 |

`examples/folders-stack.yml` 配置了 `/usr/local/bin/folder-sync-healthcheck`，检查目录 worker、Traefik 存活及扫描进展。镜像没有全局强制此检查，以兼容旧证书模式；自行编写部署配置时按需添加此 healthcheck。

目录对不能嵌套或相互反馈：任何目标都不能与任何源重叠，目标之间也不能重叠。源目录可以暂时不可用，记录错误后继续其他目录对，下一轮再试。现存路径中的符号链接不支持；ACME 工具应导出真正的 PEM 文件，而不是直接同步 Certbot `live/` 中的符号链接。

## 构建与运行

```sh
# 默认基于 traefik:3.7.18，也可通过 TRAEFIK_IMAGE 显式指定其他 Alpine 版本。
docker build -t cert-relay:local .

# 先创建本地目录，并在 NFS 发布目录准备 certs/ 和 dynamic/tls.yml。
mkdir -p /var/lib/traefik-sync
docker run -d --name cert-relay \
  -p 80:80 -p 443:443 \
  -v /mnt/acme-publish:/source:ro \
  -v /var/lib/traefik-sync:/local \
  -e 'SYNC_PAIRS=/source/certs|/local/certs
/source/dynamic|/local/dynamic' \
  -e SYNC_RELOAD_FILE=/local/dynamic/tls.yml \
  cert-relay:local \
  --entrypoints.web.address=:80 \
  --entrypoints.websecure.address=:443 \
  --providers.file.directory=/local/dynamic \
  --providers.file.watch=true
```

`examples/folders-stack.yml` 提供 Swarm `global` + `mode: host` 端口发布示例。各节点自行挂载 NFS，`/var/lib/traefik-sync` 必须是**该节点本地存储**。不要把本地目标又挂回同一个 NFS 目录；不同挂载点可能指向同一数据，普通路径重叠检测无法识别这种别名。

挂载整个目录，不要单独 bind mount 动态配置文件。动态配置放本地，Traefik 文件提供器监听 `/local/dynamic`。NFS 的远端更新不能依赖 fsnotify 通知，轮询复制到本地才产生可靠的本机文件事件。

`SYNC_RELOAD_FILE` 需指向 Traefik 实际读取的 `.yml`/`.yaml`/`.toml` 文件，如示例 `tls.yml`。只更新 PEM 时，脚本也会原子重写该配置，让文件提供器重新读取证书。没有变化不会重载。重载请求失败会保存标记并重试。程序记录的是“重载已请求”，不是 Traefik 已接受配置；配置语法和证书是否有效需要检查 Traefik 日志或实际 HTTPS 握手。

动态配置只对支持热更新的设置生效；静态配置如 entrypoints 仍需重启 Traefik。使用外部证书时移除相应的 `certResolver` 引用，避免各实例重新参与 ACME 签发。

## 只使用同步器

```sh
# 若另行配置了 Traefik 健康检查，独立同步时应关闭。
docker run --rm --no-healthcheck \
  -v /host/source:/source:ro -v /host/target:/target \
  -e 'SYNC_PAIRS=/source|/target' \
  cert-relay:local sync-once
```

支持 `sync-only` 持续同步、`sync-once` 执行一轮、`sync-check` 检查配置。`sync-check` 也会获取工作锁；不要与同一状态目录的工作进程并发执行。单轮退出码：0 全部处理成功，1 配置/启动失败，2 存在跳过或失败。持续模式遇到单文件失败继续运行。

## 一致性与异常边界

**通用目录同步只保证单文件原子发布，不保证多个文件或多个目录对的事务。** 10 秒稳定期是避免复制正在编辑文件的启发式条件，不是“文件没有被占用”的证明；长期打开但未修改的文件仍可同步。复制前后检查 inode、大小、mtime、ctime，可以发现常见并发改动，但不能代替源端发布协议，也不能防止恶意并发替换目录。

证书链、私钥和引用它们的配置存在关联时，建议源端发布为不可变版本：先发布 `/certs/releases/v002/` 中的完整文件，等待节点同步，再更新动态配置引用新路径。本项目不会验证或改写业务 YAML，不会校验证书和私钥是否配对，也不会根据扩展名改变同步逻辑。即使按证书目录在前、配置目录在后的顺序配置，跳过或失败也意味着它不是跨目录事务；需要强一致发布时应增加明确的版本清单/就绪协议，而不是只依赖处理顺序。

对于非法新配置，保留源端可回滚版本并查看 Traefik 日志；不要把“文件复制成功”当成“应用配置成功”。目标额外文件保留，因此删除路由建议编辑现有 YAML 移除条目；直接从源端删除整个 YAML 不会删除目标文件，也不会撤销相应路由。

NFS 目标允许写入和同目录 rename；但供 Traefik 监听的目标应使用本地磁盘。NFS 属性缓存可能延迟发现更新，服务端宕机可能让内核 I/O 进入不可中断等待，此时 shell timeout 也不能保证即时中止。健康检查会检测长期无进展。普通 I/O 错误保留原目标，重命名后遇到网络错误的结果可能不确定，下轮以实际文件内容为准。

正常异常/退出清理临时文件；断电、SIGKILL 或 NFS 故障可能残留 `.folder-sync-tmp.*`，确认没有同步进程后可人工清理。不要在运行中删除本地工作锁。一个目标只安排一个写入实例；跨容器必须共享本地 `SYNC_STATE_DIR` 才能互斥，不提供分布式锁。

## 资源

不使用全量内存索引、摘要数据库或并行复制；文件列表由 `find` 流式输出，内容交由 `cmp`/`cp` 分块处理。常驻为 shell 工作进程、信号/子进程管理和 Traefik，空闲时阻塞休眠。目录模式不调用 OpenSSL；镜像保留 OpenSSL 供原有证书校验模式使用。

内容模式每轮需要读取两边的同大小文件，这是精确比较的 I/O 成本。证书及少量 YAML 通常很小；如果文件数或体积很大，可增大间隔，或选择 `metadata`。后者会漏掉大小和修改时间均不变的内容修改。Shell 为每个文件启动若干短命系统工具，文件特别多时原生程序会更高效；本项目以当前证书/配置分发场景的简单可维护为目标。

本地验证样本（2026-11-13，WSLC、Traefik v3、单个小配置、无代理流量）：空闲同步 worker 的 `/proc/<pid>/status` 显示 RSS 约 2.5 MiB，WSLC 容器 CPU 快照为 0.00%。worker 数字不包括监督 shell、Traefik 或页缓存，也不是大目录/真实流量的基准。

## GitHub Actions

推送 `main`/`master`、`v*` 标签或手动运行 `.github/workflows/container.yml`，先测试，再构建并推送 GHCR 镜像；PR 只测试/构建，不推送。支持 `linux/amd64` 和 `linux/arm64`。

**唯一镜像标签采用 `${{ github.run_number }}`（此 workflow 在 Actions 页面上的 `#1`、`#2` 运行序号）**：

```text
ghcr.io/vincywindy/cert-relay:1
ghcr.io/vincywindy/cert-relay:2
```

不额外发布 `latest` 或分支标签。同一次运行重试会覆盖同一个序号标签。PR 只构建、不推送，但也占用序号，因此已发布标签可能不连续。使用仓库自带 `GITHUB_TOKEN` 和 `packages: write`。底包版本由 Dockerfile 的 `TRAEFIK_IMAGE` 默认值控制，本地构建也可覆盖此 build arg。工作流成功后在 Summary 查看完整镜像名，并更新 stack 中的运行序号。

## 测试

```sh
bash tests/folders.sh
docker build -t cert-relay:test .
docker run --rm --entrypoint /bin/bash -v "$PWD:/project:ro" cert-relay:test /project/tests/folders.sh
docker run --rm --entrypoint /bin/sh -v "$PWD:/project:ro" cert-relay:test \
  -c 'apk add --no-cache curl >/dev/null && bash /project/tests/folder-reload.sh'
```

集成测试覆盖多目录、稳定期、未来时间、内容/元数据比较、符号链接/FIFO、复制失败、复制期间源修改、重载重试、互斥和退出。Traefik 测试验证真实 TLS 握手返回新证书序列号、HTTP 路由从旧路径切到新路径以及进程正常退出。NFS 故障/缓存语义还需在实际挂载环境中验证。

参考：[Traefik 文件监听](https://doc.traefik.io/traefik/providers/file/)、[动态 TLS 证书](https://doc.traefik.io/traefik/reference/routing-configuration/http/tls/tls-certificates/)、[fsnotify 的 NFS 限制](https://github.com/fsnotify/fsnotify/blob/main/README.md)。
