import Foundation

/// Open editor tabs only. File contents remain on disk and require explicit saving.
struct FileWorkspaceSession: Codable, Equatable {
    struct Document: Codable, Equatable {
        var path: String
        var isPreview: Bool
        var markdownPreview: Bool
        var markdownPreviewOnly: Bool? = nil
    }

    var documents: [Document]
    var selectedPath: String?

    func validate() throws {
        let paths = Set(documents.map(\.path))
        guard documents.count <= 1000, paths.count == documents.count,
              documents.filter(\.isPreview).count <= 1,
              selectedPath.map({ paths.contains($0) }) ?? true,
              documents.allSatisfy({ document in
                  let path = document.path
                  return !path.isEmpty && path.utf8.count <= 16_384 &&
                      !(path as NSString).isAbsolutePath && !path.contains("\0") &&
                      path.split(separator: "/", omittingEmptySubsequences: false)
                          .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
              }) else {
            throw CocoaError(.coderReadCorrupt)
        }
    }
}

extension FileWorkspaceModel {
    var sessionSnapshot: FileWorkspaceSession {
        let saved = documents.map {
            FileWorkspaceSession.Document(path: relativePath($0.url), isPreview: $0.isPreview,
                                          markdownPreview: $0.markdownPreview, markdownPreviewOnly: $0.markdownPreviewOnly)
        }
        return FileWorkspaceSession(documents: saved,
                                    selectedPath: selectedDocument.map { relativePath($0.url) } ?? saved.last?.path)
    }

    func restoreSession(_ session: FileWorkspaceSession) {
        do { try session.validate() }
        catch { self.error = L("无法恢复文件标签：配置格式不正确。"); return }
        var restored: [(FileWorkspaceSession.Document, LocalFileDocument)] = []
        var failures: [String] = []
        for saved in session.documents {
            let url = rootURL.appendingPathComponent(saved.path).standardizedFileURL
            // Load pinned first so restoring a preview cannot replace another tab.
            open(url, preview: false)
            if let document = documents.first(where: { $0.url == url }) {
                restored.append((saved, document))
            } else { failures.append(saved.path) }
        }
        for (saved, document) in restored {
            document.isPreview = saved.isPreview
            document.markdownPreview = saved.markdownPreview && document.language == .markdown
            document.markdownPreviewOnly = (saved.markdownPreviewOnly ?? false) && document.language == .markdown
        }
        selectedDocumentID = restored.first(where: { $0.0.path == session.selectedPath })?.1.id ?? restored.last?.1.id
        if !failures.isEmpty {
            error = L("部分文件标签无法恢复（文件可能已删除、移动或无法读取）：") + failures.joined(separator: "、")
        }
    }
}
