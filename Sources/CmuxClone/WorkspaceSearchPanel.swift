import AppKit
import SwiftUI

struct WorkspaceSearchPanel: View {
    @ObservedObject private var languagePreferences = LanguagePreferences.shared
    @ObservedObject var model: WorkspaceSearchModel
    var onOpen: () -> Void
    var onBack: (() -> Void)? = nil
    @FocusState private var searchFocused: Bool

    var body: some View {
        let _ = languagePreferences.language
        VStack(spacing: 0) {
            HStack(spacing: 1) {
                if let onBack {
                    IconButton(symbol: "arrow.left", help: L("文件"), action: onBack)
                }
                Text(L("搜索")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if model.searching {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 22)
                    IconButton(symbol: "stop.fill", help: L("取消搜索")) { model.cancel() }
                } else {
                    IconButton(symbol: "arrow.clockwise", help: L("刷新搜索")) { model.schedule(immediate: true) }
                }
                IconButton(symbol: "clear", help: L("清除搜索结果")) { model.clear(); searchFocused = true }
                IconButton(symbol: "arrow.uturn.backward", help: L("撤销上次替换")) { model.undoReplacement() }
                    .disabled(!model.canUndoReplacement)
                IconButton(symbol: "rectangle.compress.vertical", help: L("折叠或展开搜索结果")) {
                    model.collapsed = model.collapsed.count == model.results.files.count ? [] : Set(model.results.files.map(\.id))
                }
            }.padding(.leading, 12).padding(.trailing, 6).frame(height: 38)
            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    Button { model.showReplace.toggle() } label: {
                        Image(systemName: model.showReplace ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9)).frame(width: 12, height: 27).contentShape(Rectangle())
                    }.buttonStyle(.plain).pointingHandCursor().help(L("显示或隐藏替换"))
                    HStack(spacing: 1) {
                        TextField(L("搜索工作区内容"), text: $model.query.text)
                            .textFieldStyle(.plain).focused($searchFocused).onSubmit { model.schedule(immediate: true) }
                            .accessibilityIdentifier("workspace-search-input")
                        option("Aa", title: L("区分大小写"), value: $model.query.matchCase)
                        option("ab", title: L("全词匹配"), value: $model.query.wholeWord)
                        option(".*", title: L("使用正则表达式"), value: $model.query.regex)
                    }.padding(.leading, 8).padding(.trailing, 3).frame(height: 29)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
                        .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(searchFocused ? Color.accentColor : Color(nsColor: .separatorColor)) }
                }
                if model.showReplace {
                    HStack(spacing: 4) {
                        Color.clear.frame(width: 12, height: 1)
                        TextField(L("替换"), text: $model.replacement).textFieldStyle(.plain)
                            .accessibilityIdentifier("workspace-replace-input")
                            .padding(.horizontal, 8).frame(height: 29).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
                            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .separatorColor)) }
                        IconButton(symbol: "arrow.triangle.2.circlepath", help: L("全部替换…")) { replaceAll() }
                            .disabled(model.searching || model.completedQuery != model.query || model.results.count == 0)
                    }
                }
                HStack {
                    Spacer()
                    Button { model.showFilters.toggle() } label: { Image(systemName: "ellipsis").frame(width: 25, height: 18).contentShape(Rectangle()) }
                        .buttonStyle(.plain).pointingHandCursor().help(L("包含和排除的文件"))
                }
                if model.showFilters {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L("包含的文件")).foregroundStyle(.secondary)
                        TextField(L("例如：*.swift, src/**"), text: $model.query.includes).textFieldStyle(.roundedBorder)
                        Text(L("排除的文件")).foregroundStyle(.secondary)
                        TextField(L("例如：Tests/**, *.lock"), text: $model.query.excludes).textFieldStyle(.roundedBorder)
                        Toggle(L("使用忽略规则"), isOn: $model.query.useIgnores).toggleStyle(.checkbox).pointingHandCursor()
                    }.padding(.leading, 16).font(.system(size: 11))
                }
            }.font(.system(size: 12)).padding(.horizontal, 10).padding(.bottom, 8)
            if let error = model.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            if model.hasSearched && model.error == nil {
                Text(model.results.count == 0 ? L("未找到结果") : L("\(model.results.count) 个结果，分布于 \(model.results.files.count) 个文件"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 8).accessibilityIdentifier("workspace-search-summary")
            }
            if model.results.limitHit {
                Text(L("已达到搜索上限，请缩小搜索范围。")).font(.system(size: 11)).foregroundStyle(.orange).padding(.horizontal, 14)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.results.files) { file in
                        fileHeader(file)
                        if !model.collapsed.contains(file.id) {
                            ForEach(file.matches) { match in matchRow(file, match) }
                        }
                    }
                }.padding(.vertical, 4)
            }.opacity(model.searching ? 0.5 : 1)
            if !model.hasSearched && !model.searching {
                Text(L("在当前工作区的文件内容中搜索。"))
                    .font(.system(size: 11)).foregroundStyle(.tertiary).padding(16)
            }
            if model.results.skipped > 0 {
                Text(L("已跳过 \(model.results.skipped) 个不可搜索的文件"))
                    .font(.system(size: 10)).foregroundStyle(.tertiary).padding(8)
            }
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .onAppear { searchFocused = true }
            .onChange(of: model.focusRequest) { _, _ in searchFocused = true }
    }

    private func option(_ label: String, title: String, value: Binding<Bool>) -> some View {
        Button { value.wrappedValue.toggle() } label: {
            Text(verbatim: label).font(.system(size: 11, weight: .medium, design: .monospaced))
                .frame(width: 24, height: 23).contentShape(Rectangle())
                .background(value.wrappedValue ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 3))
        }.buttonStyle(.plain).pointingHandCursor().help(title).accessibilityLabel(title)
            .accessibilityValue(value.wrappedValue ? L("开启") : L("关闭"))
            .accessibilityAddTraits(value.wrappedValue ? [.isSelected] : [])
    }
    private func fileHeader(_ file: WorkspaceSearchFile) -> some View {
        Button {
            if model.collapsed.remove(file.id) == nil { model.collapsed.insert(file.id) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: model.collapsed.contains(file.id) ? "chevron.right" : "chevron.down").font(.system(size: 9)).frame(width: 11)
                Image(systemName: "doc.text").foregroundStyle(.secondary).frame(width: 14)
                Text(file.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                let parent = (file.path as NSString).deletingLastPathComponent
                if !parent.isEmpty { Text(parent).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle) }
                Spacer(minLength: 2)
                Text(verbatim: String(file.matches.count)).font(.system(size: 10, weight: .medium)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Color.accentColor.opacity(0.65), in: Capsule()).foregroundStyle(.white)
            }.font(.system(size: 12)).padding(.horizontal, 10).frame(height: 27).contentShape(Rectangle())
        }.buttonStyle(.plain).pointingHandCursor().help(file.path)
    }
    private func matchRow(_ file: WorkspaceSearchFile, _ match: WorkspaceSearchMatch) -> some View {
        let selected = model.selectedMatchID == file.id + ":" + String(match.id)
        return Button {
            if model.open(file, match: match) { onOpen() }
        } label: {
            highlighted(match).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 34).padding(.trailing, 10).frame(height: 23)
                .background(selected ? Color.accentColor.opacity(0.16) : .clear).contentShape(Rectangle())
        }.buttonStyle(.plain).pointingHandCursor()
            .help(L("\(file.path)：行 \(match.line)，列 \(match.column)"))
            .accessibilityLabel(L("\(file.path)：行 \(match.line)，列 \(match.column)"))
            .simultaneousGesture(TapGesture(count: 2).onEnded { if model.open(file, match: match, keep: true) { onOpen() } })
            .contextMenu {
                Button(L("打开并保留")) { if model.open(file, match: match, keep: true) { onOpen() } }
                if model.showReplace {
                    Button(L("替换此匹配")) { if model.replace(file: file, match: match) { onOpen() } }
                        .disabled(model.searching || model.completedQuery != model.query)
                    Button(L("替换此文件中的匹配…")) {
                        if confirmReplacement(file.matches.count), model.replace(file: file) { onOpen() }
                    }.disabled(model.searching || model.completedQuery != model.query)
                }
            }
    }
    private func highlighted(_ match: WorkspaceSearchMatch) -> Text {
        var text = AttributedString(match.preview)
        if let range = Range(match.previewRange, in: match.preview), let attributedRange = Range(range, in: text) {
            text[attributedRange].backgroundColor = Color.accentColor.opacity(0.3)
        }
        return Text(text)
    }
    private func confirmReplacement(_ count: Int) -> Bool {
        confirm(title: L("替换 \(count) 个匹配？"), detail: L("替换将写入编辑器缓冲区；请检查结果并使用 ⌘S 保存文件。"), action: L("替换"))
    }
    private func replaceAll() {
        if confirmReplacement(model.results.count), model.replace() { onOpen() }
    }
}
