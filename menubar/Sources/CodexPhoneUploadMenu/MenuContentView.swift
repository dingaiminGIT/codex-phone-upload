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
                    Text(coordinator.text.appTitle)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(coordinator.text.subtitle(mode: coordinator.mode))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer()
                Menu {
                    ForEach(AppLanguage.allCases) { language in
                        Button {
                            coordinator.setLanguage(language)
                        } label: {
                            if coordinator.language == language {
                                Label(language.menuLabel, systemImage: "checkmark")
                            } else {
                                Text(language.menuLabel)
                            }
                        }
                    }
                } label: {
                    Label(coordinator.language.shortLabel, systemImage: "globe")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Picker(
                coordinator.text.modeLabel,
                selection: Binding(
                    get: { coordinator.mode },
                    set: { coordinator.setMode($0) }
                )
            ) {
                ForEach(UploadMode.allCases) { mode in
                    Text(coordinator.text.modeName(mode)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(coordinator.phase == .starting || coordinator.phase == .uploading)
            .accessibilityLabel(coordinator.text.modeLabel)

            if let targetName = coordinator.targetName {
                HStack(spacing: 6) {
                    Text(coordinator.text.targetLabel + ":")
                        .foregroundStyle(.secondary)
                    Text(coordinator.text.targetName(targetName))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .accessibilityElement(children: .combine)
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
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if coordinator.phase == .ready, let expiresAt = coordinator.expiresAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(remainingText(until: expiresAt, now: context.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button(coordinator.text.newCode) {
                    coordinator.newSession()
                }
                .buttonStyle(.bordered)
                .disabled(coordinator.phase == .starting || coordinator.phase == .uploading)

                Button(coordinator.text.copyLink) {
                    coordinator.copyUploadURL()
                }
                .disabled(coordinator.uploadURL == nil)
            }
            .controlSize(.small)

            Divider()

            HStack {
                Text(coordinator.text.privacySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(coordinator.text.close) {
                    coordinator.quit()
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 300)
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
        return coordinator.text.remaining(seconds: seconds)
    }
}
