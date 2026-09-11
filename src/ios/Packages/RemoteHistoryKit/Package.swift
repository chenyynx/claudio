// swift-tools-version:5.10
import PackageDescription

// [G-3 2026-09-12] test-only 镜像包：Sources 全部 symlink 指回 app 源文件——
// 零复制、零漂移（改 app 文件=改包内文件，同一 inode 路径）。app target 不
// 依赖本包；本包只为 `swift test` 提供可独立编译的纯逻辑闭包（模型类型 +
// RemoteHistory 校准四件套），让单元测试门摆脱"装整个 App 进签名门禁设备"
// 的历史死结（Designed-for-iPad installd 0xe800801c/0xe8008014）。
let package = Package(
    name: "RemoteHistoryKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    targets: [
        .target(name: "RemoteHistoryKit"),
        .testTarget(name: "RemoteHistoryKitTests", dependencies: ["RemoteHistoryKit"]),
    ]
)
