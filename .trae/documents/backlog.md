# Backlog

Unfinished engineering tasks. Completed items are deleted (git history is the archive).

来源标记：`[安全评审 round3 2026-10-31]` 指 devbie 仓 `.trae/documents/expert-review-2026-10-31-round3.md`（已入库）。本仓条目由 2026-11-02 二次取证拆 ID 入账，剔除误报后 open。

## P2（安全评审 round3，模板/ops 主题）

- [ ] `[R3-G4-1]` **P2** 备份脚本口令进 argv：`deploy/scripts/backup.sh` L122-124（mongodump uri 含密码）、L139-143（redis-cli `-a`）、L171-173。
- [ ] `[R3-G4-2]` **P2** 明文 dump 落盘、7 天保留：`deploy/scripts/backup.sh` L40-41 写宿主机 `backup-tmp`，L208 `-mtime +7` 才删。
- [ ] `[R3-G4-3]` **P2** render-env 用 `jq join` / `sed` 拼 Secret，未转义换行与 `|`：`deploy/scripts/render-env.sh` L38-39、L73-76。
- [ ] `[R3-G4-4]` **P2** 两条备份告警通道均 `|| true`：`deploy/scripts/backup.sh` L68-69（manifest 上传吞错）、L79-81（BackupFailure 指标吞错）；双通道同时失败即静默。
- [ ] `[R3-G4-5]` **P2** 模板仓无 Dockerfile：仓根无 Dockerfile，镜像构建契约无物承载；同 fewbie-starter。
- [ ] `[R3-G4-6]` **P2** 模板零测试：`package.json` 无 test 脚本，`src` 下无 `.test`/`.spec` 文件；同 fewbie-starter。

## 治理残余（2026-11-02 复核）

- [ ] `.github/workflows/ci.yml` 已有 `concurrency`，仍无 `timeout-minutes`。
