# 自托管运行步骤

一台腾讯云 Lighthouse（Ubuntu 24.04）只跑这一套。域名在 Cloudflare 用灰云，只做 DNS。证书由 Caddy 自动签。

命令都在仓库根目录执行。示例里的用户名、库名、密码和 `deploy/.env.example` 的占位符一致。你改过 `.env` 的话，命令里的 `gojo` 一起改。

每条 `docker compose` 都带 `--project-directory deploy`。这样不管当前目录在哪，都会读 `deploy/.env` 里的 `SITE_DOMAIN`。

三个容器都不设时区，保持 UTC。不要自己加 `TZ`。后端是单个进程，不要加 worker，也不要换成 gunicorn。

## 1. 首次部署

安全组放行 80 和 443。然后：

```bash
git clone https://github.com/unreval/gojo_pub.git
cd gojo_pub
cp deploy/.env.example deploy/.env
```

编辑 `deploy/.env`，把 `change-me`、`SITE_DOMAIN` 和要用的 key 填上。`SITE_DOMAIN` 只写主机名。

```bash
docker compose --project-directory deploy -f deploy/docker-compose.yml up -d --build
```

看是否起来：

```bash
docker compose --project-directory deploy -f deploy/docker-compose.yml ps
docker compose --project-directory deploy -f deploy/docker-compose.yml logs app --tail 100
```

日志里应有这三行，且没有报错：

- `[diary_scheduler] 日记常驻排程已启动`
- `[proactive] 主动排程已启动`
- `[memory_jobs] worker 已启动`

浏览器或本机执行（把域名换成 `SITE_DOMAIN`）：

```bash
curl https://你的域名/health
```

应返回 `"status": "ok"`。

## 2. 从 Zeabur 迁数据

顺序不要换。先让 Zeabur 不再往库里写，再导出。

1. 停掉 Zeabur 上的 app 服务。数据库服务不要停。
2. 在 Zeabur 的数据库里执行下面两句，把结果记下来：

```sql
SELECT version();
SHOW timezone;
```

3. 在新服务器上导出。`<连接串>` 换成 Zeabur 数据库的连接串，两边的引号留着。这是二进制文件，不要用编辑器打开。

```bash
docker run --rm postgres:18-alpine pg_dump "<连接串>" -Fc > gojo.dump
```

18 的客户端可以导出更老的库。

4. 只启动数据库，等健康检查通过再继续：

```bash
docker compose --project-directory deploy -f deploy/docker-compose.yml up -d --wait db
```

5. 导入：

```bash
docker compose --project-directory deploy -f deploy/docker-compose.yml exec -T db pg_restore --no-owner --no-acl -U gojo -d gojo < gojo.dump
```

`pg_restore` 碰到无害警告时退出码也可能不是 0。先看输出，再做下一步的行数对照。

6. 新旧两边各跑一次精确行数，再看新库的时区。Zeabur 用它自己的 SQL 窗口。新库用：

```bash
docker compose --project-directory deploy -f deploy/docker-compose.yml exec -T db psql -U gojo -d gojo -c "SHOW timezone;"
docker compose --project-directory deploy -f deploy/docker-compose.yml exec -T db psql -U gojo -d gojo -c "SELECT c.relname AS table_name, (xpath('/row/n/text()', query_to_xml(format('SELECT count(*) AS n FROM %I', c.relname), false, true, '')))[1]::text::bigint AS rows FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace WHERE ns.nspname = 'public' AND c.relkind = 'r' ORDER BY 1;"
```

同一条 `query_to_xml` 语句也拿到 Zeabur 上执行。表名和行数要一致。

新库的 `SHOW timezone;` 应是 `UTC` 或 `Etc/UTC`。如果 Zeabur 记下来的不是 UTC，先不要启动 app，把两边的结果留下来再决定。`TIMESTAMP` 列不带时区，会话时区不同，新写入的 `CURRENT_TIMESTAMP` 会和旧数据差几个小时。

行数一致、时区也没问题之后，再启动全部：

```bash
docker compose --project-directory deploy -f deploy/docker-compose.yml up -d --build
```

app 启动时会把 `long_memory.content` 里以「用户」开头的文字替换成「她」。行数不变，正文会变。这是现有启动代码做的，不是导入损坏。

## 3. 日常更新

```bash
git pull
docker compose --project-directory deploy -f deploy/docker-compose.yml up -d --build app
```

`--build` 不能省。省了的话还是旧镜像，拉下来的代码不会进容器。

## 4. 改了 .env 之后

```bash
docker compose --project-directory deploy -f deploy/docker-compose.yml up -d
```

`docker compose restart` 不会重新读取 `.env`。要 `up -d`，让 Compose 按新环境重建容器。

## 5. 查日志和健康

```bash
docker compose --project-directory deploy -f deploy/docker-compose.yml logs app --tail 100
curl https://你的域名/health
```
