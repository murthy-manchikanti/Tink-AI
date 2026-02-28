import SwiftUI
import SwiftUIMath
import UniformTypeIdentifiers
import Vision
import ImageIO

struct TextPart: Identifiable {
    let id = UUID()
    let content: String
    let isMath: Bool
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let content: String
    let isUser: Bool
}

struct ChatSession: Identifiable {
    let id = UUID()
    var title: String
    var messages: [ChatMessage]
    var uploadedFileName: String = ""
    var uploadedFileContent: String = ""
}

enum UploadStatus: Equatable {
    case idle
    case processing(message: String)
    case success(fileName: String)
    case failure(message: String)
}

// ────────────────────────────────────────────────
// MARK: - Splash / Loading Screen
// ────────────────────────────────────────────────

struct SplashLoadingView: View {
    let progress: Double
    let statusMessage: String
    
    var body: some View {
        VStack(spacing: 40) {
            Spacer()
            
            // Replace "AppLogo" with your actual logo asset name in Assets.xcassets
            Image("LoadingLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 50, height: 50)
            
            VStack(spacing: 16) {
                ProgressView(value: progress, total: 1.0)
                    .progressViewStyle(.linear)
                    .frame(width: 280, height: 10)
                    .tint(.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                
                Text(statusMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.darkGray).opacity(0.12))
    }
}

// ────────────────────────────────────────────────
// MARK: - Main Content View
// ────────────────────────────────────────────────

struct ContentView: View {
    @State private var engine = LLMEngine()
    @State private var userQuery = ""
    @State private var messages: [ChatMessage] = []
    @State private var chatSessions: [ChatSession] = []
    @State private var currentSessionId: UUID?
    @State private var isFileImporterPresented = false
    @State private var uploadStatus: UploadStatus = .idle
    @State private var showMainInterface = false
    
    private var isProcessingUpload: Bool {
        if case .processing = uploadStatus {
            return true
        }
        return false
    }
    
    private var canSend: Bool {
        !userQuery.isEmpty && !engine.isGenerating && !isProcessingUpload
    }
    
    var currentSession: ChatSession? {
        chatSessions.first { $0.id == currentSessionId }
    }
    
    var body: some View {
        ZStack {
            // Main interface – shown after loading
            if showMainInterface {
                NavigationSplitView {
                    sidebarView
                } detail: {
                    mainChatView
                }
                .transition(.opacity.animation(.easeInOut(duration: 0.6)))
            }
            
            // Splash screen – shown during model loading
            if !showMainInterface {
                SplashLoadingView(
                    progress: engine.loadProgress,
                    statusMessage: engine.statusMessage
                )
                .transition(.opacity)
            }
        }
        .task {
            await engine.loadModel()
            
            // Brief pause so user sees "Ready!" state
            try? await Task.sleep(for: .seconds(0.9))
            
            withAnimation {
                showMainInterface = true
            }
        }
        .onAppear {
            if chatSessions.isEmpty {
                createNewSession()
            } else if currentSessionId == nil {
                currentSessionId = chatSessions.first?.id
            }
        }
    }
    
    // ────────────────────────────────────────────────
    // MARK: - Sidebar
    // ────────────────────────────────────────────────
    
    private var sidebarView: some View {
        VStack(spacing: 0) {
            Button(action: createNewSession) {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                    Text("New Chat")
                    Spacer()
                }
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.white)
                .padding()
                .background(Color.blue)
                .cornerRadius(12)
            }
            .padding()
            .buttonStyle(.plain)
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(chatSessions) { session in
                        chatSessionButton(session)
                    }
                }
                .padding()
            }
            
            Spacer()
        }
        .frame(minWidth: 250)
        .background(Color.gray.opacity(0.05))
    }
    
    private func chatSessionButton(_ session: ChatSession) -> some View {
        Button(action: {
            currentSessionId = session.id
            updateMessagesForSession()
        }) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(.body)
                        .lineLimit(1)
                    if !session.uploadedFileName.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.fill")
                                .font(.caption2)
                            Text(session.uploadedFileName)
                                .font(.caption2)
                        }
                        .foregroundStyle(.green)
                    }
                }
                Spacer()
            }
            .padding()
            .background(currentSessionId == session.id ? Color.blue.opacity(0.2) : Color.clear)
            .cornerRadius(8)
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete", role: .destructive) {
                deleteSession(session.id)
            }
        }
    }
    
    private func createNewSession() {
        let newSession = ChatSession(title: "Chat \(chatSessions.count + 1)", messages: [], uploadedFileName: "", uploadedFileContent: "")
        chatSessions.append(newSession)
        currentSessionId = newSession.id
        updateMessagesForSession()
    }
    
    private func updateMessagesForSession() {
        if let session = currentSession {
            messages = session.messages
            if !session.uploadedFileContent.isEmpty {
                engine.setUploadedFile(name: session.uploadedFileName, content: session.uploadedFileContent)
            } else {
                engine.clearUploadedFile()
            }
        }
    }
    
    private func deleteSession(_ id: UUID) {
        chatSessions.removeAll { $0.id == id }
        if currentSessionId == id {
            if !chatSessions.isEmpty {
                currentSessionId = chatSessions.first?.id
            } else {
                createNewSession()
            }
        }
        updateMessagesForSession()
    }
    
    // ────────────────────────────────────────────────
    // MARK: - File Handling
    // ────────────────────────────────────────────────
    
    private func handleFileSelection(result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let isAccessing = url.startAccessingSecurityScopedResource()
            defer { if isAccessing { url.stopAccessingSecurityScopedResource() } }
            
            do {
                let data = try Data(contentsOf: url)
                let fileName = url.lastPathComponent
                let fileType = UTType(filenameExtension: url.pathExtension)
                
                if fileType?.conforms(to: .image) == true {
                    uploadStatus = .processing(message: "Extracting text from image...")
                    Task {
                        let extracted = await extractTextFromImageData(data)
                        await MainActor.run {
                            if extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                uploadStatus = .failure(message: "No readable text found in image.")
                                return
                            }
                            updateCurrentSessionFile(fileName: fileName, content: extracted)
                            uploadStatus = .success(fileName: fileName)
                        }
                    }
                    return
                }
                
                if let text = String(data: data, encoding: .utf8) {
                    updateCurrentSessionFile(fileName: fileName, content: text)
                    uploadStatus = .success(fileName: fileName)
                } else {
                    uploadStatus = .failure(message: "Unsupported file format.")
                }
            } catch {
                uploadStatus = .failure(message: "Failed to read file.")
                print("File read error: \(error)")
            }
            
        case .failure(let error):
            uploadStatus = .failure(message: "File selection failed.")
            print("File picker error: \(error)")
        }
    }
    
    private func updateCurrentSessionFile(fileName: String, content: String) {
        if let index = chatSessions.firstIndex(where: { $0.id == currentSessionId }) {
            chatSessions[index].uploadedFileName = fileName
            chatSessions[index].uploadedFileContent = content
            engine.setUploadedFile(name: fileName, content: content)
        }
    }
    
    private func clearSessionFile() {
        if let index = chatSessions.firstIndex(where: { $0.id == currentSessionId }) {
            chatSessions[index].uploadedFileName = ""
            chatSessions[index].uploadedFileContent = ""
        }
        engine.clearUploadedFile()
        uploadStatus = .idle
    }
    
    private func extractTextFromImageData(_ data: Data) async -> String {
        await Task.detached(priority: .userInitiated) {
            guard let cgImage = await cgImageFromData(data) else { return "" }
            
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return ""
            }
            
            let observations = request.results ?? []
            return observations
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        }.value
    }
    
    private func cgImageFromData(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    
    // ────────────────────────────────────────────────
    // MARK: - Main Chat Interface
    // ────────────────────────────────────────────────
    
    private var mainChatView: some View {
        ZStack(alignment: .bottom) {
            Color.gray.opacity(0.05).ignoresSafeArea()
            
            VStack(spacing: 0) {
                
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 20) {
                            ForEach(messages) { message in
                                MessageBubble(message: message)
                            }
                            
                            if !engine.outputText.isEmpty || engine.isGenerating {
                                MessageBubble(message: ChatMessage(content: engine.outputText, isUser: false))
                                    .id("streaming")
                            }
                        }
                        .padding(.top, 20)
                        .padding(.bottom, 100)
                    }
                    .onChange(of: engine.outputText) { _, _ in
                        withAnimation {
                            proxy.scrollTo("streaming", anchor: .bottom)
                        }
                    }
                }
            }
            
            inputArea
        }
    }
    
    private var inputArea: some View {
        VStack(spacing: 0) {
            uploadStatusView
            
            if let session = currentSession, !session.uploadedFileName.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "doc.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("File:").font(.caption.bold())
                        Text(session.uploadedFileName).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: clearSessionFile) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
                .padding(.horizontal)
                .padding(.top, 8)
                
                if !session.uploadedFileContent.isEmpty {
                    Text("Extracted text: \(session.uploadedFileContent.prefix(160))…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }
            }
            
            Divider()
            
            HStack(alignment: .bottom, spacing: 12) {
                Menu {
                    Button(action: { isFileImporterPresented = true }) {
                        Label("Upload File", systemImage: "doc")
                    }
                } label: {
                    Image(systemName: "paperclip")
                        .foregroundStyle(.blue)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                
                TextField("Ask a question...", text: $userQuery, axis: .vertical)
                    .padding(12)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(12)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                
                Button(action: sendMessage) {
                    ZStack {
                        Circle()
                            .fill(canSend ? Color.blue : Color.gray.opacity(0.3))
                            .frame(width: 32, height: 32)
                        
                        if engine.isGenerating {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .padding(.bottom, 4)
            }
            .padding()
            .background(.ultraThinMaterial)
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.plainText, .pdf, .image, .png, .jpeg],
            onCompletion: handleFileSelection
        )
    }
    
    private var uploadStatusView: some View {
        Group {
            switch uploadStatus {
            case .idle: EmptyView()
            case .processing(let message):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.orange.opacity(0.08))
                .cornerRadius(8)
                .padding(.horizontal).padding(.top, 8)
                
            case .success(let fileName):
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Uploaded \(fileName)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.green.opacity(0.08))
                .cornerRadius(8)
                .padding(.horizontal).padding(.top, 8)
                
            case .failure(let message):
                HStack(spacing: 8) {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.red.opacity(0.08))
                .cornerRadius(8)
                .padding(.horizontal).padding(.top, 8)
            }
        }
    }
    
    private func sendMessage() {
        let query = userQuery
        userQuery = ""
        
        let userMessage = ChatMessage(content: query, isUser: true)
        messages.append(userMessage)
        updateCurrentSession()
        
        if let session = currentSession {
            if !session.uploadedFileContent.isEmpty {
                engine.setUploadedFile(name: session.uploadedFileName, content: session.uploadedFileContent)
            } else {
                engine.clearUploadedFile()
            }
        }
        
        Task {
            await engine.ask(query)
            
            let aiMessage = ChatMessage(content: engine.outputText, isUser: false)
            messages.append(aiMessage)
            updateCurrentSession()
            
            engine.outputText = ""
        }
    }
    
    private func updateCurrentSession() {
        if let index = chatSessions.firstIndex(where: { $0.id == currentSessionId }) {
            chatSessions[index].messages = messages
            
            // Auto-update title from first user message if still default
            if chatSessions[index].title.hasPrefix("Chat") && messages.count <= 2 {
                if let firstUser = messages.first(where: { $0.isUser }) {
                    let preview = String(firstUser.content.prefix(30))
                    chatSessions[index].title = preview.isEmpty ? "Chat \(index + 1)" : preview
                }
            }
        }
    }
}

// ────────────────────────────────────────────────
// MARK: - Message Rendering
// ────────────────────────────────────────────────

struct MessageBubble: View {
    let message: ChatMessage
    
    var body: some View {
        HStack(alignment: .top) {
            if message.isUser { Spacer() }
            
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                if message.isUser {
                    Text(message.content)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                } else {
                    AIContentView(text: message.content)
                }
            }
            
            if !message.isUser { Spacer() }
        }
        .padding(.horizontal, 16)
    }
}

struct AIContentView: View {
    let text: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let parts = parseContent(text)
            ForEach(parts) { part in
                if part.isMath {
                    Math(part.content)
                        .font(.system(size: 20))
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.08)))
                } else {
                    Text(part.content)
                        .font(.body)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(16)
        .background(Color.gray.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    private func parseContent(_ text: String) -> [TextPart] {
        var result: [TextPart] = []
        let pattern = #"(\$\$.*?\$\$|\$.*?\$)"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let nsString = text as NSString
        let matches = regex?.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length)) ?? []
        
        var lastEnd = 0
        for match in matches {
            let textRange = NSRange(location: lastEnd, length: match.range.location - lastEnd)
            if textRange.length > 0 {
                result.append(TextPart(content: nsString.substring(with: textRange), isMath: false))
            }
            
            var mathStr = nsString.substring(with: match.range)
            mathStr = mathStr.hasPrefix("$$") ? String(mathStr.dropFirst(2).dropLast(2)) : String(mathStr.dropFirst().dropLast())
            
            result.append(TextPart(content: mathStr, isMath: true))
            lastEnd = match.range.location + match.range.length
        }
        
        if lastEnd < nsString.length {
            result.append(TextPart(content: nsString.substring(from: lastEnd), isMath: false))
        }
        return result
    }
}
