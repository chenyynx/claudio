import SwiftUI

struct PopoverContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @StateObject private var usageVM = UsageViewModel()
    @StateObject private var qrCodeVM = QRCodeViewModel()
    @StateObject private var doctorVM = DoctorViewModel()

    /// Track previous tab index for slide direction
    @State private var previousTabIndex = 0

    var body: some View {
        GlassEffectContainer {
            Group {
                if viewModel.hasCompletedOnboarding {
                    mainContent
                } else {
                    OnboardingView(doctorVM: doctorVM) {
                        viewModel.completeOnboarding()
                    }
                }
            }
            .frame(width: 380, height: 500)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
        }
        .onChange(of: viewModel.selectedTab) { oldTab, newTab in
            previousTabIndex = oldTab.rawValue
            switch newTab {
            case .usage:
                usageVM.fetchUsage()
            case .qrCode:
                qrCodeVM.refresh()
            case .doctor:
                if doctorVM.report == nil {
                    doctorVM.runDoctor()
                }
            }
        }
        .onAppear {
            // Fetch on popover open instead of polling
            viewModel.checkHealth()
            if viewModel.selectedTab == .usage {
                usageVM.fetchUsage()
            }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        VStack(spacing: 0) {
            HeaderView(viewModel: viewModel)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            GlassTabBar(selectedTab: $viewModel.selectedTab)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)

            // Content area with directional slide transition
            ZStack {
                switch viewModel.selectedTab {
                case .usage:
                    UsagePageView(viewModel: usageVM, bridgeStatus: viewModel.bridgeStatus)
                        .transition(slideTransition)
                case .qrCode:
                    QRCodePageView(viewModel: qrCodeVM)
                        .transition(slideTransition)
                case .doctor:
                    DoctorPageView(
                        viewModel: doctorVM,
                        launchAtLogin: $viewModel.launchAtLogin,
                        bridgeUpdateAvailable: viewModel.bridgeUpdateAvailable,
                        onUpdateBridge: { doctorVM.updateBridge() }
                    )
                        .transition(slideTransition)
                        #if DEBUG
                        .safeAreaInset(edge: .bottom) {
                            MockDoctorPicker(doctorVM: doctorVM)
                        }
                        #endif
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(.smooth(duration: 0.3), value: viewModel.selectedTab)
        }
    }

    private var slideTransition: AnyTransition {
        let forward = viewModel.selectedTab.rawValue >= previousTabIndex
        return .push(from: forward ? .trailing : .leading)
    }
}

// MARK: - Glass Tab Bar

struct GlassTabBar: View {
    @Binding var selectedTab: AppTab
    @Namespace private var tabNamespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    withAnimation(.smooth(duration: 0.25)) {
                        selectedTab = tab
                    }
                } label: {
                    Label(tab.label, systemImage: tab.icon)
                        .font(.subheadline.weight(.medium))
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background {
                            if selectedTab == tab {
                                Capsule()
                                    .fill(.white.opacity(0.12))
                                    .matchedGeometryEffect(id: "activeTab", in: tabNamespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedTab == tab ? .primary : .tertiary)
            }
        }
        .padding(3)
        .glassEffect(.regular, in: .capsule)
    }
}

// MARK: - Mock Doctor Picker (DEBUG only)

#if DEBUG
struct MockDoctorPicker: View {
    @ObservedObject var doctorVM: DoctorViewModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "ant.fill")
                .font(.caption2)
                .foregroundStyle(.orange)

            Picker("Mock", selection: mockBinding) {
                Text("Off").tag(nil as MockDoctorScenario?)
                ForEach(MockDoctorScenario.allCases, id: \.self) { scenario in
                    Text(scenario.displayName).tag(scenario as MockDoctorScenario?)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 8))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var mockBinding: Binding<MockDoctorScenario?> {
        Binding(
            get: { doctorVM.mockScenario },
            set: { doctorVM.setMockScenario($0) }
        )
    }
}
#endif
