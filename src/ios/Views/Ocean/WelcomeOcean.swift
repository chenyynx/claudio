import SwiftUI

// MARK: - 欢迎页深海版组件
// 逐项对照 dsh-mobile WorkspaceView.swift 真实实现（不再按截图目测）：
// header / hero / workspaceCard / newSessionButton 的结构、字号、透明度、
// 材质全部对齐原版；差异仅品牌元素（幽灵剪影 + Claudio + HARNESS）与动作闭包。

/// dsh HarnessMark 同构：剪影 icon + 产品名（22 semibold rounded）+ 描边徽章
/// （9 bold monospaced, padding 5/3, r3）。品牌元素换 claudio 幽灵。
/// 不带右上圆钮——emptyState 是会话列表 overlay，系统导航栏按钮仍在
/// （齿轮/菜单由 toolbar 提供），重复入口多余（2026-09-07 pp 拍板删除）。
struct WelcomeBrandMark: View {
    var body: some View {
        HStack(spacing: 7) {
            Image("GhostMark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 27, height: 27)
                .foregroundStyle(.white)
                .accessibilityHidden(true)
            Text("Claudio")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
            Text("HARNESS")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(Color.white, lineWidth: 1)
                )
        }
    }
}

/// dsh hero 同构：32/bold 主标 + .subheadline 白 65% 副行，spacing 7。
struct WelcomeHero: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("探索未至之境")
                .font(.system(size: 32, weight: .bold))
            Text("With us, into the unknown.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.65))
        }
    }
}

/// dsh workspaceCard 同构（关键修正：**不是玻璃 blur**——白 5.5% 薄层 +
/// r15 描边白 14%；裸 icon 无底块，.blue .title3；标题 .subheadline semibold，
/// 副行 .caption 白 55%；绿点 8pt 光晕 shadow 0.65/5；chevron .caption 白 55%）。
struct WelcomePathCard: View {
    enum Kind { case remote, local }

    let kind: Kind
    let title: String
    let subtitle: String
    let connected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: kind == .remote ? "desktopcomputer" : "iphone")
                    .foregroundStyle(.blue)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer()
                if connected {
                    WelcomeConnectionDot()
                }
                Image(systemName: connected ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(16)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.14)))
            .contentShape(RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.plain)
    }
}

/// dsh newSessionButton 同构：iOS 26 `.glass(.clear.tint(navy 22%))` +
/// roundedRectangle 18 边框 + flexible sizing；低版本 glassSurface fallback。
/// label：plus 15 semibold 28×28 白 10% 圆底 + .headline 文字，高 38。
struct StartChatStrip: View {
    let action: () -> Void

    var body: some View {
        if #available(iOS 26.0, *) {
            Button(action: action) { startChatLabel }
                .buttonStyle(.glass(.clear.tint(OceanColor.navy.opacity(0.22))))
                .buttonBorderShape(.roundedRectangle(radius: 18))
                .buttonSizing(.flexible)
        } else {
            Button(action: action) { startChatLabel }
                .buttonStyle(.plain)
                .glassSurface(radius: 18, dark: true, tint: .white.opacity(0.08))
        }
    }

    private var startChatLabel: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(.white.opacity(0.1), in: Circle())
            Text("开始对话")
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 38)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// dsh ConnectionDot 的固定 connected 版（success 绿 8pt + 光晕 0.65/5）。
struct WelcomeConnectionDot: View {
    var body: some View {
        Circle()
            .fill(OceanColor.success)
            .frame(width: 8, height: 8)
            .shadow(color: OceanColor.success.opacity(0.65), radius: 5)
            .accessibilityLabel("已连接")
    }
}
