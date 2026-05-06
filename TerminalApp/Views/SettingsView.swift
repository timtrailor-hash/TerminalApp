import SwiftUI
import TimSharedKit

struct SettingsView: View {
    @EnvironmentObject var server: ServerConnection
    @AppStorage("sshUsername") private var sshUsername = "timtrailor"
    @State private var sshPassword = CredentialStore.loadPassword()
    @AppStorage("useSplitView") private var useSplitView = true
    @State private var hostKeysCleared = false
    @State private var showClearConfirmation = false

    var body: some View {
        Form {
            Section("Server") {
                HStack {
                    Text("Host")
                        .foregroundColor(AppTheme.labelText)
                    TextField("host:port", text: $server.serverHost)
                        .multilineTextAlignment(.trailing)
                        .font(.system(.body, design: .monospaced))
                }

                HStack {
                    Text("Token")
                        .foregroundColor(AppTheme.labelText)
                    SecureField("auth token", text: $server.authToken)
                        .multilineTextAlignment(.trailing)
                        .font(.system(.body, design: .monospaced))
                }
            }

            Section("SSH") {
                HStack {
                    Text("Username")
                        .foregroundColor(AppTheme.labelText)
                    TextField("username", text: $sshUsername)
                        .multilineTextAlignment(.trailing)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                HStack {
                    Text("Password")
                        .foregroundColor(AppTheme.labelText)
                    SecureField("SSH password", text: $sshPassword)
                        .multilineTextAlignment(.trailing)
                        .font(.system(.body, design: .monospaced))
                }
            }

            Section("Security") {
                Button(role: .destructive) {
                    showClearConfirmation = true
                } label: {
                    HStack {
                        Text("Clear Pinned SSH Host Keys")
                        Spacer()
                        if hostKeysCleared {
                            Image(systemName: "checkmark")
                                .foregroundColor(.green)
                        }
                    }
                }
            }

            Section("Display") {
                Toggle("Split View", isOn: $useSplitView)
                    .tint(AppTheme.accent)
                Text("Scrollable output + input box. Disable for classic terminal.")
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.fadedText)
            }

            Section("About") {
                HStack {
                    Text("Version")
                        .foregroundColor(AppTheme.labelText)
                    Spacer()
                    Text("1.1")
                        .foregroundColor(AppTheme.dimText)
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .onAppear { hostKeysCleared = false }
        .onChange(of: sshPassword) { _, newValue in
            CredentialStore.savePassword(newValue)
        }
        .confirmationDialog(
            "Clear all pinned SSH host keys?",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All Keys", role: .destructive) {
                hostKeysCleared = HostKeyStore.clearAll()
            }
        } message: {
            Text("You will be prompted to trust each host again on next connection.")
        }
    }
}
