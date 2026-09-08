import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var doctorVM: DoctorViewModel
    var onComplete: () -> Void

    @State private var currentStep = 0

    private var steps: [(icon: String, title: String, description: String)] {
        [
            ("sparkles", String(localized: "Already have ChatGPT Plus?"), String(localized: "You can use Codex today with no extra subscription. CC Pocket helps you set it up on your Mac and connect from your phone.")),
            ("stethoscope", String(localized: "Codex-first setup"), String(localized: "We'll check the essentials for a polished Codex workflow on your Mac.")),
            ("checkmark.seal.fill", String(localized: "Codex is ready"), String(localized: "Your Mac is ready for a phone-first Codex workflow.")),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Step indicator
            HStack(spacing: 6) {
                ForEach(0..<steps.count, id: \.self) { index in
                    Capsule()
                        .fill(index <= currentStep ? Color.accentColor : .white.opacity(0.15))
                        .frame(width: index == currentStep ? 20 : 8, height: 4)
                        .animation(.smooth, value: currentStep)
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 16)

            if currentStep == 0 {
                welcomeStep
            } else if currentStep == 1 {
                doctorStep
            } else {
                doneStep
            }
        }
    }

    // MARK: - Step 0: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(.cyan.opacity(0.18))
                    .frame(width: 180, height: 180)
                    .blur(radius: 18)
                    .offset(x: -80, y: -30)

                Circle()
                    .fill(.blue.opacity(0.16))
                    .frame(width: 140, height: 140)
                    .blur(radius: 16)
                    .offset(x: 90, y: -50)

                VStack(spacing: 18) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.cyan.opacity(0.95), Color.blue.opacity(0.8)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 68, height: 68)

                        Image(systemName: steps[0].icon)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                            .symbolEffect(.bounce, value: currentStep)
                    }

                    VStack(spacing: 10) {
                        Text(steps[0].title)
                            .font(.title2.weight(.bold))
                            .multilineTextAlignment(.center)

                        Text(steps[0].description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }

                    HStack(spacing: 8) {
                        WelcomeBadge(title: String(localized: "ChatGPT Plus or above"))
                        WelcomeBadge(title: String(localized: "No extra subscription"))
                    }

                    HStack(spacing: 8) {
                        WelcomeBadge(title: String(localized: "Mac setup assistant"))
                        WelcomeBadge(title: String(localized: "Claude optional"))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 28)
            }
            .frame(maxWidth: .infinity)
            .background(.white.opacity(0.06), in: .rect(cornerRadius: 28))
            .glassEffect(.regular.tint(.white.opacity(0.1)), in: .rect(cornerRadius: 28))
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .padding(.top, 20)

            Spacer()

            Button(String(localized: "Set Up Codex")) {
                withAnimation { currentStep = 1 }
                doctorVM.runDoctor()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Step 1: Doctor (Main)

    private var doctorStep: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                onboardingStatusCard
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)

            // Scrollable step list
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if doctorVM.isRunning && doctorVM.report == nil {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Running checks…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 16)
                    } else if let report = doctorVM.report {
                        setupStepList(report: report)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }

            // Fixed bottom bar
            bottomBar
        }
    }

    // MARK: - Step List (flattened numbered steps)

    @ViewBuilder
    private func setupStepList(report: DoctorReport) -> some View {
        let allSteps = buildStepList(report: report)

        ForEach(Array(allSteps.enumerated()), id: \.offset) { index, step in
            stepRow(step: step, number: index + 1)
                .padding(.vertical, 4)
        }

        // Error / progress
        if let error = doctorVM.actionError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
                .padding(.top, 4)
        }

        if let action = doctorVM.actionInProgress {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text(action)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Row Components

    @ViewBuilder
    private func stepRow(step: SetupStep, number: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // Badge: green check if passed, numbered circle if pending
            if step.isPassed {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(.green, in: .circle)
            } else {
                Text("\(number)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Color.accentColor, in: .circle)
            }

            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(step.commands.enumerated()), id: \.element.id) { idx, cmd in
                    if idx > 0 {
                        Text(String(localized: "or"))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }

                    Text(cmd.comment)
                        .font(.caption2)
                        .foregroundStyle(cmd.isPassed ? .tertiary : .secondary)

                    CommandRow(command: cmd.command) {
                        #if DEBUG
                        doctorVM.markCommandCompleted(cmd.command)
                        #endif
                    }
                    .opacity(cmd.isPassed ? 0.5 : 1)
                }
            }
        }
    }

    // MARK: - Bottom Bar (pinned)

    private var bottomBar: some View {
        VStack(spacing: 8) {
            Divider()

            Text(doctorVM.onboardingHint)
                .font(.caption)
                .foregroundStyle(doctorVM.canContinueOnboarding ? .green : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Terminal + Re-check (always visible)
            HStack(spacing: 8) {
                Button {
                    doctorVM.openSetupTerminal()
                } label: {
                    Label(String(localized: "Open Terminal"), systemImage: "terminal")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)

                Button {
                    doctorVM.runDoctor()
                } label: {
                    Label(String(localized: "Re-check"), systemImage: "arrow.clockwise")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(doctorVM.isRunning)
            }

            // Navigation
            HStack {
                Button("Back") {
                    withAnimation { currentStep -= 1 }
                }
                .buttonStyle(.borderless)
                .font(.caption)

                Spacer()

                Button(doctorVM.onboardingCTA) {
                    withAnimation { currentStep = 2 }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .font(.caption.weight(.semibold))
                .disabled(doctorVM.isRunning || !doctorVM.canContinueOnboarding)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    // MARK: - Step 2: Done

    private var doneStep: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                Image(systemName: steps[2].icon)
                    .font(.system(size: 40))
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, value: currentStep)

                Text(steps[2].title)
                    .font(.title3.weight(.semibold))

                Text(steps[2].description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Text(String(localized: "Use the CC Pocket app to scan the Connect tab QR code and start from your phone."))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 20)

            Spacer()

            Button("Open CC Pocket") {
                onComplete()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Step Builder

    private struct SetupCommand: Identifiable {
        let id = UUID()
        let comment: String
        let command: String
        let isPassed: Bool
    }

    private struct SetupStep {
        /// Multiple commands = "pick one" (shown with "or" separator)
        let commands: [SetupCommand]

        var isPassed: Bool {
            commands.contains { $0.isPassed }
        }
    }

    private func buildStepList(report: DoctorReport) -> [SetupStep] {
        var steps: [SetupStep] = []
        var seenChecks: Set<String> = []

        for check in report.results {
            // Bridge Server and launchd share the same command — deduplicate
            let groupKey: String
            if check.name == "Bridge Server" || check.name == "launchd service" {
                groupKey = "bridge"
            } else {
                groupKey = check.name
            }
            guard !seenChecks.contains(groupKey) else { continue }
            seenChecks.insert(groupKey)

            let commands = doctorVM.onboardingCommands(for: check)
            guard !commands.isEmpty else { continue }

            let checkPassed = check.status == "pass"
            let isPickOne = check.name == "CLI providers" && commands.count > 1

            if isPickOne {
                // Group all commands into one step (pick one)
                let cmds = commands.map { entry -> SetupCommand in
                    #if DEBUG
                    let done = doctorVM.completedCommands.contains(entry.command)
                    return SetupCommand(comment: entry.comment, command: entry.command, isPassed: checkPassed || done)
                    #else
                    return SetupCommand(comment: entry.comment, command: entry.command, isPassed: checkPassed)
                    #endif
                }
                steps.append(SetupStep(commands: cmds))
            } else {
                // One command per step
                for entry in commands {
                    #if DEBUG
                    let done = doctorVM.completedCommands.contains(entry.command)
                    let passed = checkPassed || done
                    #else
                    let passed = checkPassed
                    #endif
                    steps.append(SetupStep(commands: [
                        SetupCommand(comment: entry.comment, command: entry.command, isPassed: passed),
                    ]))
                }
            }
        }

        return steps
    }

    private var onboardingStatusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: doctorVM.canContinueOnboarding
                                    ? [Color.green.opacity(0.85), Color.cyan.opacity(0.65)]
                                    : [Color.cyan.opacity(0.9), Color.blue.opacity(0.72)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 40, height: 40)

                    Image(systemName: doctorVM.canContinueOnboarding ? "checkmark" : steps[1].icon)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(steps[1].title)
                        .font(.title3.weight(.semibold))
                    Text(steps[1].description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            HStack(spacing: 8) {
                StatusBadge(
                    title: "Codex",
                    systemImage: doctorVM.isCodexReady ? "checkmark.seal.fill" : "bolt.fill",
                    tint: doctorVM.isCodexReady ? .green : .blue
                )
                StatusBadge(
                    title: "Bridge",
                    systemImage: doctorVM.allPassed ? "checkmark.circle.fill" : "dot.scope",
                    tint: doctorVM.allPassed ? .green : .secondary
                )
                if doctorVM.isClaudeReady {
                    StatusBadge(
                        title: "Claude",
                        systemImage: "checkmark.circle.fill",
                        tint: .secondary
                    )
                }
            }
        }
        .padding(16)
        .background(.white.opacity(0.07), in: .rect(cornerRadius: 20))
        .glassEffect(.regular.tint(.white.opacity(0.08)), in: .rect(cornerRadius: 20))
    }
}

private struct WelcomeBadge: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.white.opacity(0.08), in: .capsule)
            .glassEffect(.regular.tint(.white.opacity(0.06)), in: .capsule)
    }
}

private struct StatusBadge: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.12), in: .capsule)
    }
}

// MARK: - Command Row (reusable)

struct CommandRow: View {
    let command: String
    var onCopied: (() -> Void)?

    @State private var copied = false

    var body: some View {
        HStack(spacing: 4) {
            Text(command)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)

            Spacer(minLength: 4)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
                onCopied?()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption2)
                    .frame(width: 16, height: 16)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(copied ? .green : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.black.opacity(0.2), in: .rect(cornerRadius: 6))
    }
}
