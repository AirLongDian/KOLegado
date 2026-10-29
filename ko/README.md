# 阅读D / KOReader 最小集成

同一个 APK、同一个进程。阅读保留书架、书源、搜索、目录、下载缓存；阅读界面替换为 KOReader 2022.06 的 ReaderUI / CREngine / BlitBuffer / Android NativeActivity 路径。

本版显示名称及 APK 文件名为“K源阅O”，Android 技术包 ID 为 `io.legado.app.kotest`。它不覆盖现有的正式阅读或阅读D；实机测试结束后仅清除本包的临时测试数据，勿删除原应用的数据目录。

## 边界

- 原有 `book_cache/<book>/<chapter>.nb` 直接传文件路径给 KO，无 EPUB/HTML 导出、无章节副本。
- 当前范围是文字网文及其已有离线缓存。未缓存的本地 TXT/EPUB 分章和图文正文的远程图片映射尚未接入，不宣称支持。
- 当前章只保留一个 KO 文档，预取下一章沿用阅读自己的缓存。
- KO 文档页缓存预算为 8–16 MiB，保留原预绘逻辑；这不是整个应用的 RAM 占用承诺，实际总占用待实机测量。
- 位置按章节索引 + 章内百分比保存。旧字符偏移不直接当百分比使用，首次迁移从该章开头开始。
- 不生成每章 `.sdr`、历史记录或 CREngine 磁盘缓存。KO 仅有安装所需的代码/字体/库及少量全局设置、字体索引。
- KO 书库、历史、文件管理的依赖先保留，但菜单不提供入口；所有文件管理回退路径返回阅读书架。
- 保留 KO 插件及其管理菜单；不运行第二个 APK、子进程或本地 HTTP 服务。
- 旧阅读器源码与之前的用户修改仍留在工作树中，但由 Java/Kotlin 源集排除，不进入此 APK。旧文字朗读服务同时排除。

## 核心改动

- `app/src/main/java/io/legado/app/ko/KoChapterAdapter.kt`：缓存路径、网络加载、切章、位置。
- `app/src/main/java/io/legado/app/ko/ReadBookActivity.kt`：旧 Activity 名字的新 NativeActivity 实现及 JNI host API。
- `ko/legado.lua`：轻量入口、章边界桥接、关闭文件管理、禁止多余磁盘状态。
- `app/src/main/cpp/main.c`：Android 19 启动器；结束 Lua 后关闭 Activity，不退出整个阅读进程。
- 原生渲染库不改。`tools/prepare-ko.ps1` 重打运行包并编译启动器。

## 构建

使用 JDK 11、Android SDK 30 / build-tools 30.0.3。原生启动器使用 NDK r23c / armeabi-v7a / API 19。

第一次准备：从已在设备实测过的 KOReader 2022.06 APK 提取 `assets/*` 与 `lib/armeabi-v7a/libluajit.so` 至 `work/koreader-donor`，再将 `assets/module/koreader.7z` 解至 `work/koreader-runtime`。解包目录和 SDK 都仅在电脑上。

```powershell
./tools/prepare-ko.ps1 -Ndk 'C:/path/to/android-ndk-r23c'
./gradlew.bat :app:assembleAppDebug --max-workers=4
```

打好的 `app/src/main/assets/ko-runtime.zip` 与原生库可直接复用；只有修改 Lua/启动器时才需要运行准备脚本。

本测试构建输出至 `work/build-ko/outputs/apk/app/debug/`，不会清理或改写原 `app/build/outputs/` 中的阅读D安装包。

## 验证范围

`ko/tests/bridge_test.lua` 是 host-side LuaJIT 桥接契约测试，不等同 Kindle 实机验收。

`python tools/check-ko-apk.py <APK路径>` 只读检查实际 DEX：NativeActivity 继承、JNI 方法签名、旧阅读器/朗读类排除、ARMv7 库、运行包哈希与授权文件。它也不能代替设备启动和翻页测试。

设备验收项：缓存章打开、连续翻页、前后切章、目录跳章、退出重开恢复百分比、反复开关不退出书架、离线已缓存章节、断网报错返回、所有文件管理入口不可达，以及实际 RAM/磁盘增量。未连接设备时不能承诺这些实测通过或翻页达到 KOReader 的实际速度。

## 上游

- KOReader runtime: <https://github.com/koreader/koreader/tree/v2022.06>
- Android launcher/glue: <https://github.com/koreader/android-luajit-launcher/tree/4321d0a1d75d7635c80afeb8b7c50a365d516c91>
- KO base bindings: `8a8722a491ed7897bb8eaa0c2e9e8c05b54e1104`；CREngine: `c66fd65a3dbc0129c8885cbd9359ec08adb8a911`。
- 本次使用之前从 Kindle 备份的 `koreader-installed-v2022.06.apk` 作为二进制来源。各字体授权随运行包保留；原有 Java/Lua/C 文件版权标头保留。
