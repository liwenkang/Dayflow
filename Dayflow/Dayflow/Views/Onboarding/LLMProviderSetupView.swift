//
//  LLMProviderSetupView.swift
//  Dayflow
//
//  LLM provider setup flow with step-by-step configuration
//

import SwiftUI
import Foundation

private let cliSearchPaths: [String] = {
    let home = NSHomeDirectory()
    return [
        "/usr/local/bin",
        "/opt/homebrew/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
        "\(home)/.npm-global/bin",
        "\(home)/.local/bin",
        "\(home)/.cargo/bin",
        "\(home)/.bun/bin",
        "\(home)/.pyenv/bin",
        "\(home)/.pyenv/shims",
        "\(home)/.npm-global/lib/node_modules/@openai/codex/vendor/aarch64-apple-darwin/path",
        "\(home)/.codeium/windsurf/bin",
        "\(home)/.lmstudio/bin"
    ]
}()

struct CLIResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

@discardableResult
func runCLI(
    _ command: String,
    args: [String] = [],
    env: [String: String]? = nil,
    cwd: URL? = nil
) throws -> CLIResult {
    let process = Process()
    let expandedCommand = (command as NSString).expandingTildeInPath
    if expandedCommand.hasPrefix("/") {
        guard FileManager.default.isExecutableFile(atPath: expandedCommand) else {
            throw NSError(domain: "StreamingCLI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Executable not found: \(expandedCommand)"])
        }
        process.executableURL = URL(fileURLWithPath: expandedCommand)
        process.arguments = args
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [expandedCommand] + args
    }
    process.currentDirectoryURL = cwd
    
    var environment = ProcessInfo.processInfo.environment
    if let overrides = env {
        environment.merge(overrides, uniquingKeysWith: { _, new in new })
    }
    
    var pathComponents: [String] = environment["PATH"]
        .map { $0.split(separator: ":").map { String($0) } } ?? []
    for rawPath in cliSearchPaths {
        let expanded = (rawPath as NSString).expandingTildeInPath
        if !pathComponents.contains(expanded) {
            pathComponents.append(expanded)
        }
    }
    environment["PATH"] = pathComponents.joined(separator: ":")
    environment["HOME"] = environment["HOME"] ?? NSHomeDirectory()
    process.environment = environment
    
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    
    try process.run()
    process.waitUntilExit()
    
    let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    
    return CLIResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
}

final class StreamingCLI {
    private var process: Process?
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    
    func cancel() {
        process?.terminate()
    }
    
    func run(
        command: String,
        args: [String],
        env: [String: String]? = nil,
        cwd: URL? = nil,
        onStdout: @escaping (String) -> Void,
        onStderr: @escaping (String) -> Void,
        onFinish: @escaping (Int32) -> Void
    ) {
        let proc = Process()
        process = proc
        
        let expandedCommand = (command as NSString).expandingTildeInPath
        if expandedCommand.hasPrefix("/") {
            guard FileManager.default.isExecutableFile(atPath: expandedCommand) else {
                DispatchQueue.main.async {
                    onStderr("Executable not found or not executable: \(expandedCommand)\n")
                    onFinish(-1)
                }
                return
            }
            proc.executableURL = URL(fileURLWithPath: expandedCommand)
            proc.arguments = args
        } else {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = [expandedCommand] + args
        }
        proc.currentDirectoryURL = cwd
        
        var environment = ProcessInfo.processInfo.environment
        if let overrides = env {
            environment.merge(overrides, uniquingKeysWith: { _, new in new })
        }
        var pathComponents: [String] = environment["PATH"]
            .map { $0.split(separator: ":").map { String($0) } } ?? []
        for rawPath in cliSearchPaths {
            let expanded = (rawPath as NSString).expandingTildeInPath
            if !pathComponents.contains(expanded) {
                pathComponents.append(expanded)
            }
        }
        environment["PATH"] = pathComponents.joined(separator: ":")
        environment["HOME"] = environment["HOME"] ?? NSHomeDirectory()
        proc.environment = environment
        
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                onStdout(chunk)
            }
        }
        
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                onStderr(chunk)
            }
        }
        
        do {
            try proc.run()
            proc.terminationHandler = { process in
                self.stdoutPipe.fileHandleForReading.readabilityHandler = nil
                self.stderrPipe.fileHandleForReading.readabilityHandler = nil
                DispatchQueue.main.async {
                    onFinish(process.terminationStatus)
                }
            }
        } catch {
            DispatchQueue.main.async {
                onStderr("Failed to start \(command): \(error.localizedDescription)")
                onFinish(-1)
            }
        }
    }
}

struct LLMProviderSetupView: View {
    let providerType: String // "ollama" or "gemini"
    let onBack: () -> Void
    let onComplete: () -> Void
    
    private var activeProviderType: String {
        providerType == "chatgpt_claude" ? "gemini" : providerType
    }
    
    // Layout constants
    private let sidebarWidth: CGFloat = 250
    private let fixedOffset: CGFloat = 50
    
    @StateObject private var setupState = ProviderSetupState()
    @State private var sidebarOpacity: Double = 0
    @State private var contentOpacity: Double = 0
    @State private var nextButtonHovered: Bool = false // legacy, unused after refactor
    @State private var googleButtonHovered: Bool = false // legacy, unused after refactor
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with Back button and Title on same line
            HStack(alignment: .center, spacing: 0) {
                // Back button container matching sidebar width
                HStack {
                    Button(action: handleBack) {
                        HStack(spacing: 12) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.black.opacity(0.7))
                                .frame(width: 20, alignment: .center)
                            
                            Text("Back")
                                .font(.custom("Nunito", size: 15))
                                .fontWeight(.medium)
                                .foregroundColor(.black.opacity(0.7))
                        }
                    }
                    .buttonStyle(.plain)
                    // Position where sidebar items start: 20 + 16 = 36px
                    .padding(.leading, 36) // Align with sidebar item structure
                    .pointingHandCursor()
                    
                    Spacer()
                }
                .frame(width: sidebarWidth)
                
                // Title in the content area
                HStack {
                    Text(activeProviderType == "ollama" ? "Use local AI" : "Bring your own API keys")
                        .font(.custom("Nunito", size: 32))
                        .fontWeight(.semibold)
                        .foregroundColor(.black.opacity(0.9))
                    
                    Spacer()
                }
                .padding(.leading, 40) // Gap between sidebar and content
            }
            .padding(.leading, fixedOffset)
            .padding(.top, fixedOffset)
            .padding(.bottom, 40)
            
            // Main content area with sidebar and content
            HStack(alignment: .top, spacing: 40) {
                // Sidebar - fixed width 250px
                VStack(alignment: .leading, spacing: 0) {
                    SetupSidebarView(
                        steps: setupState.steps,
                        currentStepId: setupState.currentStep.id,
                        onStepSelected: { setupState.navigateToStep($0) }
                    )
                    Spacer()
                }
                .frame(width: sidebarWidth)
                .opacity(sidebarOpacity)
                
                // Content area - wrapped in VStack to match sidebar alignment
                VStack(alignment: .leading, spacing: 0) {
                    currentStepContent
                        .frame(maxWidth: 500, alignment: .leading)
                    Spacer()
                }
                .opacity(contentOpacity)
                .textSelection(.enabled)
            }
            .padding(.leading, fixedOffset)
            
            Spacer() // Push everything to top
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            setupState.configureSteps(for: activeProviderType)
            animateAppearance()
        }
        .preferredColorScheme(.light)
    }
    
    private var nextButtonText: String {
        if let title = setupState.currentStep.contentType.informationTitle {
            if (title == "Testing" || title == "Test Connection") && !setupState.testSuccessful {
                return "Test Required"
            }
        }
        return "Next"
    }
    
    @ViewBuilder
    private var nextButton: some View {
        if setupState.isLastStep {
            DayflowSurfaceButton(
                action: { saveConfiguration(); onComplete() },
                content: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 14))
                        Text("Complete Setup").font(.custom("Nunito", size: 14)).fontWeight(.semibold)
                    }
                },
                background: Color(red: 0.25, green: 0.17, blue: 0),
                foreground: .white,
                borderColor: .clear,
                cornerRadius: 8,
                horizontalPadding: 24,
                verticalPadding: 12,
                showOverlayStroke: true
            )
        } else {
            DayflowSurfaceButton(
                action: handleContinue,
                content: {
                    HStack(spacing: 6) {
                        Text(nextButtonText).font(.custom("Nunito", size: 14)).fontWeight(.semibold)
                        if nextButtonText == "Next" {
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium))
                        }
                    }
                },
                background: Color(red: 0.25, green: 0.17, blue: 0),
                foreground: .white,
                borderColor: .clear,
                cornerRadius: 8,
                horizontalPadding: 24,
                verticalPadding: 12,
                showOverlayStroke: true
            )
            .disabled(!setupState.canContinue)
            .opacity(!setupState.canContinue ? 0.5 : 1.0)
        }
    }
    
    @ViewBuilder
    private var currentStepContent: some View {
        let step = setupState.currentStep
        
        switch step.contentType {
        case .localChoice:
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Choose your local AI engine")
                        .font(.custom("Nunito", size: 24))
                        .fontWeight(.semibold)
                        .foregroundColor(.black.opacity(0.9))
                    Text("We strongly recommend LM Studio for the best reliability. Ollama is also supported, but tends to have more connection and timeout issues.")
                        .font(.custom("Nunito", size: 14))
                        .foregroundColor(.black.opacity(0.6))
                }
                HStack(alignment: .center, spacing: 12) {
                    DayflowSurfaceButton(
                        action: { setupState.selectEngine(.lmstudio); openLMStudioDownload() },
                        content: {
                            AsyncImage(url: URL(string: "https://lmstudio.ai/_next/image?url=%2F_next%2Fstatic%2Fmedia%2Flmstudio-app-logo.11b4d746.webp&w=96&q=75")) { phase in
                                switch phase {
                                case .success(let image): image.resizable().scaledToFit()
                                case .failure(_): Image(systemName: "desktopcomputer").resizable().scaledToFit().foregroundColor(.white.opacity(0.6))
                                case .empty: ProgressView().scaleEffect(0.7)
                                @unknown default: EmptyView()
                                }
                            }
                            .frame(width: 18, height: 18)
                            Text("Download LM Studio")
                                .font(.custom("Nunito", size: 14))
                                .fontWeight(.semibold)
                        },
                        background: Color(red: 0.25, green: 0.17, blue: 0),
                        foreground: .white,
                        borderColor: .clear,
                        cornerRadius: 8,
                        showOverlayStroke: true
                    )
                    Text("or")
                        .font(.custom("Nunito", size: 13))
                        .foregroundColor(.black.opacity(0.5))
                        .padding(.horizontal, 4)
                    DayflowSurfaceButton(
                        action: { setupState.selectEngine(.ollama); openOllamaDownload() },
                        content: {
                            AsyncImage(url: URL(string: "https://ollama.com/public/ollama.png")) { phase in
                                switch phase {
                                case .success(let image):
                                    image
                                        .renderingMode(.template)
                                        .resizable()
                                        .scaledToFit()
                                        .foregroundColor(.white)
                                case .failure(_): Image(systemName: "shippingbox").resizable().scaledToFit().foregroundColor(.white.opacity(0.6))
                                case .empty: ProgressView().scaleEffect(0.7)
                                @unknown default: EmptyView()
                                }
                            }
                            .frame(width: 18, height: 18)
                            Text("Download Ollama")
                                .font(.custom("Nunito", size: 14))
                                .fontWeight(.semibold)
                        },
                        background: Color(red: 0.25, green: 0.17, blue: 0),
                        foreground: .white,
                        borderColor: .clear,
                        cornerRadius: 8,
                        showOverlayStroke: true
                    )
                }
                Text("Already have a local server? Make sure it’s OpenAI-compatible. You can set a custom base URL in the next step.")
                    .font(.custom("Nunito", size: 13))
                    .foregroundColor(.black.opacity(0.6))
                HStack { Spacer(); nextButton }
            }
        case .localModelInstall:
            VStack(alignment: .leading, spacing: 16) {
                Text("Install Qwen 2.5 VLM")
                    .font(.custom("Nunito", size: 24))
                    .fontWeight(.semibold)
                    .foregroundColor(.black.opacity(0.9))
                if setupState.localEngine == .ollama {
                    Text("After installing Ollama, run this in your terminal to download the model (≈3GB):")
                        .font(.custom("Nunito", size: 14))
                        .foregroundColor(.black.opacity(0.6))
                    TerminalCommandView(
                        title: "Run this command:",
                        subtitle: "Downloads Qwen 2.5 Vision 3B for Ollama",
                        command: "ollama pull qwen2.5vl:3b"
                    )
                } else if setupState.localEngine == .lmstudio {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("After installing LM Studio, download the recommended model:")
                            .font(.custom("Nunito", size: 14))
                            .foregroundColor(.black.opacity(0.6))

                        DayflowSurfaceButton(
                            action: openLMStudioModelDownload,
                            content: {
                                HStack(spacing: 8) {
                                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 14))
                                    Text("Download Qwen 2.5 VL in LM Studio").font(.custom("Nunito", size: 14)).fontWeight(.semibold)
                                }
                            },
                            background: Color(red: 0.25, green: 0.17, blue: 0),
                            foreground: .white,
                            borderColor: .clear,
                            cornerRadius: 8,
                            horizontalPadding: 24,
                            verticalPadding: 12,
                            showOverlayStroke: true
                        )

                        VStack(alignment: .leading, spacing: 6) {
                            Text("This will open LM Studio and prompt you to download the model (≈3GB).")
                                .font(.custom("Nunito", size: 13))
                                .foregroundColor(.black.opacity(0.65))

                            Text("Once downloaded, turn on 'Local Server' in LM Studio (default http://localhost:1234)")
                                .font(.custom("Nunito", size: 13))
                                .foregroundColor(.black.opacity(0.65))
                        }
                        .padding(.top, 4)

                        // Fallback manual instructions
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Manual setup:")
                                .font(.custom("Nunito", size: 12))
                                .fontWeight(.semibold)
                                .foregroundColor(.black.opacity(0.5))
                            Text("1. Open LM Studio → Models tab")
                                .font(.custom("Nunito", size: 12))
                                .foregroundColor(.black.opacity(0.45))
                            Text("2. Search for 'Qwen2.5-VL-3B' and install the Instruct variant")
                                .font(.custom("Nunito", size: 12))
                                .foregroundColor(.black.opacity(0.45))
                        }
                        .padding(.top, 8)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Use any OpenAI-compatible VLM")
                            .font(.custom("Nunito", size: 16))
                            .fontWeight(.semibold)
                            .foregroundColor(.black.opacity(0.85))
                        Text("Make sure your server exposes the OpenAI Chat Completions API and has a Qwen 2.5 Vision model installed.")
                            .font(.custom("Nunito", size: 14))
                            .foregroundColor(.black.opacity(0.75))
                    }
                }
                HStack { Spacer(); nextButton }
            }
        case .terminalCommand(let command):
            VStack(alignment: .leading, spacing: 24) {
                TerminalCommandView(
                    title: "Terminal command:",
                    subtitle: "Copy the code below and try running it in your terminal",
                    command: command
                )
                
                HStack {
                    Spacer()
                    nextButton
                }
            }
            
        case .apiKeyInput:
            VStack(alignment: .leading, spacing: 24) {
                APIKeyInputView(
                    apiKey: $setupState.apiKey,
                    title: "Enter your API key:",
                    subtitle: "Paste your Gemini API key below",
                    placeholder: "AIza...",
                    onValidate: { key in
                        // Basic validation for now
                        return key.hasPrefix("AIza") && key.count > 30
                    }
                )

                VStack(alignment: .leading, spacing: 12) {
                    Text("Choose your Gemini model. If you're on the free tier, pick 2.5 Pro, it's the most powerful model and is completely free to use. If you're on a paid plan, which is not recommended, I recommend 2.5 Flash-Lite to minimize costs.")
                        .font(.custom("Nunito", size: 16))
                        .fontWeight(.semibold)
                        .foregroundColor(.black.opacity(0.85))

                    Picker("Gemini model", selection: $setupState.geminiModel) {
                        ForEach(GeminiModel.allCases, id: \.self) { model in
                            Text(model.shortLabel).tag(model)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(GeminiModelPreference(primary: setupState.geminiModel).fallbackSummary)
                        .font(.custom("Nunito", size: 13))
                        .foregroundColor(.black.opacity(0.55))
                }
                .onChange(of: setupState.geminiModel) {
                    setupState.persistGeminiModelSelection(source: "onboarding_picker")
                }
                
                HStack {
                    Spacer()
                    nextButton
                }
            }
            
        case .modelDownload(let command):
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Download the AI model")
                        .font(.custom("Nunito", size: 24))
                        .fontWeight(.semibold)
                        .foregroundColor(.black.opacity(0.9))
                    
                    Text("This model enables Dayflow to understand what's on your screen")
                        .font(.custom("Nunito", size: 14))
                        .foregroundColor(.black.opacity(0.6))
                }
                
                TerminalCommandView(
                    title: "Run this command:",
                    subtitle: "This will download the Qwen 2.5 Vision model (about 3GB)",
                    command: command
                )
                
                HStack {
                    Spacer()
                    nextButton
                }
            }
            
        case .information(let title, let description):
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(title)
                        .font(.custom("Nunito", size: 24))
                        .fontWeight(.semibold)
                        .foregroundColor(.black.opacity(0.9))
                    if !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(description)
                            .font(.custom("Nunito", size: 14))
                            .foregroundColor(.black.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                            .lineLimit(nil)
                        // Additional guidance for the local intro step
                        if step.id == "intro" {
                            (
                                Text("Advanced users can pick any ") +
                                Text("vision-capable").fontWeight(.bold) +
                                Text(" LLM, but we strongly recommend using Qwen 2.5-VL 3B based on our internal benchmarks.")
                            )
                            .font(.custom("Nunito", size: 14))
                            .foregroundColor(.black.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                        }
                    }
                }

                // Content area scrolls if needed; Next stays visible below
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 16) {
                        if title == "Testing" || title == "Test Connection" {
                            if providerType == "gemini" {
                                TestConnectionView(
                                    onTestComplete: { success in
                                        setupState.hasTestedConnection = true
                                        setupState.testSuccessful = success
                                    }
                                )
                            } else {
                                // Engine selection: Ollama, LM Studio, Other
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Which tool are you using?")
                                        .font(.custom("Nunito", size: 14))
                                        .foregroundColor(.black.opacity(0.65))
                                    Picker("Engine", selection: $setupState.localEngine) {
                                        Text("LM Studio").tag(LocalEngine.lmstudio)
                                        Text("Ollama").tag(LocalEngine.ollama)
                                        Text("Other").tag(LocalEngine.custom)
                                    }
                                    .pickerStyle(.segmented)
                                    .frame(maxWidth: 380)
                                }
                                .onChange(of: setupState.localEngine) { _, newValue in
                                    setupState.selectEngine(newValue)
                                }

                                LocalLLMTestView(
                                    baseURL: $setupState.localBaseURL,
                                    modelId: $setupState.localModelId,
                                    engine: setupState.localEngine,
                                    showInputs: setupState.localEngine == .custom,
                                    onTestComplete: { success in
                                        setupState.hasTestedConnection = true
                                        setupState.testSuccessful = success
                                    }
                                )
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 2)
                }
                .frame(maxHeight: 420)

                HStack {
                    Spacer()
                    nextButton
                }
            }
            
        case .cliDetection:
            ChatCLIDetectionStepView(
                codexStatus: setupState.codexCLIStatus,
                codexReport: setupState.codexCLIReport,
                claudeStatus: setupState.claudeCLIStatus,
                claudeReport: setupState.claudeCLIReport,
                isChecking: setupState.isCheckingCLIStatus,
                onRetry: { setupState.refreshCLIStatuses() },
                onInstall: { tool in openChatCLIInstallPage(for: tool) },
                debugCommand: $setupState.debugCommandInput,
                debugOutput: setupState.debugCommandOutput,
                isRunningDebug: setupState.isRunningDebugCommand,
                onRunDebug: { setupState.runDebugCommand() },
                cliPrompt: $setupState.cliPrompt,
                codexOutput: setupState.codexStreamOutput,
                claudeOutput: setupState.claudeStreamOutput,
                isRunningCodex: setupState.isRunningCodexStream,
                isRunningClaude: setupState.isRunningClaudeStream,
                onRunCodex: { setupState.runCodexStream() },
                onCancelCodex: { setupState.cancelCodexStream() },
                onRunClaude: { setupState.runClaudeStream() },
                onCancelClaude: { setupState.cancelClaudeStream() },
                nextButton: { nextButton }
            )
            .onAppear {
                setupState.ensureCLICheckStarted()
            }
            
        case .apiKeyInstructions:
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Get your Gemini API key")
                        .font(.custom("Nunito", size: 24))
                        .fontWeight(.semibold)
                        .foregroundColor(.black.opacity(0.9))
                    
                    Text("Google's Gemini offers a generous free tier that should allow you to run Dayflow 24/7 for free - no credit card required")
                        .font(.custom("Nunito", size: 14))
                        .foregroundColor(.black.opacity(0.6))
                }
                
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 12) {
                        Text("1.")
                            .font(.custom("Nunito", size: 14))
                            .foregroundColor(.black.opacity(0.6))
                            .frame(width: 20, alignment: .leading)
                        
                        Group {
                            Text("Visit Google AI Studio ")
                                .font(.custom("Nunito", size: 14))
                                .foregroundColor(.black.opacity(0.8))
                            + Text("(aistudio.google.com)")
                                .font(.custom("Nunito", size: 14))
                                .foregroundColor(Color(red: 1, green: 0.42, blue: 0.02))
                                .underline()
                        }
                        .onTapGesture { openGoogleAIStudio() }
                        .pointingHandCursor()
                    }
                    
                    HStack(alignment: .top, spacing: 12) {
                        Text("2.")
                            .font(.custom("Nunito", size: 14))
                            .foregroundColor(.black.opacity(0.6))
                            .frame(width: 20, alignment: .leading)
                        
                        Text("Click \"Get API key\" in the top right")
                            .font(.custom("Nunito", size: 14))
                            .foregroundColor(.black.opacity(0.8))
                    }
                    
                    HStack(alignment: .top, spacing: 12) {
                        Text("3.")
                            .font(.custom("Nunito", size: 14))
                            .foregroundColor(.black.opacity(0.6))
                            .frame(width: 20, alignment: .leading)
                        
                        Text("Create a new API key and copy it")
                            .font(.custom("Nunito", size: 14))
                            .foregroundColor(.black.opacity(0.8))
                    }
                }
                .padding(.vertical, 12)
                
                // Buttons row with Open Google AI Studio on left, Next on right
                HStack {
                    DayflowSurfaceButton(
                        action: openGoogleAIStudio,
                        content: {
                            HStack(spacing: 8) {
                                Image(systemName: "safari").font(.system(size: 14))
                                Text("Open Google AI Studio").font(.custom("Nunito", size: 14)).fontWeight(.semibold)
                            }
                        },
                        background: Color(red: 0.25, green: 0.17, blue: 0),
                        foreground: .white,
                        borderColor: .clear,
                        cornerRadius: 8,
                        horizontalPadding: 24,
                        verticalPadding: 12,
                        showOverlayStroke: true
                    )
                    Spacer()
                    nextButton
                }
            }
        }
    }
    
    private func handleBack() {
        if setupState.currentStepIndex == 0 {
            onBack()
        } else {
            setupState.goBack()
        }
    }
    
    private func handleContinue() {
        // Persist local config immediately after a successful local test when user advances
        if activeProviderType == "ollama" {
            if case .information(let title, _) = setupState.currentStep.contentType,
               (title == "Testing" || title == "Test Connection"),
               setupState.testSuccessful {
                persistLocalSettings()
            }
        }

        if setupState.isLastStep {
            saveConfiguration()
            onComplete()
        } else {
            setupState.markCurrentStepCompleted()
            setupState.goNext()
        }
    }
    
    private func saveConfiguration() {
        // Save API key to keychain for Gemini
        if activeProviderType == "gemini" && !setupState.apiKey.isEmpty {
            KeychainManager.shared.store(setupState.apiKey, for: "gemini")
            GeminiModelPreference(primary: setupState.geminiModel).save()
        }
        
        // Save local endpoint for local engine selection
        if activeProviderType == "ollama" {
            persistLocalSettings()
        }
        
        // Mark setup as complete
        UserDefaults.standard.set(true, forKey: "\(activeProviderType)SetupComplete")
    }

    // Persist provider choice + local settings without marking setup complete
    private func persistLocalSettings() {
        let endpoint = setupState.localBaseURL
        let type = LLMProviderType.ollamaLocal(endpoint: endpoint)
        if let encoded = try? JSONEncoder().encode(type) {
            UserDefaults.standard.set(encoded, forKey: "llmProviderType")
        }
        // Store model id for local engines
        UserDefaults.standard.set(setupState.localModelId, forKey: "llmLocalModelId")
        // Store local engine selection for header/model defaults
        UserDefaults.standard.set(setupState.localEngine.rawValue, forKey: "llmLocalEngine")
        // Store selected provider key for robustness across relaunches
        UserDefaults.standard.set("ollama", forKey: "selectedLLMProvider")
        // Also store the endpoint explicitly for other parts of the app if needed
        UserDefaults.standard.set(endpoint, forKey: "llmLocalBaseURL")
    }
    
    private func openGoogleAIStudio() {
        if let url = URL(string: "https://aistudio.google.com/app/apikey") {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func openOllamaDownload() {
        if let url = URL(string: "https://ollama.com/download") {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func openLMStudioDownload() {
        if let url = URL(string: "https://lmstudio.ai/") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openLMStudioModelDownload() {
        if let url = URL(string: "https://model.lmstudio.ai/download/lmstudio-community/Qwen2.5-VL-3B-Instruct-GGUF") {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func openChatCLIInstallPage(for tool: CLITool) {
        guard let url = tool.installURL else { return }
        NSWorkspace.shared.open(url)
    }
    
    private func animateAppearance() {
        withAnimation(.easeOut(duration: 0.4)) {
            sidebarOpacity = 1
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(.easeOut(duration: 0.4)) {
                contentOpacity = 1
            }
        }
    }
}

class ProviderSetupState: ObservableObject {
    @Published var steps: [SetupStep] = []
    @Published var currentStepIndex: Int = 0
    @Published var apiKey: String = ""
    @Published var hasTestedConnection: Bool = false
    @Published var testSuccessful: Bool = false
    @Published var geminiModel: GeminiModel
    // Local engine configuration
    @Published var localEngine: LocalEngine = .ollama
    @Published var localBaseURL: String = "http://localhost:11434"
    @Published var localModelId: String = "qwen2.5vl:3b"
    // CLI detection
    @Published var codexCLIStatus: CLIDetectionState = .unknown
    @Published var claudeCLIStatus: CLIDetectionState = .unknown
    @Published var isCheckingCLIStatus: Bool = false
    @Published var codexCLIReport: CLIDetectionReport?
    @Published var claudeCLIReport: CLIDetectionReport?
    @Published var debugCommandInput: String = "which codex"
    @Published var debugCommandOutput: String = ""
    @Published var isRunningDebugCommand: Bool = false
    @Published var cliPrompt: String = "Say hello"
    @Published var codexStreamOutput: String = ""
    @Published var claudeStreamOutput: String = ""
    @Published var isRunningCodexStream: Bool = false
    @Published var isRunningClaudeStream: Bool = false

    private var lastSavedGeminiModel: GeminiModel
    private var hasStartedCLICheck = false
    private let codexStreamer = StreamingCLI()
    private let claudeStreamer = StreamingCLI()

    init() {
        let preference = GeminiModelPreference.load()
        self.geminiModel = preference.primary
        self.lastSavedGeminiModel = preference.primary
    }
    
    var currentStep: SetupStep {
        guard currentStepIndex < steps.count else {
            return SetupStep(id: "fallback", title: "Setup", contentType: .information("Complete", "Setup is complete"))
        }
        return steps[currentStepIndex]
    }
    
    var canContinue: Bool {
        switch currentStep.contentType {
        case .apiKeyInput:
            return !apiKey.isEmpty && apiKey.count > 20
        case .cliDetection:
            return hasAnyCLIInstalled
        case .terminalCommand(_), .modelDownload(_), .localChoice, .localModelInstall, .information(_, _), .apiKeyInstructions:
            return true
        }
    }
    
    var isLastStep: Bool {
        return currentStepIndex == steps.count - 1
    }
    
    func configureSteps(for provider: String) {
        switch provider {
        case "ollama":
            steps = [
                SetupStep(
                    id: "intro",
                    title: "Before you begin",
                    contentType: .information(
                        "For experienced users",
                        "This path is recommended only if you're comfortable running LLMs locally and debugging technical issues. If terms like vLLM or API endpoint don't ring a bell, we recommend going back and picking 'Bring your own API keys'. It's non-technical and takes about 30 seconds.\n\nFor local mode, Dayflow recommends Qwen 2.5-VL 3B as the core vision-language model."
                    )
                ),
                SetupStep(id: "choose", title: "Choose engine", contentType: .localChoice),
                SetupStep(id: "model", title: "Install model", contentType: .localModelInstall),
                SetupStep(id: "test", title: "Test connection", contentType: .information("Test Connection", "Click the button below to verify your local server responds to a simple chat completion.")),
                SetupStep(id: "complete", title: "Complete", contentType: .information("All set!", "Local AI is configured and ready to use with Dayflow."))
            ]
        case "chatgpt_claude":
            steps = [
                SetupStep(
                    id: "intro",
                    title: "Before you begin",
                    contentType: .information(
                        "Install ChatGPT or Claude",
                        "Dayflow can drive either ChatGPT (through the Codex CLI) or Claude Code. You'll need at least one installed and signed in on this Mac. We'll check automatically in the next step."
                    )
                ),
                SetupStep(
                    id: "detect",
                    title: "Check installations",
                    contentType: .cliDetection
                ),
                SetupStep(
                    id: "complete",
                    title: "Complete",
                    contentType: .information(
                        "All set!",
                        "ChatGPT and Claude tooling is ready. You can fine-tune which assistant to use anytime from Settings → AI Provider."
                    )
                )
            ]
            codexCLIStatus = .unknown
            claudeCLIStatus = .unknown
            codexCLIReport = nil
            claudeCLIReport = nil
            isCheckingCLIStatus = false
            hasStartedCLICheck = false
            cancelCodexStream()
            cancelClaudeStream()
            codexStreamOutput = ""
            claudeStreamOutput = ""
            cliPrompt = "Say hello"
        default: // gemini
            steps = [
                SetupStep(id: "getkey", title: "Get API key",
                          contentType: .apiKeyInstructions),
                SetupStep(id: "enterkey", title: "Enter API key",
                          contentType: .apiKeyInput),
                SetupStep(id: "verify", title: "Test connection",
                          contentType: .information("Test Connection", "Click the button below to verify your API key works with Gemini")),
                SetupStep(id: "complete", title: "Complete",
                          contentType: .information("All set!", "Gemini is now configured and ready to use with Dayflow."))
            ]
        }
    }
    
    func goNext() {
        // Save API key to keychain when moving from API key input step
        if currentStep.contentType.isApiKeyInput && !apiKey.isEmpty {
            KeychainManager.shared.store(apiKey, for: "gemini")
            // Reset test state when API key changes
            hasTestedConnection = false
            testSuccessful = false
            persistGeminiModelSelection(source: "onboarding_step")
        }

        if currentStepIndex < steps.count - 1 {
            currentStepIndex += 1
        }
    }
    
    func goBack() {
        if currentStepIndex > 0 {
            currentStepIndex -= 1
        }
    }
    
    func navigateToStep(_ stepId: String) {
        if let index = steps.firstIndex(where: { $0.id == stepId }) {
            // Reset test state when navigating to test step
            if stepId == "verify" || stepId == "test" {
                hasTestedConnection = false
                testSuccessful = false
            }
            // Allow free navigation between all steps
            currentStepIndex = index
        }
    }
    
    func markCurrentStepCompleted() {
        if currentStepIndex < steps.count {
            steps[currentStepIndex].markCompleted()
        }
    }

    func persistGeminiModelSelection(source: String) {
        guard geminiModel != lastSavedGeminiModel else { return }
        lastSavedGeminiModel = geminiModel
        GeminiModelPreference(primary: geminiModel).save()

        Task { @MainActor in
            await AnalyticsService.shared.capture("gemini_model_selected", [
                "source": source,
                "model": geminiModel.rawValue
            ])
        }

        // Changing models should prompt the user to re-run the connection test
        hasTestedConnection = false
        testSuccessful = false
    }
    
    private var hasAnyCLIInstalled: Bool {
        codexCLIStatus.isInstalled || claudeCLIStatus.isInstalled
    }
    
    func ensureCLICheckStarted() {
        guard !hasStartedCLICheck else { return }
        hasStartedCLICheck = true
        refreshCLIStatuses()
    }
    
    func refreshCLIStatuses() {
        if isCheckingCLIStatus { return }
        isCheckingCLIStatus = true
        codexCLIStatus = .checking
        claudeCLIStatus = .checking
        codexCLIReport = nil
        claudeCLIReport = nil
        
        Task.detached { [weak self] in
            guard let self else { return }
            async let codex = CLIDetector.detect(tool: .codex)
            async let claude = CLIDetector.detect(tool: .claude)
            let (codexResult, claudeResult) = await (codex, claude)
            
            await MainActor.run {
                self.codexCLIReport = codexResult
                self.claudeCLIReport = claudeResult
                self.codexCLIStatus = codexResult.state
                self.claudeCLIStatus = claudeResult.state
                self.isCheckingCLIStatus = false
            }
        }
    }
    
    @MainActor
    func runDebugCommand() {
        guard !debugCommandInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            debugCommandOutput = "Enter a command to run."
            return
        }
        if isRunningDebugCommand { return }
        isRunningDebugCommand = true
        debugCommandOutput = "Running..."
        
        let command = debugCommandInput
        Task.detached { [weak self] in
            let result = CLIDetector.runDebugCommand(command)
            await MainActor.run {
                guard let self else { return }
                var output = ""
                output += "Exit code: \(result.exitCode)\n"
                if !result.stdout.isEmpty {
                    output += "\nstdout:\n\(result.stdout)"
                }
                if !result.stderr.isEmpty {
                    output += "\nstderr:\n\(result.stderr)"
                }
                if result.stdout.isEmpty && result.stderr.isEmpty {
                    output += "\n(no output)"
                }
                self.debugCommandOutput = output
                self.isRunningDebugCommand = false
            }
        }
    }
    
    private func cliEnvironment(overrides: [String: String]? = nil) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        var components = env["PATH"].map { $0.split(separator: ":").map { String($0) } } ?? []
        for raw in CLIDetector.searchPaths {
            let expanded = (raw as NSString).expandingTildeInPath
            if !components.contains(expanded) {
                components.append(expanded)
            }
        }
        env["PATH"] = components.joined(separator: ":")
        env["HOME"] = env["HOME"] ?? NSHomeDirectory()
        if let overrides = overrides {
            env.merge(overrides, uniquingKeysWith: { _, new in new })
        }
        return env
    }
    
    func runCodexStream() {
        guard !isRunningCodexStream else { return }
        guard let path = CLIDetector.resolveExecutablePath(for: .codex) else {
            codexStreamOutput = "Codex CLI not found."
            return
        }
        let prompt = cliPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Say hello" : cliPrompt
        codexStreamOutput = "Running \(path) with prompt: \(prompt)\n\n"
        isRunningCodexStream = true
        codexStreamer.run(
            command: path,
            args: ["exec", "--json", prompt],
            env: cliEnvironment(),
            onStdout: { [weak self] chunk in
                self?.codexStreamOutput.append(chunk)
            },
            onStderr: { [weak self] chunk in
                self?.codexStreamOutput.append("\n[stderr] \(chunk)")
            },
            onFinish: { [weak self] code in
                guard let self else { return }
                self.codexStreamOutput.append("\n\nExited \(code)\n")
                self.isRunningCodexStream = false
            }
        )
    }
    
    func cancelCodexStream() {
        codexStreamer.cancel()
        if isRunningCodexStream {
            codexStreamOutput.append("\n\nCancelled.\n")
        }
        isRunningCodexStream = false
    }
    
    func runClaudeStream() {
        guard !isRunningClaudeStream else { return }
        guard let path = CLIDetector.resolveExecutablePath(for: .claude) else {
            claudeStreamOutput = "Claude CLI not found."
            return
        }
        let prompt = cliPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Say hello" : cliPrompt
        claudeStreamOutput = "Running \(path) with prompt: \(prompt)\n\n"
        isRunningClaudeStream = true
        claudeStreamer.run(
            command: path,
            args: ["--print", "--output-format", "json", prompt],
            env: cliEnvironment(),
            onStdout: { [weak self] chunk in
                self?.claudeStreamOutput.append(chunk)
            },
            onStderr: { [weak self] chunk in
                self?.claudeStreamOutput.append("\n[stderr] \(chunk)")
            },
            onFinish: { [weak self] code in
                guard let self else { return }
                self.claudeStreamOutput.append("\n\nExited \(code)\n")
                self.isRunningClaudeStream = false
            }
        )
    }
    
    func cancelClaudeStream() {
        claudeStreamer.cancel()
        if isRunningClaudeStream {
            claudeStreamOutput.append("\n\nCancelled.\n")
        }
        isRunningClaudeStream = false
    }
}

struct SetupStep: Identifiable {
    let id: String
    let title: String
    let contentType: StepContentType
    private(set) var isCompleted: Bool = false
    
    mutating func markCompleted() {
        isCompleted = true
    }
}

enum StepContentType {
    case terminalCommand(String)
    case apiKeyInput
    case apiKeyInstructions
    case modelDownload(String)
    case information(String, String)
    case localChoice
    case localModelInstall
    case cliDetection
    
    var isApiKeyInput: Bool {
        if case .apiKeyInput = self {
            return true
        }
        return false
    }
    
    var informationTitle: String? {
        if case .information(let title, _) = self {
            return title
        }
        return nil
    }
}


enum LocalEngine: String {
    case ollama
    case lmstudio
    case custom
}

extension ProviderSetupState {
    @MainActor func selectEngine(_ engine: LocalEngine) {
        localEngine = engine
        switch engine {
        case .ollama:
            localBaseURL = "http://localhost:11434"
            localModelId = "qwen2.5vl:3b"
        case .lmstudio:
            localBaseURL = "http://localhost:1234"
            localModelId = "qwen2.5-vl-3b-instruct"
        case .custom:
            break
        }

        // Track local engine selection for analytics
        AnalyticsService.shared.capture("local_engine_selected", [
            "engine": engine.rawValue,
            "base_url": localBaseURL,
            "default_model": localModelId
        ])
    }
    
    var localCurlCommand: String {
        let payload = "{\"model\":\"\(localModelId)\",\"messages\":[{\"role\":\"user\",\"content\":\"Say 'hello' and your model name.\"}],\"max_tokens\":50}"
        let authHeader = localEngine == .lmstudio ? " -H \"Authorization: Bearer lm-studio\"" : ""
        return "curl -s \(localBaseURL)/v1/chat/completions -H \"Content-Type: application/json\"\(authHeader) -d '\(payload)'"
    }
}

struct LocalLLMTestView: View {
    @Binding var baseURL: String
    @Binding var modelId: String
    let engine: LocalEngine
    var showInputs: Bool = true
    let onTestComplete: (Bool) -> Void

    private let accentColor = Color(red: 0.25, green: 0.17, blue: 0)
    private let successAccentColor = Color(red: 0.34, green: 1, blue: 0.45)

    @State private var isTesting = false
    @State private var resultMessage: String?
    @State private var success: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showInputs {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Base URL")
                        .font(.custom("Nunito", size: 13))
                        .foregroundColor(.black.opacity(0.6))
                    TextField(engine == .lmstudio ? "http://localhost:1234" : "http://localhost:11434", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Model ID")
                        .font(.custom("Nunito", size: 13))
                        .foregroundColor(.black.opacity(0.6))
                    TextField(engine == .lmstudio ? "qwen2.5-vl-3b-instruct" : "qwen2.5vl:3b", text: $modelId)
                        .textFieldStyle(.roundedBorder)
                }
            }
            
            DayflowSurfaceButton(
                action: runTest,
                content: {
                    HStack(spacing: 8) {
                        if isTesting {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: success ? "checkmark.circle.fill" : "bolt.fill").font(.system(size: 14))
                        }
                        Text(isTesting ? "Testing..." : (success ? "Test Successful!" : "Test Local API")).font(.custom("Nunito", size: 14)).fontWeight(.semibold)
                    }
                },
                background: success ? successAccentColor.opacity(0.2) : accentColor,
                foreground: success ? .black : .white,
                borderColor: success ? successAccentColor.opacity(0.3) : .clear,
                cornerRadius: 8,
                horizontalPadding: 24,
                verticalPadding: 12,
                showOverlayStroke: !success
            )
            .disabled(isTesting)
            
            if let msg = resultMessage {
                Text(msg)
                    .font(.custom("Nunito", size: 13))
                    .foregroundColor(success ? .black.opacity(0.7) : Color(hex: "E91515"))
                    .padding(.vertical, 6)
                if !success {
                    Text("If you get stuck here, you can go back and choose the ‘Bring your own key’ option — it only takes a minute to set up.")
                        .font(.custom("Nunito", size: 12))
                        .foregroundColor(.black.opacity(0.55))
                        .padding(.top, 2)
                }
            }
        }
    }
    private func runTest() {
        guard !isTesting else { return }
        isTesting = true
        success = false
        resultMessage = nil
        
        guard let url = URL(string: "\(baseURL)/v1/chat/completions") else {
            resultMessage = "Invalid base URL"
            isTesting = false
            onTestComplete(false)
            return
        }
        
        struct Req: Codable { let model: String; let messages: [Msg]; let max_tokens: Int }
        struct Msg: Codable { let role: String; let content: String }
        let req = Req(model: modelId, messages: [Msg(role: "user", content: "Say 'hello' and your model name.")], max_tokens: 50)
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if engine == .lmstudio { request.setValue("Bearer lm-studio", forHTTPHeaderField: "Authorization") }
        request.httpBody = try? JSONEncoder().encode(req)
        request.timeoutInterval = 15
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    self.resultMessage = error.localizedDescription
                    self.isTesting = false
                    self.onTestComplete(false)
                    return
                }
                guard let http = response as? HTTPURLResponse, let data = data else {
                    self.resultMessage = "No response"; self.isTesting = false; self.onTestComplete(false); return
                }
                if http.statusCode == 200 {
                    // Success: don't print raw response body; keep UI clean
                    self.resultMessage = nil
                    self.success = true
                    self.isTesting = false
                    self.onTestComplete(true)
                } else {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    self.resultMessage = "HTTP \(http.statusCode): \(body)"
                    self.isTesting = false
                    self.onTestComplete(false)
                }
            }
        }.resume()
    }
}

enum CLITool: String, CaseIterable {
    case codex
    case claude
    
    var displayName: String {
        switch self {
        case .codex: return "ChatGPT (Codex CLI)"
        case .claude: return "Claude Code"
        }
    }
    
    var shortName: String {
        switch self {
        case .codex: return "ChatGPT"
        case .claude: return "Claude"
        }
    }
    
    var subtitle: String {
        switch self {
        case .codex:
            return "OpenAI's ChatGPT desktop tooling with codex CLI"
        case .claude:
            return "Anthropic's Claude Code command-line helper"
        }
    }
    
    var executableName: String {
        switch self {
        case .codex: return "codex"
        case .claude: return "claude"
        }
    }
    
    var versionCommand: String {
        "\(executableName) --version"
    }
    
    var installURL: URL? {
        switch self {
        case .codex:
            return URL(string: "https://github.com/a16z-infra/codex#installation")
        case .claude:
            return URL(string: "https://docs.anthropic.com/en/docs/claude-code/setup")
        }
    }
    
    var iconName: String {
        switch self {
        case .codex: return "terminal"
        case .claude: return "bolt.horizontal.circle"
        }
    }
}

enum CLIDetectionState: Equatable {
    case unknown
    case checking
    case installed(version: String)
    case notFound
    case failed(message: String)
    
    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }
    
    var statusLabel: String {
        switch self {
        case .unknown:
            return "Not checked"
        case .checking:
            return "Checking…"
        case .installed:
            return "Installed"
        case .notFound:
            return "Not installed"
        case .failed:
            return "Error"
        }
    }
    
    var detailMessage: String? {
        switch self {
        case .installed(let version):
            return version.trimmingCharacters(in: .whitespacesAndNewlines)
        case .failed(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        default:
            return nil
        }
    }
}

struct CLIDetectionReport {
    let state: CLIDetectionState
    let resolvedPath: String?
    let stdout: String?
    let stderr: String?
}

struct CLIDetector {
    static var searchPaths: [String] { cliSearchPaths }
    
    static func detect(tool: CLITool) async -> CLIDetectionReport {
        guard let executablePath = resolveExecutablePath(for: tool) else {
            return CLIDetectionReport(state: .notFound, resolvedPath: nil, stdout: nil, stderr: nil)
        }
        do {
            let result = try runCLI(executablePath, args: ["--version"])
            if result.exitCode == 0 {
                let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
                let summary = firstLine.isEmpty ? "\(tool.shortName) detected" : firstLine
                return CLIDetectionReport(state: .installed(version: summary), resolvedPath: executablePath, stdout: result.stdout, stderr: result.stderr)
            }
            if result.exitCode == 127 || result.stderr.contains("not found") {
                return CLIDetectionReport(state: .notFound, resolvedPath: executablePath, stdout: result.stdout, stderr: result.stderr)
            }
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.isEmpty {
                return CLIDetectionReport(state: .failed(message: "Exit code \(result.exitCode)"), resolvedPath: executablePath, stdout: result.stdout, stderr: result.stderr)
            }
            return CLIDetectionReport(state: .failed(message: message), resolvedPath: executablePath, stdout: result.stdout, stderr: result.stderr)
        } catch {
            return CLIDetectionReport(state: .failed(message: error.localizedDescription), resolvedPath: executablePath, stdout: nil, stderr: nil)
        }
    }
    
    static func resolveExecutablePath(for tool: CLITool) -> String? {
        resolveExecutablePath(named: tool.executableName)
    }
    
    private static func resolveExecutablePath(named name: String) -> String? {
        let fileManager = FileManager.default
        var searchDirectories: [String] = []
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            searchDirectories.append(contentsOf: envPath.split(separator: ":").map { String($0) })
        }
        searchDirectories.append(contentsOf: cliSearchPaths)
        var seen = Set<String>()
        for directory in searchDirectories {
            let expanded = (directory as NSString).expandingTildeInPath
            if !seen.insert(expanded).inserted {
                continue
            }
            let candidate = (expanded as NSString).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
    
    static func runDebugCommand(_ command: String) -> CLIResult {
        do {
            return try runCLI("bash", args: ["-lc", command])
        } catch {
            return CLIResult(stdout: "", stderr: error.localizedDescription, exitCode: -1)
        }
    }
}

struct ChatCLIDetectionStepView<NextButton: View>: View {
    let codexStatus: CLIDetectionState
    let codexReport: CLIDetectionReport?
    let claudeStatus: CLIDetectionState
    let claudeReport: CLIDetectionReport?
    let isChecking: Bool
    let onRetry: () -> Void
    let onInstall: (CLITool) -> Void
    @Binding var debugCommand: String
    let debugOutput: String
    let isRunningDebug: Bool
    let onRunDebug: () -> Void
    @Binding var cliPrompt: String
    let codexOutput: String
    let claudeOutput: String
    let isRunningCodex: Bool
    let isRunningClaude: Bool
    let onRunCodex: () -> Void
    let onCancelCodex: () -> Void
    let onRunClaude: () -> Void
    let onCancelClaude: () -> Void
    @ViewBuilder let nextButton: () -> NextButton
    
    @State private var showCodexDebug = false
    @State private var showClaudeDebug = false
    
    private let accentColor = Color(red: 0.25, green: 0.17, blue: 0)
    
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Check ChatGPT or Claude")
                    .font(.custom("Nunito", size: 24))
                    .fontWeight(.semibold)
                    .foregroundColor(.black.opacity(0.9))
                Text("Dayflow can talk to ChatGPT (via the Codex CLI) or Claude Code. You only need one installed and signed in on this Mac.")
                    .font(.custom("Nunito", size: 14))
                    .foregroundColor(.black.opacity(0.6))
            }
            
            VStack(alignment: .leading, spacing: 14) {
                ChatCLIToolStatusRow(
                    tool: .codex,
                    status: codexStatus,
                    report: codexReport,
                    showDebug: $showCodexDebug,
                    onInstall: { onInstall(.codex) }
                )
                ChatCLIToolStatusRow(
                    tool: .claude,
                    status: claudeStatus,
                    report: claudeReport,
                    showDebug: $showClaudeDebug,
                    onInstall: { onInstall(.claude) }
                )
            }
            
            Text("Tip: Once both are installed, you can choose which assistant Dayflow uses from Settings → AI Provider.")
                .font(.custom("Nunito", size: 12))
                .foregroundColor(.black.opacity(0.5))
            
            DebugCommandConsole(
                command: $debugCommand,
                output: debugOutput,
                isRunning: isRunningDebug,
                runAction: {
                    onRunDebug()
                }
            )
            
            VStack(alignment: .leading, spacing: 12) {
                Text("Try a sample prompt")
                    .font(.custom("Nunito", size: 13))
                    .fontWeight(.semibold)
                    .foregroundColor(.black.opacity(0.7))
                TextField("Ask ChatGPT or Claude…", text: $cliPrompt)
                    .textFieldStyle(.roundedBorder)
                    .font(.custom("Nunito", size: 13))
                HStack(spacing: 12) {
                    DayflowSurfaceButton(
                        action: {
                            if isRunningCodex {
                                onCancelCodex()
                            } else if codexStatus.isInstalled || codexReport?.resolvedPath != nil {
                                onRunCodex()
                            }
                        },
                        content: {
                            HStack(spacing: 6) {
                                Image(systemName: isRunningCodex ? "stop.fill" : "play.fill").font(.system(size: 12, weight: .semibold))
                                Text(isRunningCodex ? "Stop Codex" : "Run Codex")
                                    .font(.custom("Nunito", size: 13))
                                    .fontWeight(.semibold)
                            }
                        },
                        background: Color(red: 0.25, green: 0.17, blue: 0),
                        foreground: .white,
                        borderColor: .clear,
                        cornerRadius: 8,
                        horizontalPadding: 16,
                        verticalPadding: 10,
                        showOverlayStroke: true
                    )
                    .disabled(!(codexStatus.isInstalled || codexReport?.resolvedPath != nil) && !isRunningCodex)
                    
                    DayflowSurfaceButton(
                        action: {
                            if isRunningClaude {
                                onCancelClaude()
                            } else if claudeStatus.isInstalled || claudeReport?.resolvedPath != nil {
                                onRunClaude()
                            }
                        },
                        content: {
                            HStack(spacing: 6) {
                                Image(systemName: isRunningClaude ? "stop.fill" : "play.fill").font(.system(size: 12, weight: .semibold))
                                Text(isRunningClaude ? "Stop Claude" : "Run Claude")
                                    .font(.custom("Nunito", size: 13))
                                    .fontWeight(.semibold)
                            }
                        },
                        background: Color(red: 0.25, green: 0.17, blue: 0),
                        foreground: .white,
                        borderColor: .clear,
                        cornerRadius: 8,
                        horizontalPadding: 16,
                        verticalPadding: 10,
                        showOverlayStroke: true
                    )
                    .disabled(!(claudeStatus.isInstalled || claudeReport?.resolvedPath != nil) && !isRunningClaude)
                }
                if !codexOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    DebugField(label: "Codex output", value: codexOutput)
                }
                if !claudeOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    DebugField(label: "Claude output", value: claudeOutput)
                }
            }
            .padding(16)
            .background(Color.white.opacity(0.55))
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.black.opacity(0.05), lineWidth: 1)
            )
            
            HStack {
                DayflowSurfaceButton(
                    action: {
                        if !isChecking {
                            onRetry()
                        }
                    },
                    content: {
                        HStack(spacing: 8) {
                            if isChecking {
                                ProgressView().scaleEffect(0.7)
                            } else {
                                Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
                            }
                            Text(isChecking ? "Checking…" : "Re-check")
                                .font(.custom("Nunito", size: 14))
                                .fontWeight(.semibold)
                        }
                    },
                    background: accentColor,
                    foreground: .white,
                    borderColor: .clear,
                    cornerRadius: 8,
                    horizontalPadding: 20,
                    verticalPadding: 10,
                    showOverlayStroke: true
                )
                .disabled(isChecking)
                
                Spacer()
                
                nextButton()
                    .opacity(canContinue ? 1.0 : 0.5)
                    .allowsHitTesting(canContinue)
            }
        }
    }
    
    private var canContinue: Bool {
        codexStatus.isInstalled || claudeStatus.isInstalled
    }
}

struct ChatCLIToolStatusRow: View {
    let tool: CLITool
    let status: CLIDetectionState
    let report: CLIDetectionReport?
    @Binding var showDebug: Bool
    let onInstall: () -> Void
    
    private let accentColor = Color(red: 0.25, green: 0.17, blue: 0)
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: tool.iconName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.black.opacity(0.75))
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.7))
                    .cornerRadius(8)
                    .shadow(color: Color.black.opacity(0.08), radius: 4, x: 0, y: 2)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(tool.displayName)
                        .font(.custom("Nunito", size: 16))
                        .fontWeight(.semibold)
                        .foregroundColor(.black.opacity(0.9))
                    Text(tool.subtitle)
                        .font(.custom("Nunito", size: 12))
                        .foregroundColor(.black.opacity(0.55))
                }
                
                Spacer()
                
                statusView
            }
            
            if let detail = status.detailMessage, !detail.isEmpty {
                Text(detail)
                    .font(.custom("Nunito", size: 12))
                    .foregroundColor(.black.opacity(0.6))
                    .padding(.leading, 48)
            }
            
            if let report {
                Button(action: { withAnimation { showDebug.toggle() } }) {
                    HStack(spacing: 6) {
                        Image(systemName: showDebug ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                        Text(showDebug ? "Hide debug info" : "Show debug info")
                            .font(.custom("Nunito", size: 12))
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.plain)
                .padding(.leading, 48)
                .pointingHandCursor()
                
                if showDebug {
                    VStack(alignment: .leading, spacing: 6) {
                        if let path = report.resolvedPath {
                            DebugField(label: "Resolved path", value: path)
                        }
                        if let stdout = report.stdout, !stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            DebugField(label: "stdout", value: stdout)
                        }
                        if let stderr = report.stderr, !stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            DebugField(label: "stderr", value: stderr)
                        }
                        if (report.stdout?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) && (report.stderr?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                            DebugField(label: "Note", value: "No output captured from --version")
                        }
                    }
                    .padding(.leading, 48)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            
            if shouldShowInstallButton {
                DayflowSurfaceButton(
                    action: onInstall,
                    content: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down.circle.fill").font(.system(size: 13, weight: .semibold))
                            Text(installLabel)
                                .font(.custom("Nunito", size: 13))
                                .fontWeight(.semibold)
                        }
                    },
                    background: .white.opacity(0.85),
                    foreground: accentColor,
                    borderColor: accentColor.opacity(0.35),
                    cornerRadius: 8,
                    horizontalPadding: 16,
                    verticalPadding: 8,
                    showOverlayStroke: true
                )
                .padding(.leading, 48)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.6))
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
    }
    
    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .checking, .unknown:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.55)
                Text(status.statusLabel)
                    .font(.custom("Nunito", size: 12))
                    .foregroundColor(accentColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(accentColor.opacity(0.12))
            .cornerRadius(999)
        case .installed:
            Text(status.statusLabel)
                .font(.custom("Nunito", size: 12))
                .fontWeight(.semibold)
                .foregroundColor(Color(red: 0.13, green: 0.7, blue: 0.23))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(red: 0.13, green: 0.7, blue: 0.23).opacity(0.17))
                .cornerRadius(999)
        case .notFound:
            Text(status.statusLabel)
                .font(.custom("Nunito", size: 12))
                .fontWeight(.semibold)
                .foregroundColor(Color(hex: "E91515"))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(hex: "FFD1D1"))
                .cornerRadius(999)
        case .failed:
            Text(status.statusLabel)
                .font(.custom("Nunito", size: 12))
                .fontWeight(.semibold)
                .foregroundColor(Color(red: 0.91, green: 0.34, blue: 0.16))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(red: 0.91, green: 0.34, blue: 0.16).opacity(0.18))
                .cornerRadius(999)
        }
    }
    
    private var shouldShowInstallButton: Bool {
        switch status {
        case .notFound, .failed:
            return tool.installURL != nil
        default:
            return false
        }
    }
    
    private var installLabel: String {
        switch status {
        case .failed:
            return "Open setup guide"
        default:
            return "Install \(tool.shortName)"
        }
    }
}

struct DebugField: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.custom("Nunito", size: 11))
                .fontWeight(.semibold)
                .foregroundColor(.black.opacity(0.55))
            ScrollView(.vertical, showsIndicators: true) {
                Text(value)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.black.opacity(0.75))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.white.opacity(0.85))
                    .cornerRadius(6)
            }
            .frame(maxHeight: 100)
        }
    }
}

struct DebugCommandConsole: View {
    @Binding var command: String
    let output: String
    let isRunning: Bool
    let runAction: () -> Void
    
    private let accentColor = Color(red: 0.25, green: 0.17, blue: 0)
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Run a command as Dayflow")
                .font(.custom("Nunito", size: 13))
                .fontWeight(.semibold)
                .foregroundColor(.black.opacity(0.7))
            Text("Helpful for checking PATH differences. We run using the same environment as the detection step.")
                .font(.custom("Nunito", size: 12))
                .foregroundColor(.black.opacity(0.55))
            HStack(spacing: 10) {
                TextField("Command", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                DayflowSurfaceButton(
                    action: runAction,
                    content: {
                        HStack(spacing: 6) {
                            if isRunning {
                                ProgressView().scaleEffect(0.7)
                            } else {
                                Image(systemName: "play.fill").font(.system(size: 12, weight: .semibold))
                            }
                            Text(isRunning ? "Running..." : "Run")
                                .font(.custom("Nunito", size: 13))
                                .fontWeight(.semibold)
                        }
                    },
                    background: accentColor,
                    foreground: .white,
                    borderColor: .clear,
                    cornerRadius: 8,
                    horizontalPadding: 14,
                    verticalPadding: 10,
                    showOverlayStroke: true
                )
                .disabled(isRunning)
            }
            ScrollView {
                Text(output.isEmpty ? "Output will appear here" : output)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.black.opacity(output.isEmpty ? 0.4 : 0.75))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.white.opacity(0.85))
                    .cornerRadius(8)
            }
            .frame(maxHeight: 160)
        }
        .padding(16)
        .background(Color.white.opacity(0.55))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
    }
}
