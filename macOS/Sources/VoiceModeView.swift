import SwiftUI

struct VoiceModeView: View {
    @ObservedObject var agent: AgentState
    @ObservedObject var voice = VoiceManager.shared
    let onClose: () -> Void

    @State private var permissionAsked = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button {
                        onClose()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                                .font(.system(size: 12))
                            Text("Mostrar el chat")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .chipBackground(Theme.elevated, radius: 14)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)

                Spacer()

                OrbStage(voice: voice, size: 300)

                Spacer()

                if voice.permissionDenied {
                    VStack(spacing: 8) {
                        Text("Candy necesita acceso al micrófono y al reconocimiento de voz.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.red)
                            .multilineTextAlignment(.center)
                        Button("Volver a pedir permiso") {
                            voice.permissionDenied = false
                            requestAndStart()
                        }
                        .controlSize(.small)
                    }
                    .padding(.bottom, 14)
                } else if !voice.transcript.isEmpty && voice.phase == .listening {
                    Text(voice.transcript)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Theme.textPrimary.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        .padding(.bottom, 14)
                }

                Text("Esc interrumpe; pulsa otra vez para terminar")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .chipBackground(Color(hex: 0x26262E), radius: 8)

                Text("Habla cuando quieras")
                    .font(.system(size: 17))
                    .italic()
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 10)
                    .padding(.bottom, 26)

                HStack(spacing: 22) {
                    Button {
                        if voice.phase == .listening {
                            voice.finishManual()
                        } else {
                            requestAndStart()
                        }
                    } label: {
                        Image(systemName: voice.phase == .listening ? "mic.fill" : "mic")
                            .font(.system(size: 22))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 64, height: 64)
                            .background(Color(hex: 0x2C2C34), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(voice.permissionDenied)

                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 64, height: 64)
                            .background(Theme.red, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 34)
            }
        }
        .onAppear {
            agent.showVoice = true
            voice.onFinal = { text in
                agent.voiceSubmit(text)
            }
            voice.onSpeakingEnd = {
                voice.startListening()
            }
            if !permissionAsked {
                permissionAsked = true
                requestAndStart()
            }
            advance()
        }
        .onDisappear {
            agent.showVoice = false
            voice.stopSpeaking()
            voice.stopListening(silently: true)
            voice.onFinal = nil
            voice.onSpeakingEnd = nil
            voice.transcript = ""
            voice.phase = .idle
        }
        .onChange(of: agent.busy) { _, _ in
            advance()
        }
        .onChange(of: agent.confirmation?.id) { _, _ in
            advance()
        }
        .overlay {
            if let request = agent.confirmation {
                ConfirmOverlay(
                    request: request,
                    allowAll: $agent.allowAll,
                    onAnswer: { agent.answerConfirm($0) }
                )
            }
        }
        .overlay {
            if let prompt = agent.modelPrompt {
                VStack(spacing: 10) {
                    Text("Descargar modelo")
                        .font(.headline)
                    Text("¿Usar '\(prompt.model)'? Si no está en tu Mac se descargará ahora.")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                    HStack {
                        Button("Cancelar") { agent.cancelModelChange() }
                        Button("Descargar y usar") { agent.confirmModelChange() }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)
                    }
                }
                .padding(22)
                .frame(width: 420)
                .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 16))
                .shadow(radius: 24, y: 8)
            }
        }
        .onKeyPress(.escape) {
            if voice.phase == .speaking {
                voice.interrupt()
                return .handled
            }
            if agent.busy {
                agent.stop()
                return .handled
            }
            if voice.phase == .listening {
                voice.finishManual()
                onClose()
                return .handled
            }
            onClose()
            return .handled
        }
    }

    private func requestAndStart() {
        voice.requestPermissions { granted in
            if granted {
                voice.startListening()
            }
        }
    }

    private func advance() {
        if agent.confirmation != nil {
            voice.stopSpeaking()
            voice.stopListening(silently: true)
            voice.phase = .idle
            return
        }
        if agent.busy {
            voice.stopSpeaking()
            voice.stopListening(silently: true)
            voice.phase = .thinking
            return
        }
        if voice.phase == .thinking {
            voice.startListening()
        }
    }
}
