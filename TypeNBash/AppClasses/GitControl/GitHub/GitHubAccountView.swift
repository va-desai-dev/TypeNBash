import SwiftUI

struct GitHubAccountView: View {
    @Bindable var model: GitHubAccountModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let code = model.userCode {
                HStack {
                    Text(code).font(.title2.monospaced()).textSelection(.enabled)
                    Button("Copy Code", action: model.copyCode)
                    Button("Open GitHub", action: model.openBrowser)
                    Spacer()
                    ProgressView().controlSize(.small)
                    Button("Cancel", action: model.cancel)
                }
                Text("Enter this code in your browser and approve access. Waiting for GitHub…")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let login = model.login, GitHubSignInStatus.shared.needsSignIn {
                // A refused login is always "sign in again" — never a reason to
                // touch the repository.
                HStack {
                    Label("GitHub · \(login) · sign-in expired", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Sign in again", action: model.connect).disabled(model.isBusy)
                    if model.isBusy {
                        ProgressView().controlSize(.small)
                        Button("Cancel", action: model.cancel)
                    }
                }
                Text("GitHub no longer accepts this sign-in. Approve access in your browser to reconnect; your code and history are unaffected.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let login = model.login {
                HStack {
                    Label("GitHub · \(login)", systemImage: "person.crop.circle.badge.checkmark")
                    Spacer()
                    Button("Disconnect") { Task { await model.disconnect() } }
                        .disabled(model.isBusy)
                        .help("Remove authorization from this Mac. Revoke app access on GitHub to invalidate it.")
                }
            } else {
                HStack {
                    Button("Sign in with GitHub", action: model.connect).disabled(model.isBusy)
                    if model.isBusy {
                        ProgressView().controlSize(.small)
                        Button("Cancel", action: model.cancel)
                    }
                }
                Text("Authorize repository and profile access in your browser. Credentials stay in Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .task { await model.load() }
        .onDisappear { model.cancel() }
    }
}
