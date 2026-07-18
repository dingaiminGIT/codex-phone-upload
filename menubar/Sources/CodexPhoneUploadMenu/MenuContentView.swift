import SwiftUI

struct MenuContentView: View {
    @ObservedObject var coordinator: UploadCoordinator

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.title3)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex 手机传图")
                        .font(.body.weight(.semibold))
                    Text("同一 Wi-Fi · 一次性二维码")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Group {
                if let qrImage = coordinator.qrImage,
                   coordinator.phase == .ready || coordinator.phase == .uploading {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 170, height: 170)
                        .padding(8)
                        .background(.white, in: RoundedRectangle(cornerRadius: 12))
                } else if coordinator.phase == .success {
                    statusSymbol("checkmark.circle.fill", color: .green)
                } else if coordinator.phase == .failure || coordinator.phase == .expired {
                    statusSymbol("exclamationmark.triangle.fill", color: .orange)
                } else {
                    ProgressView()
                        .controlSize(.regular)
                        .frame(width: 186, height: 186)
                }
            }

            Text(coordinator.status)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(statusColor)
                .frame(maxWidth: .infinity)

            if coordinator.phase == .ready, let expiresAt = coordinator.expiresAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(remainingText(until: expiresAt, now: context.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("换一个") {
                    coordinator.newSession()
                }
                .buttonStyle(.bordered)

                Button("复制链接") {
                    coordinator.copyUploadURL()
                }
                .disabled(coordinator.uploadURL == nil)
            }
            .controlSize(.small)

            Divider()

            HStack {
                Text("最多 12 张 · 不发送 · 不分析")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("关闭") {
                    coordinator.quit()
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 276)
        .onAppear {
            coordinator.ensureSession()
        }
    }

    private var statusColor: Color {
        coordinator.phase == .failure ? .orange : .primary
    }

    private func statusSymbol(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 74))
            .foregroundStyle(color)
            .frame(width: 186, height: 186)
    }

    private func remainingText(until date: Date, now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        return String(format: "%d:%02d 后失效", seconds / 60, seconds % 60)
    }
}
