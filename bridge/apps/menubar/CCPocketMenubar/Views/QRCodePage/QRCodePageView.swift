import SwiftUI

struct QRCodePageView: View {
    @ObservedObject var viewModel: QRCodeViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [Color.cyan.opacity(0.9), Color.blue.opacity(0.72)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 36, height: 36)

                            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Ready for your phone")
                                .font(.subheadline.weight(.semibold))
                            Text("Scan this QR code in CC Pocket to connect to your Mac.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }

                    if let selectedAddress = viewModel.selectedAddress {
                        HStack(spacing: 8) {
                            routeBadge(title: selectedAddress.label, tint: .blue)
                            routeBadge(title: selectedAddress.ip, tint: .secondary)
                        }
                    }
                }
                .padding(16)
                .background(.white.opacity(0.07), in: .rect(cornerRadius: 18))
                .glassEffect(.regular.tint(.white.opacity(0.08)), in: .rect(cornerRadius: 18))

                // QR Code card
                if let image = viewModel.qrImage {
                    VStack(spacing: 12) {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 180, height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        Text("Scan with CC Pocket app")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity)
                    .background(.white.opacity(0.06), in: .rect(cornerRadius: 16))
                } else {
                    ContentUnavailableView {
                        Label("No Network", systemImage: "wifi.slash")
                    } description: {
                        Text("No network addresses found.")
                    }
                }

                // Deep link with copy
                if !viewModel.deepLink.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "link")
                            .font(.caption)
                            .foregroundStyle(.tertiary)

                        Text(viewModel.deepLink)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        Button {
                            viewModel.copyDeepLink()
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Copy deep link")
                    }
                    .padding(.horizontal, 4)
                }

                // Address list
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(viewModel.addresses) { address in
                        AddressRow(
                            address: address,
                            port: viewModel.port,
                            isSelected: viewModel.selectedAddress?.ip == address.ip
                        ) {
                            viewModel.selectAddress(address)
                        }
                    }
                }
                .background(.white.opacity(0.06), in: .rect(cornerRadius: 12))
            }
            .padding(16)
        }
        .onAppear {
            viewModel.refresh()
        }
    }

    private func routeBadge(title: String, tint: Color) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.12), in: .capsule)
    }
}
