import SwiftUI
import UniformTypeIdentifiers

struct ExportView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var appState: AppState

    let bgSecondary = Color(hex: "181825")
    let bgPrimary = Color(hex: "1e1e2e")
    let accent = Color(hex: "cba6f7")
    let textPrimary = Color(hex: "cdd6f4")
    let textSecondary = Color(hex: "a6adc8")
    let textMuted = Color(hex: "6c7086")
    let border = Color(hex: "45475a")

    @State private var compilePreview: CompilePreview?
    @State private var isLoading = true
    @State private var isExporting = false
    @State private var exportFormat: ExportFormat = .pdf
    @State private var exportError: String = ""
    @State private var exportedURL: URL?
    @State private var exportSuccess = false
    @State private var activeTab: ExportTab = .preview

    enum ExportFormat: String, CaseIterable, Identifiable {
        case pdf = "PDF", docx = "DOCX", vellum = "Vellum DOCX",
             md = "Markdown", txt = "Plain Text", html = "HTML", epub = "ePub",
             rtf = "RTF", opml = "OPML", bundle = "ZIP Bundle"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .pdf: return "doc.fill"
            case .docx: return "doc.richtext.fill"
            case .vellum: return "book.pages.fill"
            case .md: return "doc.plaintext.fill"
            case .txt: return "doc.text.fill"
            case .html: return "globe"
            case .epub: return "book.closed.fill"
            case .rtf: return "doc.richtext"
            case .opml: return "list.bullet.indent"
            case .bundle: return "doc.zipper"
            }
        }

        var description: String {
            switch self {
            case .pdf: return "Print-ready PDF with formatting"
            case .docx: return "Microsoft Word document (standard)"
            case .vellum: return "Vellum-compatible — auto-detects chapters & scene breaks"
            case .md: return "Raw markdown, all chapters merged"
            case .txt: return "Plain text, no formatting"
            case .html: return "Standalone web page, styled for reading"
            case .epub: return "E-book format for Kindle, iBooks, etc."
            case .rtf: return "Rich Text Format (universal)"
            case .opml: return "Outline editor format (chapters only)"
            case .bundle: return "ZIP with all chapters + manifest.json"
            }
        }

        /// Path on the backend
        var apiPath: String {
            switch self {
            case .pdf: return "export/pdf"
            case .docx: return "export/docx"
            case .vellum: return "export/vellum"
            case .md: return "export/md"
            case .txt: return "export/txt"
            case .html: return "export/html"
            case .epub: return "export/epub"
            case .rtf: return "export/rtf"
            case .opml: return "export/opml"
            case .bundle: return "export/bundle"
            }
        }
    }

    enum ExportTab: String, CaseIterable {
        case preview = "Preview"
        case export = "Export"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 16))
                    .foregroundColor(accent)
                Text("Compile & Export")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(textPrimary)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(textMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(bgSecondary)

            Divider().background(border)

            HStack(spacing: 0) {
                ForEach(ExportTab.allCases, id: \.rawValue) { tab in
                    Button(action: { activeTab = tab }) {
                        Text(tab.rawValue.uppercased())
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(activeTab == tab ? accent : textMuted)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(activeTab == tab ? accent.opacity(0.12) : Color.clear)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .background(bgSecondary)
            .overlay(
                Rectangle()
                    .fill(border)
                    .frame(height: 1),
                alignment: .bottom
            )

            if activeTab == .preview {
                previewTab
            } else {
                exportTab
            }
        }
        .frame(width: 660, height: 560)
        .background(bgPrimary)
        .onAppear { loadPreview() }
    }

    private var previewTab: some View {
        VStack(spacing: 0) {
            if isLoading {
                Spacer()
                ProgressView()
                    .scaleEffect(1.2)
                Text("Compiling preview...")
                    .font(.system(size: 13))
                    .foregroundColor(textMuted)
                    .padding(.top, 12)
                Spacer()
            } else if let preview = compilePreview {
                HStack(spacing: 20) {
                    statPill(icon: "book.fill", value: "\(preview.chapterCount)", label: "chapters")
                    statPill(icon: "text.word.spacing", value: "\(preview.wordCount)", label: "words")
                    statPill(icon: "person.fill", value: preview.author.isEmpty ? "—" : preview.author, label: "author")
                    statPill(icon: "tag.fill", value: preview.genre.isEmpty ? "—" : preview.genre, label: "genre")
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(bgSecondary)

                Divider().background(border)

                ScrollView {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(preview.content)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(textPrimary)
                            .textSelection(.enabled)
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .background(bgPrimary)
            } else {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundColor(Color(hex: "f9e2af"))
                    Text("No project selected")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(textSecondary)
                    Text("Select or create a project to compile your book.")
                        .font(.system(size: 12))
                        .foregroundColor(textMuted)
                }
                Spacer()
            }
        }
    }

    private var exportTab: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("SELECT FORMAT")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(accent)
                    Rectangle()
                        .fill(accent.opacity(0.3))
                        .frame(height: 1)

                    ForEach(ExportFormat.allCases) { format in
                        Button(action: { exportFormat = format }) {
                            HStack(spacing: 14) {
                                Image(systemName: format.icon)
                                    .font(.system(size: 18))
                                    .foregroundColor(exportFormat == format ? accent : textMuted)
                                    .frame(width: 24)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(format.rawValue)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(exportFormat == format ? textPrimary : textSecondary)
                                    Text(format.description)
                                        .font(.system(size: 11))
                                        .foregroundColor(textMuted)
                                }

                                Spacer()

                                if exportFormat == format {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 16))
                                        .foregroundColor(accent)
                                }
                            }
                            .padding(14)
                            .background(exportFormat == format ? accent.opacity(0.1) : bgSecondary)
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(exportFormat == format ? accent.opacity(0.5) : border, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    if !exportError.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(Color(hex: "f38ba8"))
                            Text(exportError)
                                .font(.system(size: 12))
                                .foregroundColor(Color(hex: "f38ba8"))
                        }
                        .padding(12)
                        .background(Color(hex: "f38ba8").opacity(0.1))
                        .cornerRadius(6)
                    }

                    if exportSuccess {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(Color(hex: "a6e3a1"))
                            Text("Exported successfully! Click 'Open File' to view it.")
                                .font(.system(size: 12))
                                .foregroundColor(Color(hex: "a6e3a1"))
                            Button("Open File") {
                                if let url = exportedURL {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(accent)
                        }
                        .padding(12)
                        .background(Color(hex: "a6e3a1").opacity(0.1))
                        .cornerRadius(6)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("EXPORT INFO")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(accent)
                        Rectangle()
                            .fill(accent.opacity(0.3))
                            .frame(height: 1)

                        if let preview = compilePreview {
                            infoRow("Title", preview.title)
                            infoRow("Chapters", "\(preview.chapterCount)")
                            infoRow("Word count", "\(preview.wordCount)")
                            infoRow("Author", preview.author.isEmpty ? "— (set in Settings)" : preview.author)
                            infoRow("Output", "~/Downloads/")
                        }
                    }
                }
                .padding(24)
            }

            Spacer()

            Divider().background(border)

            HStack {
                if let url = exportedURL {
                    Button("Open File") {
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(.bordered)
                }

                if exportSuccess {
                    Button("Re-export") {
                        exportSuccess = false
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(textSecondary)
                }

                Spacer()

                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .foregroundColor(textSecondary)

                Button(action: performExport) {
                    HStack(spacing: 6) {
                        if isExporting {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 14, height: 14)
                        }
                        Image(systemName: "square.and.arrow.down")
                        Text(isExporting ? "Exporting..." : "Export \(exportFormat.rawValue)")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isExporting || appState.currentProject == nil || compilePreview == nil)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(bgSecondary)
        }
    }

    private func statPill(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(accent)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(textPrimary)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(textMuted)
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text("\(label):")
                .font(.system(size: 12))
                .foregroundColor(textMuted)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(textSecondary)
        }
    }

    private func loadPreview() {
        guard let project = appState.currentProject else {
            isLoading = false
            return
        }
        isLoading = true
        Task {
            do {
                let preview: CompilePreview = try await BackendService.shared.get(
                    "/api/projects/\(project.id)/compile"
                )
                compilePreview = preview
            } catch {
                print("Preview error: \(error)")
            }
            isLoading = false
        }
    }

    private func performExport() {
        guard let project = appState.currentProject else { return }
        isExporting = true
        exportError = ""
        exportSuccess = false
        exportedURL = nil

        Task {
            do {
                let data: Data = try await BackendService.shared.getRawData(
                    "/api/projects/\(project.id)/\(exportFormat.apiPath)"
                )
                let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
                let safeName = (compilePreview?.title ?? project.name).replacingOccurrences(of: " ", with: "-")
                // Map formats to file extensions
                let ext: String = {
                    switch exportFormat {
                    case .pdf: return "pdf"
                    case .docx: return "docx"
                    case .vellum: return "docx"
                    case .md: return "md"
                    case .txt: return "txt"
                    case .html: return "html"
                    case .epub: return "epub"
                    case .rtf: return "rtf"
                    case .opml: return "opml"
                    case .bundle: return "zip"
                    }
                }()
                let fileURL = downloadsURL.appendingPathComponent("\(safeName).\(ext)")
                try data.write(to: fileURL)
                exportedURL = fileURL
                exportSuccess = true
            } catch {
                exportError = error.localizedDescription
            }
            isExporting = false
        }
    }
}
