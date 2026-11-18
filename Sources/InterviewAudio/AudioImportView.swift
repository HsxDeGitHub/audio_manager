import SwiftUI

struct AudioImportView: View {
    @Environment(\.dismiss) private var dismiss
    @UIState private var draft: AudioImportDraft
    @ObservedObject var installer: ModelInstaller
    let onConfirm: (AudioImportDraft) -> Void

    init(draft: AudioImportDraft, installer: ModelInstaller, onConfirm: @escaping (AudioImportDraft) -> Void) {
        _draft = UIState(initialValue: draft)
        self.installer = installer
        self.onConfirm = onConfirm
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("导入音频").font(.title2.weight(.semibold))
            if draft.urls.count == 1, let url = draft.urls.first {
                HStack {
                    Text("资料名称").accessibilityHidden(true)
                    TextField("资料名称", text: $draft.title, prompt: Text(url.deletingPathExtension().lastPathComponent))
                        .textFieldStyle(.roundedBorder).accessibilityLabel("资料名称")
                }
            } else {
                Text("这 \(draft.urls.count) 份音频共用所选人数。").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                SpeakerCountPicker(selection: $draft.speakerCount).fixedSize()
                Text("人数不确定时，可选择自动判断。").font(.caption).foregroundStyle(.secondary)
            }
            if !installer.ready {
                Text("录音会先保存，模型就绪后可开始转写。").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(installer.ready ? "导入并转写" : "导入") { onConfirm(draft) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

struct SpeakerCountPicker: View {
    @Binding var selection: Int?

    var body: some View {
        Picker("说话人数", selection: Binding(get: { selection ?? 0 }, set: { selection = $0 == 0 ? nil : $0 })) {
            Text("自动判断").tag(0)
            ForEach(1...12, id: \.self) { Text("\($0) 人").tag($0) }
        }
    }
}
