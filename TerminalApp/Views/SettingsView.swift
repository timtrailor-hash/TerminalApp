import SwiftUI
import TimSharedKit

struct SettingsView: View {
    @EnvironmentObject var server: ServerConnection
    @AppStorage("sshUsername") private var sshUsername = "timtrailor"
    @AppStorage("sshPassword") private var sshPassword = ""

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

            Section("About") {
                HStack {
                    Text("Version")
                        .foregroundColor(AppTheme.labelText)
                    Spacer()
                    Text("1.0")
                        .foregroundColor(AppTheme.dimText)
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
    }
}
