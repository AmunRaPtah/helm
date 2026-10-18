import PhotosUI
import SwiftUI

struct ComposerView: View {
    @Bindable var model: ChatModel
    let accent: Color

    @State private var photoItems: [PhotosPickerItem] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            if !model.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.attachments) { a in
                            AttachmentChip(attachment: a) { model.removeAttachment(a) }
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $photoItems, maxSelectionCount: 4, matching: .images) {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(Color(.tertiarySystemFill), in: Circle())
                        .foregroundStyle(.secondary)
                }
                .disabled(model.isExited)
                .accessibilityLabel("Attach image")

                TextField(placeholder, text: $model.draft, axis: .vertical)
                    .lineLimit(1...8)
                    .focused($focused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(minHeight: 36)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                    .disabled(model.isExited)

                actionButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(.bar)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            for item in items { Task { await upload(item) } }
        }
    }

    private var placeholder: String {
        model.isExited ? "Session exited" : model.isRunning ? "Working\u{2026}" : "Message"
    }

    @ViewBuilder
    private var actionButton: some View {
        if model.isRunning {
            Button {
                Task { await model.interrupt() }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 36, height: 36)
                    .background(Color.primary, in: Circle())
                    .foregroundStyle(Color(.systemBackground))
            }
            .accessibilityLabel("Stop")
            .transition(.scale.combined(with: .opacity))
        } else {
            Button {
                Task { await model.send() }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 36, height: 36)
                    .background(model.canSend ? accent : Color(.tertiarySystemFill), in: Circle())
                    .foregroundStyle(model.canSend ? Color.white : Color.secondary)
            }
            .disabled(!model.canSend)
            .accessibilityLabel("Send")
            .transition(.scale.combined(with: .opacity))
        }
    }

    private func upload(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            model.banner = "Couldn't load that image."
            return
        }
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        if let jpeg = ImageEncoding.jpeg(from: data) {
            await model.upload(data: jpeg, filename: "image-\(stamp).jpg", mimeType: "image/jpeg")
        } else {
            await model.upload(data: data, filename: "file-\(stamp)", mimeType: "application/octet-stream")
        }
    }
}

enum ImageEncoding {
    /// Re-encode (HEIC etc.) as JPEG, capped at 2048px on the long side.
    static func jpeg(from data: Data, maxSide: CGFloat = 2048) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height, 1))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.85)
    }
}

struct AttachmentChip: View {
    let attachment: Attachment
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if attachment.isUploading {
                ProgressView().controlSize(.mini)
            } else if attachment.error != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } else {
                Image(systemName: "photo")
            }
            Text(attachment.error ?? attachment.filename)
                .lineLimit(1)
                .frame(maxWidth: 160)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove attachment")
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(.tertiarySystemFill), in: Capsule())
    }
}
