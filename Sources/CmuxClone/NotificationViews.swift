import AppKit
import SwiftUI

struct GitNotificationStatusBar: View {
    @ObservedObject var store: GitNotificationStore
    @ObservedObject private var language = LanguagePreferences.shared
    var body: some View {
        let _ = language.language
        HStack(spacing: 0) {
            Button { store.toggleCenter() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "xmark.circle")
                    Text("\(store.errorCount)").monospacedDigit()
                    Image(systemName: "exclamationmark.triangle").padding(.leading, 4)
                    Text("\(store.warningCount)").monospacedDigit()
                }.padding(.horizontal, 10).frame(height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain).pointingHandCursor()
                .help(L("Git 通知：\(store.errorCount) 个错误，\(store.warningCount) 个警告，点击查看"))
                .accessibilityLabel(L("Git 通知：\(store.errorCount) 个错误，\(store.warningCount) 个警告，点击查看"))
            Spacer(minLength: 0)
            Button { store.toggleCenter() } label: {
                HStack(spacing: 5) {
                    Image(systemName: store.notices.isEmpty ? "bell" : "bell.badge")
                    if !store.notices.isEmpty { Text("\(store.notices.count)").monospacedDigit() }
                }.padding(.horizontal, 10).frame(height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain).pointingHandCursor().help(L("Git 通知"))
                .accessibilityLabel(L("Git 通知"))
        }.font(.system(size: 11)).foregroundStyle(.secondary).background(.bar)
    }
}

struct GitNotificationOverlay: View {
    @ObservedObject var store: GitNotificationStore
    let showOutput: (GitNotice) -> Void
    @ObservedObject private var language = LanguagePreferences.shared
    var body: some View {
        let _ = language.language
        GeometryReader { geometry in
            VStack(alignment: .trailing, spacing: 8) {
                if store.isCenterVisible {
                    center.frame(height: min(460, max(180, geometry.size.height - 60)))
                } else {
                    ForEach(store.toasts) { notice in
                        GitNoticeCard(notice: notice, store: store, isToast: true, showOutput: showOutput)
                    }
                }
            }.frame(width: min(450, max(260, geometry.size.width - 24)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(12)
        }
        .task(id: store.toastIDs.isEmpty) {
            while !Task.isCancelled && !store.toastIDs.isEmpty {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                store.advanceToasts(by: 0.25, appIsActive: NSApp.isActive)
            }
        }
    }

    private var center: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Git 通知")).font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(L("清除全部")) { store.clearAll() }.buttonStyle(.plain).pointingHandCursor()
                    .font(.system(size: 11)).disabled(store.notices.isEmpty)
                IconButton(symbol: "chevron.down", help: L("收起通知")) { store.isCenterVisible = false }
                    .keyboardShortcut(.cancelAction)
            }.padding(.leading, 12).padding(.trailing, 5).frame(height: 36).background(.bar)
            Divider()
            if store.notices.isEmpty {
                Text(L("暂无 Git 通知")).font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(store.notices) { notice in
                                GitNoticeCard(notice: notice, store: store, isToast: false, showOutput: showOutput)
                                    .id(notice.id)
                                Divider()
                            }
                        }
                    }.onAppear { if let id = store.selectedNoticeID { proxy.scrollTo(id, anchor: .top) } }
                }
            }
        }.background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)).allowsHitTesting(false))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }
}

private struct GitNoticeCard: View {
    let notice: GitNotice
    @ObservedObject var store: GitNotificationStore
    let isToast: Bool
    let showOutput: (GitNotice) -> Void
    @State private var expanded = false
    @State private var hovered = false
    @FocusState private var focusedControl: String?
    private var showDetail: Bool { expanded || (!isToast && store.selectedNoticeID == notice.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: notice.severity.symbol).foregroundStyle(notice.severity.color)
                    .font(.system(size: 15)).frame(width: 18).padding(.top, 4)
                VStack(alignment: .leading, spacing: 5) {
                    Text(notice.kind.title).font(.system(size: 12, weight: .semibold))
                    Text(notice.summary).font(.system(size: 12)).lineLimit(showDetail ? nil : 3)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.top, 3)
                IconButton(symbol: "xmark", help: L("清除此通知")) { store.dismiss(notice.id) }
                    .focused($focusedControl, equals: "close")
            }
            if showDetail {
                ScrollView {
                    Text(notice.detail).font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }.frame(height: 140).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 3))
            }
            HStack(spacing: 8) {
                Text(notice.source).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(notice.repositoryURL.path)
                if notice.occurrences > 1 {
                    Text("×\(notice.occurrences)").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(showDetail ? L("收起详情") : L("查看详情")) {
                    if isToast { store.showCenter(select: notice.id) }
                    else {
                        let expand = !showDetail
                        if store.selectedNoticeID == notice.id { store.showCenter() }
                        expanded = expand
                    }
                }.buttonStyle(.plain).foregroundStyle(Color.accentColor).pointingHandCursor()
                    .focused($focusedControl, equals: "details")
                if notice.canShowOutput {
                    Button(L("显示 Git 输出")) { showOutput(notice) }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor).pointingHandCursor()
                        .focused($focusedControl, equals: "output")
                }
                if showDetail {
                    IconButton(symbol: "doc.on.doc", help: L("复制错误详情")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(notice.detail, forType: .string)
                    }
                    .focused($focusedControl, equals: "copy")
                }
            }.font(.system(size: 11))
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: isToast ? 6 : 0))
            .overlay {
                if isToast { RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)).allowsHitTesting(false) }
            }
            .shadow(color: .black.opacity(isToast ? 0.16 : 0), radius: 8, y: 3)
            .focusable().focused($focusedControl, equals: "card")
            .onHover { hovered = $0; store.protectToast(notice.id, hovered || focusedControl != nil) }
            .onChange(of: focusedControl) { _, value in store.protectToast(notice.id, hovered || value != nil) }
            .onDisappear { store.protectToast(notice.id, false) }
    }
}
