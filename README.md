# claudio

**跑在手机上的私有 AI Agent。**

claudio 把 Claude、GPT、Gemini 等模型装进原生移动应用，并给它一台真正能用的电脑：
设备上的完整 Linux 环境、浏览器自动化、可扩展技能、跨会话持久记忆，
以及对 iOS 系统的深度集成。

模型密钥完全由你自己提供，数据留在你的设备上——iCloud 同步与云端备份都由你开关。

---

## 核心能力

| 能力 | 说明 |
|---|---|
| **自带模型** | Claude / GPT / Gemini 等任意 provider，用自己的 API key 或账号登录。 |
| **真实 Linux 环境** | 设备上跑沙箱化的 Alpine Linux——agent 能装包、跑脚本、操作真实文件。 |
| **iOS 系统集成** | HealthKit、Calendar、Reminders、Contacts、HomeKit、Bluetooth、Clipboard、Media、Alarms 等，全部作为工具暴露给 agent。 |
| **浏览器自动化** | agent 替你浏览网页、点击交互、提取内容。 |
| **远端 Agent** | 手机作为终端，直连服务器上跑着的 Claude Code 会话——共享项目目录、推送消息、上传文件、实时看工具执行过程。 |
| **技能与记忆** | 可扩展的技能系统（`SKILL.md`）+ 跨会话持久记忆。 |
| **工作区** | 把工作组织成相互隔离的上下文，agent 可直接读写。 |
| **iCloud 同步与备份** | 会话、技能、记忆、配置多端同步；支持 rclone 远端备份。 |
| **细粒度权限** | 按工具逐项授权，agent 的每次外部调用都可审查。 |

---

## 远端 Agent

本地 agent 的能力受限于手机；claudio 额外支持**远端 agent**，把手机变成一台终端：

- **服务器上跑长任务**——会话常驻在服务器上，手机只管发消息、看结果，切后台也不会中断。
- **共享项目目录**——远端 agent 直接在服务器的项目目录里工作，改代码、跑测试、看 git 状态。
- **文件上传到项目**——手机里的图片、PDF、文档可以直接送进远端项目目录，让 agent 处理。
- **完整工具可见**——远端每一步工具调用、参数、结果都实时流式回传，思考过程一并展示。
- **会话可恢复**——杀掉 app 重进，历史消息和思考内容从服务器拉回，不丢上下文。

---

## 实际用法

人们在用 claudio 做的事情：

- **拍一顿饭，记进营养日志**——识别菜品、估算热量和宏量营养素，写入 Apple Health。
- **起床听到时间线**——Shortcuts 触发抓取社交平台时间线、做摘要、合成语音，作为闹钟播放。
- **把群聊变成任务**——拉 Telegram 群消息，提取 bug 和行动项、去重，写入 Apple Reminders。
- **挂载 Obsidian 库**——把 vault 当成普通工作区，让 agent 研究、清理、写回 Markdown 笔记。
- **分享任意内容到日历**——通过 iOS Share Sheet 把网页或消息发给 claudio，自动创建事件并填好时间和地点。
- **手机上改服务器代码**——远端 agent 连接项目目录，推送指令、上传文件、查看 diff，手机就是 Claude Code 的终端。

---

## 技能

一个**技能**就是一个带 `SKILL.md` 的目录——指令说明，可附带脚本、参考资料和素材。
agent 在请求匹配时按需加载：元数据常驻上下文用于触发，正文和捆绑资源只在技能真正被使用时读取。

claudio 有自己的工具系统，但**不要求技能专门为它编写**：为 Claude Code、Codex 等通用 agent
生态写的技能通常可以直接运行；针对 claudio 工具做过适配的技能效果更好——可以直接触达
Linux 环境、设备集成和原生能力。

---

## 从源码构建

claudio 内置 Linux 沙箱，原生依赖（iOS 侧 iSH、Android 侧 PRoot、FFmpeg、LAME）
和 Alpine rootfs 都是**从源码编译**的，不以二进制形式入库。首次构建预计 30–60 分钟，
之后产物有磁盘缓存，正常构建很快。

**→ 完整首次构建指南见 [BUILDING.md](BUILDING.md)。**

简要版：

```sh
git clone --recurse-submodules https://github.com/chenyynx/claudio.git
cd claudio

# iOS — 顺序有要求：FFmpeg 依赖 LAME
./deps/build_lame.sh && ./deps/build_ffmpeg.sh
./deps/build_ish.sh && ./deps/prepare_alpine_rootfs.sh
open src/ios/Minis.xcodeproj

# Android — 需要 NDK r28+
./deps/build_proot.sh && ./scripts/prepare_android_sandbox.sh
cd src/android && ./gradlew :app:assembleDebug
```

`BUILDING.md` 覆盖每个平台的具体工具链要求、构建期自定义模板，
以及一份针对最常见失败模式的排错章节。

---

## 仓库结构

```
src/ios/          iOS app（Swift / SwiftUI）+ share、widget、file-provider 扩展
src/android/      Android app（Kotlin / Compose）+ JNI 原生代码
src/shared/       双平台共享资源
deps/             原生依赖构建脚本与内置源码
docs/             设计与审计文档（含架构规格、设计决策记录）
scripts/          rootfs 准备与开发者工具
```

---

## 致谢

claudio 建立在大量开源工作之上。完整清单（含版本号与许可证条款）见
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)。感谢这些项目的维护者。

**沙箱**——产品的核心：

- **[iSH](https://github.com/ish-app/ish)**（GPLv3）——iOS 上的 Linux 用户态模拟。
- **[PRoot](https://github.com/termux/proot)**（GPLv2）——Android 沙箱的用户态 chroot，
  底层依赖 **[talloc](https://talloc.samba.org)**（LGPLv3+）。
- **[Alpine Linux](https://alpinelinux.org)**——沙箱启动所用的 minirootfs。

**多媒体与文本**——[FFmpeg](https://ffmpeg.org)（LGPL-2.1+）、
[LAME](https://lame.sourceforge.io)（LGPL）、
[cppjieba](https://github.com/yanyiwu/cppjieba)（MIT）、[KaTeX](https://katex.org)（MIT）。

**iOS**——[SwiftAnthropic](https://github.com/jamesrochabrun/SwiftAnthropic)、
[SwiftMath](https://github.com/mgriebling/SwiftMath)、
[RealTimeCutVADLibrary](https://github.com/helloooideeeeea/RealTimeCutVADLibrary)（均 MIT）、
[swift-cmark](https://github.com/swiftlang/swift-cmark)（BSD-2-Clause）、
以及 Apple / Swift Server Workgroup 系列包（Apache-2.0）。

**Android**——[AndroidX & Jetpack Compose](https://developer.android.com/jetpack)、
[OkHttp](https://square.github.io/okhttp/)、[Coil](https://coil-kt.github.io/coil/)、
[kotlinx](https://github.com/Kotlin) serialization 与 coroutines、
[multiplatform-markdown-renderer](https://github.com/mikepenz/multiplatform-markdown-renderer)、
[Reorderable](https://github.com/Calvin-LL/Reorderable)、[ACRA](https://github.com/ACRA/acra)
（均 Apache-2.0）、[Shizuku](https://github.com/RikkaApps/Shizuku-API)（MIT）。

---

## License

claudio 采用 **[GNU General Public License v3.0](LICENSE)** 许可。

app 链接了 GPL 许可的组件——iSH（GPLv3）与 PRoot（GPLv2）——因此合并作品按 GPLv3 分发。
捆绑的第三方许可证清单见 [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)。

---

## 社区

- **Issues**：bug 报告、功能请求与讨论走 [GitHub Issues](https://github.com/chenyynx/claudio/issues)

这个仓库是开发线的公开只读发布，**不接受 pull request**——没有可以合并的落点。
提 issue 是塑造这个产品最有效的方式。详见 [CONTRIBUTING.md](CONTRIBUTING.md)。
