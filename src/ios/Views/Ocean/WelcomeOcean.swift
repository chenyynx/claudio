import SwiftUI

// MARK: - 欢迎页深海版组件（设计稿 welcome-page-v7.html 定稿，2026-09-07 pp 拍板）
// 呈现层组件：品牌行 / hero / 玻璃路径卡 / 开始对话条。
// 数据与动作链路由调用方（ContentView.emptyState）注入——0 原则：只换皮不换链路。

/// 品牌行：幽灵剪影 + Claudio + HARNESS 徽章 + 右上两圆钮（齿轮=设置 / 终端=工具）。
/// 幽灵剪影与 dsh-mobile 的鲸鱼同位同用法（Image template 上色）。
struct WelcomeBrandBar: View {
    var onSettings: () -> Void
    var onTools: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image("GhostMark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
                .foregroundStyle(.white)
                .accessibilityHidden(true)
            Text("Claudio")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text("HARNESS")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.white.opacity(0.85), lineWidth: 1)
                )
            Spacer()
            WelcomeRoundButton(systemName: "gearshape", accessibilityLabel: "设置", action: onSettings)
            WelcomeRoundButton(systemName: "terminal", accessibilityLabel: "工具", action: onTools)
        }
    }
}

/// 品牌行圆钮（深海墨底 + 细描边，44pt 命中区）。
struct WelcomeRoundButton: View {
    let systemName: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(OceanColor.navy.opacity(0.55)))
                .overlay(Circle().stroke(Color.white.opacity(0.16), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// hero 大标题：「探索未至之境」+ 英文 slogan（pp 定稿：中文主标 + 英文副行）。
struct WelcomeHero: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("探索未至之境")
                .font(.system(size: 40, weight: .heavy))
                .kerning(-1)
                .foregroundStyle(.white)
            Text("With us, into the unknown.")
                .font(.system(size: 16))
                .foregroundStyle(.white.opacity(0.62))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 玻璃路径卡：icon + 标题 + 副行（简介或状态摘要）+ 可选呼吸绿点 + chevron。
/// 未配置 = 入口态（› 进配置流）；已配置 = 状态态（⌄ 进管理）。
struct WelcomePathCard: View {
    enum Kind { case remote, local }

    let kind: Kind
    let title: String
    let subtitle: String
    let connected: Bool
    let action: () -> Void

    private var iconSystemName: String {
        kind == .remote ? "desktopcomputer" : "iphone"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: iconSystemName)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(OceanColor.ocean)
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color.white.opacity(0.10))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if connected {
                    BreathingConnectionDot()
                }
                Image(systemName: connected ? "chevron.down" : "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .glassSurface(radius: 20, dark: true)
    }
}

/// 「＋ 开始对话」全宽玻璃条（dsh「新建会话」同位同形）。
struct StartChatStrip: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.white.opacity(0.16)))
                Text("开始对话")
                    .font(.system(size: 16, weight: .semibold))
                    .tracking(-0.2)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
        }
        .buttonStyle(.plain)
        .glassSurface(radius: 18, dark: true)
    }
}

/// 发光状态点（对齐 dsh ConnectionDot 的 success 绿 + 光晕；静态即可，
/// dsh 原版也是静态 shadow，呼吸留给背景层）。
struct BreathingConnectionDot: View {
    var body: some View {
        Circle()
            .fill(OceanColor.success)
            .frame(width: 8, height: 8)
            .shadow(color: OceanColor.success.opacity(0.7), radius: 5)
            .accessibilityLabel("已连接")
    }
}
