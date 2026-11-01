# CI 与自动发布配置

这份文档说清楚三件事：**这套 CI 在干什么、你需要在 GitHub 上点哪些按钮、第一次跑大概率会在哪里翻车**。

---

## 一、这套 CI 现在做什么

| 什么时候跑 | 跑什么 | 产出 |
|---|---|---|
| 推送到 `main` / `dev`，且改动涉及 workflow、manager-next、kernel、userspace 等 | 完整构建 | Actions 里的 artifact（不发布） |
| 你在 Actions 页面手动点 "Run workflow" | 完整构建 | 同上，**不发版** |
| 打一个 `v*` 开头的 tag 并推送 | 完整构建 + 自动创建 Release | GitHub Releases 上的 APK 和内核模块 |

## 二、为什么构建链这么长

`ksud` 这个东西很特别：它会把**内核模块**和 **ksuinit** 直接嵌在自己身上，然后 `manager-next` 又要把 `ksud` 当成 `libksud.so` 打进 APK。所以顺序是死的，不能跳：

```
内核模块（8 个 KMI）  ┐
                      ├──→ ksud（arm64 + x86_64）──→ manager-next 的 APK
ksuinit               ┘
```

对应到 5 个 job：

1. `generate-key` —— 只有 PR 才真的干活（临时签名钥匙），平时空跑
2. `build-lkm` —— 用 DDK 编 8 个 KMI 的 `*_sevenk.ko`
3. `build-ksuinit` —— 编两个架构的 ksuinit
4. `build-ksud` —— 把上面两样嵌进去，编出 ksud
5. `build-manager` —— 把 ksud 塞进 `manager/app/src/main/jniLibs/`，再编 APK

> 顺带说明：这次改造后**不再需要 `repack_apk.py`**。旧流程是先编一个不带 ksud 的 APK，
> 再用 python 脚本把 ksud 塞进去重新签名；新流程直接在 gradle 编译前就把 `libksud.so`
> 放进 `jniLibs`，gradle 会自己合并进去并签名，少一道手工工序。

---

## 三、你需要做的配置（只能你在网页上点，我没有仓库写权限）

### 步骤 1：启用 Actions

fork 出来的仓库默认**不跑**任何 workflow。打开仓库页面：

- 如果顶部有一条黄色提示 "Workflows aren't being run on this forked repository"，点右边的
  **"I understand my workflows, go ahead and enable them"**
- 或者去 **Settings → Actions → General**，最上方确认没有处于 Disabled 状态

### 步骤 2：给 GITHUB_TOKEN 写权限

**Settings → Actions → General → Workflow permissions**

选 **"Read and write permissions"**，然后 **Save**。

不设这个，`release.yml` 最后一步创建 Release 会被拒绝（403）。

### 步骤 3：添加 4 个 Secret

**Settings → Secrets and variables → Actions → New repository secret**，逐个新建：

| 名称 | 值从哪来 |
|---|---|
| `KEYSTORE` | `D:/00_ME/001_Code/05_Kernel/7kimisu-signing/填入GitHub的密钥.txt` 里 "名称：KEYSTORE" 下面那一整段 |
| `KEYSTORE_PASSWORD` | 同一个文件 |
| `KEY_ALIAS` | 同一个文件（就是 `sevenk`） |
| `KEY_PASSWORD` | 同一个文件 |

⚠️ **`KEYSTORE` 是 2992 个字符的单行 base64**。粘贴时从 `MII` 开头一直到最后，中间不能有换行、不能有空格。粘贴框会自动换行显示，那是正常的。

### 步骤 4：核对签名库和内核指纹是否配套

这一步是"能不能用"的分水岭。内核把证书指纹编译期写死，两者必须来自同一把钥匙：

| 项目 | 值 |
|---|---|
| 签名库文件 | `7kimisu-signing/sevenk.jks` |
| 别名 | `sevenk` |
| 证书长度 | `0x037a`（890 字节） |
| 证书 SHA256 | `0c86c59ba97d998b51d4fc9627f1dd422bc1f8c43beef1ee65e8f6686a103a4a` |

这两个值已经写进 `kernel/Kbuild` 的 `KSU_EXPECTED_SIZE` / `KSU_EXPECTED_HASH`。

> 想自己复核：`keytool -exportcert -alias sevenk -keystore sevenk.jks -file c.der` 然后
> `sha256sum c.der`，结果应当与上表一致。

---

## 四、第一次怎么测

别急着打 tag，先空跑一次：

1. 把改动推到 `dev`
2. 打开仓库 **Actions** 页面 → 左侧点 **Build Manager** → 右上 **Run workflow** → 分支选 `dev` → 运行
3. 盯着 5 个 job 依次变绿
4. 全绿后点进这次 run，页面底部 **Artifacts** 里下载 `manager`，解压得到 APK
5. 用 `apkanalyzer` 或直接解压 APK，确认里面 `lib/arm64-v8a/libksud.so` 存在且不是 0 字节

第 5 步是关键：**没有 libksud.so 的 APK 能装但没 root 能力**，这是本次改造最容易静默出错的地方。

## 五、确认没问题了再发版

```bash
git tag v3.0.1
git push origin v3.0.1
```

推送后 `Release` workflow 会自动跑，产出：

- `7kimisu-next_v3.0.1_3000010-release.apk`
- 8 个 `lkm-aarch64-androidXX-X.X_sevenk.ko` / `lkm-x86_64-...`

---

## 六、我预判第一次会翻车的地方

这些点我在 Windows 上**无法本地验证**，第一次运行很可能需要调：

1. **SDK 组件名**。脚本里写的是 `platforms;android-37`、`build-tools;37.0.0`、`ndk;29.0.14206865`。
   如果 `sdkmanager` 报 "package not found"，用 `sdkmanager --list | grep android-37` 看实际名字。
2. **Action 版本号**。`checkout@v7`、`upload-artifact@v7`、`download-artifact@v8`、
   `setup-java@v6`、`gradle/actions/setup-gradle@v6` 都是仓库原有的写法，如果 GitHub 上不存在，
   job 会在第一步直接报 "Unable to resolve action"，改小一个版本即可。
3. **DDK 镜像版本** `20260828`（在 `ddk-lkm.yml` 里）。版本不存在会拉不到镜像。
4. **耗时**。8 个 KMI 的内核模块构建很慢，整条链路可能 30 分钟往上。公开仓库不消耗免费额度。
5. **`git describe`**。`manager-next/build.gradle.kts` 里定义了 `getGitDescribe()` 但**没有任何地方调用**，
   版本号默认是 `v3.0.0` / `3000000`，所以 CI 里没打 tag 也能编过。打 tag 时我用
   `-PKSU_VERSION_NAME=<tag>` 注入，保证 Release 上的版本号跟 tag 一致。

---

## 七、换签名库了怎么办

按顺序来，少一步都不行：

1. 生成新库 → 导出证书 → 算 `0x....` 长度和 sha256
2. 改 `kernel/Kbuild` 里那两行
3. 在 GitHub 上更新 4 个 Secret（base64 要重新生成）
4. 重新跑构建 —— **内核模块必须重编**，旧的 `.ko` 只认旧的证书

⚠️ **换签名库的代价**：Android 不允许签名不同的 APK 覆盖安装，老用户必须先卸载旧管理器
才能装新的。`/data/adb/sevenk` 里的数据不受影响，但应用内设置会重置。

⚠️ **本次换库的影响**：新内核（本次编出的 `.ko`）只信任新证书，**旧的 v2.30 APK 在新内核上会显示"未安装"**。
所以刷机顺序必须是：先刷新的 `.ko` → 再装新的 APK。反过来也没用，因为旧内核不认新 APK。
