import SwiftUI

struct ContentView: View {
    @ObservedObject var agent: AgentState
    @State private var selectedModel = AgentState.defaultModel
    @State private var newChatHover = false

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                sidebar
                VStack(spacing: 0) {
                    header
                    if agent.screen == .chat {
                        chatArea
                        inputBar
                    } else {
                        DashboardView(agent: agent)
                    }
                }
            }
            .background(Theme.bg)

            if agent.showVoice {
                VoiceModeView(agent: agent) {
                    agent.showVoice = false
                }
                .transition(.opacity)
            }
        }
        .frame(minWidth: 880, minHeight: 600)
        .preferredColorScheme(.dark)
        .onAppear {
            selectedModel = agent.model
            agent.boot()
        }
        .onChange(of: agent.model) { _, newValue in
            selectedModel = newValue
        }
        .overlay {
            if !agent.showVoice, let request = agent.confirmation {
                ConfirmOverlay(
                    request: request,
                    allowAll: $agent.allowAll,
                    onAnswer: { agent.answerConfirm($0) }
                )
            }
        }
        .alert("Descargar modelo", isPresented: Binding(
            get: { agent.modelPrompt != nil && !agent.showVoice },
            set: { if !$0 { agent.cancelModelChange() } }
        )) {
            Button("Cancelar", role: .cancel) {
                selectedModel = agent.model
                agent.cancelModelChange()
            }
            Button("Descargar y usar") {
                agent.confirmModelChange()
            }
        } message: {
            Text("¿Usar '\(agent.modelPrompt?.model ?? "")'? Si aún no está en tu Mac (~1-2 GB), se descargará ahora.")
        }
    }

    // ------------------------------------------------------------- sidebar

    private var sidebar: some View {
        VStack(spacing: 10) {
            Circle()
                .fill(Theme.candyGradient)
                .frame(width: 30, height: 30)
                .overlay(
                    Circle().stroke(Color.white.opacity(0.25), lineWidth: 1)
                )
                .padding(.top, 14)
                .shadow(color: Theme.accent.opacity(0.5), radius: 10)

            Spacer()

            sidebarButton(icon: "bubble.left.and.bubble.right.fill",
                          active: agent.screen == .chat) {
                agent.screen = .chat
            }

            sidebarButton(icon: "speedometer",
                          active: agent.screen == .dashboard) {
                agent.screen = .dashboard
            }

            Button {
                agent.newChat()
                agent.screen = .chat
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 38, height: 38)
                    .background(
                        Circle().fill(newChatHover ? Theme.elevated : Color.clear)
                    )
                    .onHover { newChatHover = $0 }
            }
            .buttonStyle(.plain)
            .help("Nueva conversación")

            Spacer()

            Circle()
                .fill(agent.ready ? Theme.green : Theme.amber)
                .frame(width: 8, height: 8)
                .padding(.bottom, 16)
        }
        .frame(width: 60)
        .background(Color(hex: 0x0E0E12))
    }

    private func sidebarButton(icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(active ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 38, height: 38)
                .background(
                    Circle().fill(active ? Theme.elevated : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    // ------------------------------------------------------------- header

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Circle()
                    .fill(agent.statusError ? Theme.red : (agent.statusOK ? Theme.green : Theme.amber))
                    .frame(width: 8, height: 8)
                Text(agent.statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: 240)

            Spacer()

            HStack(spacing: 6) {
                Text("🏠")
                    .font(.system(size: 14))
                Text("Personal")
                    .font(.system(size: 15, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 9))

            Spacer()

            HStack(spacing: 8) {
                Image(systemName: "cpu")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.violet)
                Picker("", selection: $selectedModel) {
                    ForEach(agent.modelChoices, id: \.self) { name in
                        HStack(spacing: 5) {
                            if agent.isInstalled(name) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.green)
                            } else {
                                Image(systemName: "arrow.down.circle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.amber)
                            }
                            Text(name)
                        }
                        .tag(name)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
                .onChange(of: selectedModel) { _, newValue in
                    agent.requestModelChange(newValue)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 9))

            if agent.busy {
                Button {
                    agent.stop()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.red)
                }
                .buttonStyle(.plain)
                .help("Detener")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Theme.surface)
    }

    // ------------------------------------------------------------- chat

    private var chatArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if agent.display.isEmpty {
                        VStack(spacing: 8) {
                            Text("CANDY IA")
                                .font(.system(size: 30, weight: .bold))
                                .foregroundStyle(Theme.candyGradient)
                            Text("Pídele que abra apps, ejecute comandos, vigile tus servicios o te ayude con tareas.\nLas acciones sensibles piden tu confirmación.")
                                .font(.callout)
                                .foregroundStyle(Theme.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 90)
                    }
                    ForEach(agent.display) { msg in
                        row(for: msg)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(20)
            }
            .onChange(of: agent.revision) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
        .background(Theme.bg)
    }

    @ViewBuilder
    private func row(for msg: DisplayMsg) -> some View {
        switch msg.kind {
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(msg.text)
                    .font(.system(size: 14.5))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 10)
                    .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: 560, alignment: .trailing)
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                Text(msg.text)
                    .font(.system(size: 14.5))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !agent.busy, isLastAssistant(msg) {
                    HStack(spacing: 16) {
                        Button("Copiar") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(msg.text, forType: .string)
                        }
                        Button("Releer") {
                            agent.readAloud()
                        }
                        Button("Regenerar") {
                            agent.regenerate()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 90)
        case .tool:
            toolChip(msg)
        case .system:
            Text(msg.text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .italic()
                .frame(maxWidth: .infinity)
        case .error:
            Text(msg.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func isLastAssistant(_ msg: DisplayMsg) -> Bool {
        guard let idx = agent.display.lastIndex(where: { $0.kind == .assistant }) else { return false }
        return agent.display[idx].id == msg.id
    }

    private func toolChip(_ msg: DisplayMsg) -> some View {
        let statusColor: Color = {
            switch msg.toolStatus {
            case "Done": return Theme.green
            case "Failed", "Cancelled": return Theme.red
            default: return Theme.amber
            }
        }()

        return VStack(alignment: .leading, spacing: 6) {
            Button {
                if let idx = agent.display.firstIndex(where: { $0.id == msg.id }) {
                    agent.display[idx].expanded.toggle()
                    agent.revision += 1
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "wrench.adjustable")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Text(msg.toolName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text("·")
                        .foregroundStyle(Theme.textSecondary)
                    Text(msg.toolStatus)
                        .font(.system(size: 13))
                        .foregroundStyle(statusColor)
                    Image(systemName: msg.expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            if msg.expanded, !msg.toolDetail.isEmpty {
                ScrollView {
                    Text(msg.toolDetail)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
                .padding(10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                .padding(.leading, 18)
            }
        }
    }

    // ------------------------------------------------------------- input

    private var inputBar: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    agent.newChat()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Nueva conversación")

                TextField("Escribe algo…", text: $agent.draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14.5))
                    .foregroundStyle(Theme.textPrimary)
                    .onKeyPress(.return) {
                        agent.send()
                        return .handled
                    }

                if agent.busy {
                    Button {
                        agent.stop()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Theme.red)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        agent.send()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(
                                agent.ready && !agent.draft.trimmingCharacters(
                                    in: .whitespacesAndNewlines).isEmpty
                                ? Theme.accent : Theme.textSecondary.opacity(0.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!agent.ready || agent.draft.trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.input, in: RoundedRectangle(cornerRadius: 22))
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .stroke(Theme.stroke, lineWidth: 1)
            )

            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    agent.showVoice = true
                }
            } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 42, height: 42)
                    .background(Theme.elevated, in: Circle())
                    .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Hablar con Candy (modo voz)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.surface)
    }
}

// ------------------------------------------------------------- confirmación

struct ConfirmOverlay: View {
    let request: ConfirmationRequest
    @Binding var allowAll: Bool
    let onAnswer: (Bool) -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { onAnswer(false) }

            VStack(alignment: .leading, spacing: 12) {
                Text("Confirmar acción")
                    .font(.headline)

                Text(request.name)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.red)

                Text("Candy quiere ejecutar esto:")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)

                ScrollView {
                    Text(request.argsJSON)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .padding(8)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))

                Toggle("Permitir todas las acciones de esta sesión", isOn: $allowAll)
                    .toggleStyle(.switch)

                HStack {
                    Spacer()
                    Button("Cancelar") {
                        onAnswer(false)
                    }
                    .keyboardShortcut(.cancelAction)

                    Button("Ejecutar") {
                        onAnswer(true)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                }
            }
            .padding(20)
            .frame(width: 540)
            .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 20, y: 8)
        }
    }
}
