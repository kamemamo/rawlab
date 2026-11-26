import DecoderKit
import LibraryKit
import SwiftUI

/// 今の写真の色味を、ほかの写真にまとめて貼る
struct LookPasteSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<Int64> = []
    @State private var rematch = true

    private let accent = Color(red: 0.31, green: 0.63, blue: 1.0)

    private var candidates: [Photo] {
        model.photos.filter { $0.id != model.selectedPhotoID && !$0.isMissing }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                if let ref = model.lookReference {
                    Image(decorative: ref, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 90, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("色味「\(model.lookReferenceName ?? "見本")」をほかの写真に貼る").font(.headline)
                    Text("選んだ写真の最初のバージョン(一覧で開くもの)に、この色味と強さ \(Int(model.settings.lookStrength))% を設定します。露出などほかの補正は変えません。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 8)], spacing: 8) {
                    ForEach(candidates) { photo in
                        cell(photo)
                    }
                }
                .padding(4)
            }
            .frame(minHeight: 260)
            .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                if candidates.isEmpty {
                    Text("左の一覧に、ほかの写真がありません").foregroundStyle(.secondary)
                }
            }

            Picker("貼り方", selection: $rematch) {
                Text("1 枚ずつ合わせ直す(写真ごとに同じ見本へ近づける。RAW を読むので少し時間がかかる)").tag(true)
                Text("そのまま貼る(今の写真で作った色味を同じようにかける。同じ光で撮った続きの写真向け)").tag(false)
            }
            .pickerStyle(.radioGroup)

            HStack {
                Button("すべて選ぶ") { selected = Set(candidates.map(\.id)) }
                Button("選択を外す") { selected = [] }
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("\(selected.count) 枚に貼る") {
                    model.pasteLook(to: Array(selected), rematch: rematch)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 680, height: 540)
    }

    private func cell(_ photo: Photo) -> some View {
        let on = selected.contains(photo.id)
        return VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumb = model.thumbnails[photo.id] {
                        Image(decorative: thumb, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Color.gray.opacity(0.2)
                    }
                }
                .frame(height: 80)
                .frame(maxWidth: .infinity)
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(on ? accent : .white.opacity(0.8))
                    .shadow(radius: 2)
                    .padding(4)
            }
            Text(photo.fileName)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(6)
        .background(on ? accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? accent : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture {
            if on { selected.remove(photo.id) } else { selected.insert(photo.id) }
        }
        .task { await model.loadThumbnail(for: photo) }
    }
}
