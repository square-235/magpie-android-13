# 维护说明

仓库结构、上游同步、CI/CD 和发版规则。

## 仓库结构

| 目录 | 内容 |
| --- | --- |
| `upstream/` | magpie 上游源码，完全没有改动；当前版本记录在 `UPSTREAM_VERSION` |
| `android/` | 安卓工程，壳子代码在 `app/src/main/java/com/magpie/android/` |
| `scripts/` | 构建脚本：`build-magpie-android.*` 编译网关，`build-apk.*` 打 APK；`.sh` 另含上游同步和兼容检查 |
| `.github/workflows/` | GitHub Actions：PR 校验、自动发版、每天上游同步 |

`upstream/` 里没有任何本地改动，方便对比和跟进上游；上游的 `build/` 目录是源码的一部分
（图标生成器和 Windows/macOS 清单），要一起保留，仓库的 `.gitignore` 也不忽略它。
`sync-upstream.sh` 会整体替换 `upstream/` 并更新 `UPSTREAM_VERSION`，不要把上游的 `.git`
带进来。

## 修改应用

**想改支持的安卓版本** — 改 `android/app/build.gradle.kts`：`minSdk` 现在是 33
（Android 13）。壳子用了 API 33 的 `OnBackInvokedDispatcher` 和
`enableOnBackInvokedCallback`，33 是当前的下限；再往下要改返回键处理，并重新考虑前台服务
类型。`compileSdk`/`targetSdk` 仍是 36，要退回旧版本就一起改；网关侧同步改
`scripts/build-magpie-android.ps1` 的 `-ApiLevel` / `.sh` 的 `--api-level`。

插件用的 Bun 在 `android/app/src/main/jniLibs/<abi>/libmagpiebun.so`。

**想只编一个架构、或者加 32 位** — `-Abis` 支持 `arm64-v8a`、`armeabi-v7a`、`x86_64`、
`x86`，改完记得同步 `app/build.gradle.kts` 里的 `abiFilters`。

## 上游同步

平时交给每天的 `upstream-sync` workflow；本地也可以手动：

```bash
./scripts/sync-upstream.sh                 # 拉最新 release
./scripts/check-upstream-compat.sh         # 静态检查集成点
./scripts/build-apk.sh --abis arm64-v8a    # 真正构建
```

## CI/CD

仓库带三个用户可见的 GitHub Actions workflow，外加可复用、也可手动运行的 `build.yml`：

| 文件 | 触发 | 做什么 |
| --- | --- | --- |
| `.github/workflows/ci.yml` | PR、push `master`、手动 | **只做静态校验**：上游兼容性 + 版本接线；不构建 APK，不发 Release |
| `.github/workflows/build.yml` | `workflow_call`、手动 | 可复用构建；也可在 Actions 里手动运行，完整日志便于排查编译报错；默认上传 APK artifact，不发布 |
| `.github/workflows/release.yml` | 由 `upstream-sync` 成功后调用、手动 | 构建 release APK 并创建 GitHub Release |
| `.github/workflows/upstream-sync.yml` | 每天 03:17 UTC、手动 | 拉最新上游，建分支，静态检查 + Android 构建，成功自动合并并发版，失败发通知 |

真正的 APK 构建只在上游同步分支、Release 和手动 `build` 里跑，在 GitHub 的
`ubuntu-latest` 上完成：JDK 21、Go（版本读 `upstream/go.mod`）、Android SDK 36、
Build-Tools 36.0.0、NDK r28c，Gradle 用仓库自带的 wrapper。Gradle、Go modules 和 Bun zip
都有缓存，APK 以 artifact 形式上传。`ci.yml` 不占用构建时间。

### 版本规则

版本唯一来源是 `UPSTREAM_VERSION` 里的 `tag=`，例如 `v0.1.3532`。`v` 只是 tag 的符号
前缀，不进入数值版本字段：

| 位置 | 值 |
| --- | --- |
| Release tag | `v0.1.3532` |
| APK `versionName` | `0.1.3532` |
| APK `versionCode` | `major * 10000000 + minor * 1000000 + patch`，即 `1003532` |
| 网关 `--version` | `0.1.3532` |
| APK 文件名 | `magpie-android-0.1.3532-arm64-v8a.apk` |

CI 校验、上游同步分支构建和最终 Release 都从同一个 `UPSTREAM_VERSION` 取值，不写死
`1.0`，也不用日期或 run number 当版本号。`versionCode` 只取前三段数字，后缀（如
`-beta`）只保留在 `versionName` / tag 中。

### 上游同步的流程

1. 查询 `yetone/magpie` 最新 release，和 `UPSTREAM_VERSION` 比较
2. 有新版就整体替换 `upstream/`，提交到 `upstream/<tag>` 分支并推送
3. 跑 `scripts/check-upstream-compat.sh`，检查 CLI、环境变量、Bun 版本、手机端 CSS/JS 选择器
4. 用 `build.yml` 在该分支上真正编译 arm64 APK
5. 全部通过：自动开 PR 并 squash 合进 `master`
6. 合并成功后：调用 `release.yml`，从最新 `master` 重新构建 release APK 并创建 GitHub Release
7. 任一环节失败（含发版失败）：分支保留，自动开/更新带 `upstream-sync-failed` 标签的
   issue，并 @ 仓库 owner

定时任务统一是 **1 天一次**（每天 03:17 UTC）；GitHub 的 cron 可能因负载延迟几分钟到
几十分钟。

### 发版规则

- push `master`：只做静态校验，**不构建、不创建 Release**
- `upstream-sync` 成功合并后：自动创建 `v<上游版本>` 的 Release，例如 `v0.1.3532`
- 如果该 tag 的 Release 已存在，会覆盖上传 APK 和 `.sha256`，不再静默跳过
- 也可以在 Actions 里手动跑 `release` workflow 发一次版（取消 `release` 复选框则只构建）
- 资产里是 `magpie-android-<version>-arm64-v8a.apk`（version 不含 `v`）和同名 `.sha256`
- APK 使用本仓库统一的签名构建

### 仓库设置

- `Settings → Actions → General → Workflow permissions` 选 **Read and write
  permissions**，否则 `GITHUB_TOKEN` 不能建 Release、开 issue 或合并 PR
- 如果 `master` 开了分支保护，要允许 GitHub Actions 创建/合并 PR，否则第 5 步会失败并转成
  issue 通知
- 可选的 `NOTIFY_WEBHOOK` secret：填一个 Slack 风格的 webhook，失败时会额外 POST
  `{"text": "..."}`。不填也一定会开 GitHub issue

`upstream-sync` 用 `GITHUB_TOKEN` 创建的 PR 不会触发 `ci.yml`，所以它自己在同一条
workflow 里直接跑构建，不依赖 PR 的 check。