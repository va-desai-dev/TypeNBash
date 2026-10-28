import SwiftUI

struct AgentSettingsPane: View {
    @Bindable private var settings = AgentSettings.shared
    var body: some View {
        Form {
            Section("Connection") {
                Picker("Server", selection: $settings.preset) {
                    ForEach(AgentConnectionPreset.allCases) { Text($0.title).tag($0) }
                }
                TextField("Base URL", text: $settings.connection.baseURL)
                    .autocorrectionDisabled()
                Picker("API format", selection: $settings.connection.kind) {
                    ForEach(AgentProviderKind.allCases) { Text($0.title).tag($0) }
                }
                Text(settings.endpointDescription).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                TextField("Model ID", text: $settings.connection.model).autocorrectionDisabled()
                Text("Use a model that supports tools. An origin URL uses /v1; an API base path such as /v1 is preserved. Changes apply to new conversations.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Authentication") {
                Picker("Method", selection: $settings.connection.authentication) {
                    ForEach(AgentAuthentication.allCases) { Text($0.title).tag($0) }
                }
                if settings.connection.authentication == .chatGPT {
                    HStack {
                        if settings.isSigningIn {
                            ProgressView().controlSize(.small)
                            Button("Cancel Sign-In", action: settings.cancelChatGPTSignIn)
                        } else {
                            Button(settings.hasKey ? "Sign In Again" : "Continue with ChatGPT", action: settings.signInWithChatGPT)
                            if settings.hasKey { Button("Sign Out", role: .destructive, action: settings.forgetKey) }
                        }
                    }
                } else if settings.connection.authentication != .none {
                    SecureField(settings.hasKey ? "Replace saved credential" : "Credential", text: $settings.apiKey)
                    HStack {
                        Button("Save Credential", action: settings.saveKey).disabled(settings.apiKey.isEmpty)
                        if settings.hasKey { Button("Forget Credential", role: .destructive, action: settings.forgetKey) }
                    }
                }
                if !settings.status.isEmpty { Text(settings.status).font(.caption).textSelection(.enabled) }
            }
            Section {
                Text("Prompts and files read by the agent go to the selected server. Local models need no paid API account. Credentials stay in Keychain and are scoped to the endpoint.")
                if settings.preset == .ollama {
                    Text("Local Ollama needs no credential. A signed-in Ollama server can also run cloud models using your Ollama account; use the model ID exposed by that server.")
                } else if settings.preset == .ollamaCloud {
                    Text("Direct Ollama Cloud access uses an Ollama API key and your Ollama account limits. You can also select Ollama to connect through your signed-in local server.")
                }
                Text("Local commands are available only in the DMG edition and require approval. They run with the app’s operating-system privileges; the working directory does not confine them.")
            }.font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .task { settings.refresh() }
        .onDisappear { settings.apiKey = "" }
        .scrollContentBackground(.hidden)
    }
}
