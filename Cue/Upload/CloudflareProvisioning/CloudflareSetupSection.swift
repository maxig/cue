import SwiftUI

/// The Cloudflare setup card. Its model lives on AppState because the
/// popover (and every view in it) is torn down the moment setup opens the
/// browser; the in-flight flow state has to outlive that.
struct CloudflareSetupSection: View {
    @ObservedObject var provisioner: CloudflareProvisioner
    let settings: UploadSettings
    @State private var token = ""
    @State private var selectedZoneID = ""
    @State private var subdomainLabel = "cue"

    var body: some View {
        Card("Cloudflare — automatic setup") {
            content
        }
        .onAppear { provisioner.bootstrap(settings: settings) }
    }

    @ViewBuilder
    private var content: some View {
        switch provisioner.phase {
        case .idle:
            Caption("Cue can set up free Cloudflare sharing for you: storage, database, and your own share server — no manual configuration.")
            emailField
            RowButton("Set up automatically…", system: "wand.and.stars") {
                NSWorkspace.shared.open(CloudflareProvisioner.tokenCreationURL)
                provisioner.beginTokenEntry()
            }
            Divider().opacity(0.5)
            RowButton("Create a free Cloudflare account…", system: "person.badge.plus") {
                NSWorkspace.shared.open(CloudflareProvisioner.signupURL)
            }
            Caption("No account yet? Create one first, then come back and choose “Set up automatically”.")

        case .enteringToken:
            Caption("Your browser opened a Cloudflare page with a ready-made token. Click “Continue to summary”, then “Create Token”, copy the token, and paste it here.")
            SecureField("", text: $token, prompt: Text("Paste the token"))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .padding(.vertical, 4)
            HStack(spacing: 10) {
                Button("Connect") { provisioner.connect(token: token) }
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
                Button("Cancel") {
                    token = ""
                    provisioner.cancel()
                }
            }
            .controlSize(.small)
            .padding(.vertical, 9)
            Divider().opacity(0.5)
            RowButton("Open the token page again", system: "arrow.up.forward.app") {
                NSWorkspace.shared.open(CloudflareProvisioner.tokenCreationURL)
            }

        case .selectingAccount(let accounts):
            Caption("The token can reach more than one Cloudflare account. Pick where Cue should set up sharing.")
            ForEach(accounts) { account in
                RowButton(account.name, system: "building.2") {
                    provisioner.continueWith(account: account)
                }
            }
            Divider().opacity(0.5)
            HStack {
                Spacer()
                Button("Cancel") { provisioner.cancel() }.controlSize(.small)
            }
            .padding(.vertical, 9)

        case .running(let current):
            ForEach(CloudflareProvisioner.Step.allCases, id: \.rawValue) { step in
                HStack(spacing: 9) {
                    if step < current {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.accent)
                    } else if step == current {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "circle")
                            .foregroundStyle(Theme.tertiaryText)
                    }
                    Text(step.title)
                        .font(.cueRowTitle)
                        .foregroundStyle(step <= current ? Theme.primaryText : Theme.tertiaryText)
                    Spacer()
                }
                .frame(minHeight: 26)
            }
            Caption("Setting things up on your Cloudflare account. This usually takes under a minute.")

        case .failed(let step, let message, let help):
            HStack(spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(step.title).font(.cueRowTitle).foregroundStyle(Theme.primaryText)
                Spacer()
            }
            .padding(.vertical, 8)
            Caption(message)
            if case .enableR2(let accountId) = help {
                RowButton("Enable R2 storage in Cloudflare…", system: "arrow.up.forward.app") {
                    NSWorkspace.shared.open(CloudflareProvisioner.r2PlanURL(accountId: accountId))
                }
            }
            HStack(spacing: 10) {
                Button("Try Again") { provisioner.retry() }
                Spacer()
                Button("Cancel") { provisioner.cancel() }
            }
            .controlSize(.small)
            .padding(.vertical, 9)

        case .connected(let workerURL):
            HStack(spacing: 9) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.accent)
                Text("Connected").font(.cueRowTitle).foregroundStyle(Theme.primaryText)
                Spacer()
            }
            .padding(.vertical, 8)
            Caption("Your recordings share at \(workerURL). The fields below were filled in automatically — you normally don't need to touch them.")
            if settings.accessConfigured {
                Caption("Web library: \(workerURL)/app — sign in with a one-time code sent to your email.")
            } else if let notice = provisioner.dashboardNotice {
                Caption(notice)
            } else if settings.ownerEmail.trimmingCharacters(in: .whitespaces).isEmpty {
                emailField
                Caption("Add your email and choose “Run setup again” to unlock your online library at /app with an emailed sign-in code.")
            }
            Divider().opacity(0.5)
            domainSection
            Divider().opacity(0.5)
            RowButton("Run setup again…", system: "arrow.clockwise") {
                provisioner.reprovision()
            }
            Caption("Re-checks everything and publishes this app version's share server — useful after an update.")
            Divider().opacity(0.5)
            RowButton("Forget Cloudflare token", system: "xmark.circle") {
                token = ""
                provisioner.forgetToken()
            }
            Caption("Forgetting the token only stops automatic setup — sharing keeps working with the settings below.")
        }
    }

    /// Optional email that unlocks the online library: setup locks /app behind
    /// a one-time code sent to this address.
    private var emailField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sign-in email for the web library (optional)")
                .font(.cueCaption).foregroundStyle(Theme.secondaryText)
            TextField("", text: Binding(get: { settings.ownerEmail },
                                        set: { settings.ownerEmail = $0 }),
                      prompt: Text("you@example.com"))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
        }
        .padding(.vertical, 6)
    }

    /// Inside the connected card: move the share link onto one of the
    /// account's own domains, entirely from within Settings.
    @ViewBuilder
    private var domainSection: some View {
        switch provisioner.domainPhase {
        case .idle:
            RowButton("Use your own domain…", system: "globe") {
                provisioner.beginDomainSelection()
            }

        case .loadingZones:
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text("Looking up your domains…").font(.cueRowTitle).foregroundStyle(Theme.secondaryText)
                Spacer()
            }
            .padding(.vertical, 10)

        case .choosing(let zones):
            Caption("Pick a domain and a subdomain for your share links. Cloudflare creates the address and certificate automatically.")
            Picker("", selection: $selectedZoneID) {
                ForEach(zones) { zone in Text(zone.name).tag(zone.id) }
            }
            .labelsHidden()
            .onAppear { if selectedZoneID.isEmpty { selectedZoneID = zones.first?.id ?? "" } }
            HStack(spacing: 6) {
                TextField("", text: $subdomainLabel, prompt: Text("cue"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(width: 90)
                Text("." + (zones.first(where: { $0.id == selectedZoneID })?.name ?? ""))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.vertical, 4)
            HStack(spacing: 10) {
                Button("Connect domain") {
                    if let zone = zones.first(where: { $0.id == selectedZoneID }) {
                        provisioner.attachDomain(zone: zone, subdomain: subdomainLabel)
                    }
                }
                .disabled(selectedZoneID.isEmpty || subdomainLabel.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Button("Cancel") { provisioner.cancelDomainSelection() }
            }
            .controlSize(.small)
            .padding(.vertical, 9)

        case .attaching(let hostname):
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text("Setting up \(hostname)…").font(.cueRowTitle).foregroundStyle(Theme.primaryText)
                Spacer()
            }
            .padding(.vertical, 10)
            Caption("Creating the address and its certificate. This can take a few minutes on a brand-new subdomain.")

        case .failed(let message):
            Caption(message)
            HStack(spacing: 10) {
                Button("Try Again") { provisioner.beginDomainSelection() }
                Spacer()
                Button("Cancel") { provisioner.cancelDomainSelection() }
            }
            .controlSize(.small)
            .padding(.vertical, 9)
        }
    }
}
