#if os(iOS)
import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers
import StrandDesign
import StrandGlucose

struct GlucoseSettingsView: View {
    @ObservedObject private var hub = GlucoseHub.shared
    @AppStorage(GlucosePrefs.bleEnabled) private var bleEnabled = true
    @AppStorage(GlucosePrefs.shareEnabled) private var shareEnabled = false
    @AppStorage(GlucosePrefs.healthKitEnabled) private var healthKitEnabled = true
    @AppStorage(GlucosePrefs.unit) private var unitRaw = GlucoseUnit.mmol.rawValue
    @AppStorage(GlucosePrefs.profile) private var profileRaw = GlucoseProfile.generalHealth.rawValue

    @State private var username = ""
    @State private var password = ""
    @State private var region: DexcomShareRegion = .outsideUS
    @State private var shareResult = ""
    @State private var testing = false
    @State private var manualValue = ""
    @State private var manualDate = Date()
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section {
                Picker("Units", selection: $unitRaw) {
                    ForEach(GlucoseUnit.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Target range", selection: $profileRaw) {
                    ForEach(GlucoseProfile.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                }
            } header: { Text("Display") } footer: {
                Text("General health scores against the tight range people without diabetes spend most of the day in. Both ranges are always calculated.")
            }

            Section {
                Toggle("Read the G7 directly", isOn: $bleEnabled)
                LabeledContent("Status", value: hub.bleState.label)
            } header: { Text("Bluetooth (real time)") } footer: {
                Text("Listens to your G7 alongside the Dexcom app on this iPhone — every 5 minutes, no internet needed. The Dexcom app must stay installed and signed in; NOOP Pro never sends anything to the sensor.")
            }

            Section {
                Toggle("Use Dexcom Share as backup", isOn: $shareEnabled)
                if shareEnabled {
                    TextField("Dexcom username / email", text: $username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password)
                    Picker("Region", selection: $region) {
                        ForEach(DexcomShareRegion.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Button(testing ? "Checking…" : "Save & test") {
                        Task {
                            testing = true
                            let c = DexcomShareCredentials(username: username.trimmingCharacters(in: .whitespaces),
                                                           password: password, region: region)
                            shareResult = await hub.testShare(c)
                            if shareResult.hasPrefix("Connected") { DexcomShareKeychain.save(c); hub.applySettings() }
                            testing = false
                        }
                    }
                    .disabled(testing || username.isEmpty || password.isEmpty)
                    if !shareResult.isEmpty { Text(shareResult).font(.footnote) }
                    LabeledContent("Status", value: hub.shareStatus)
                    if DexcomShareKeychain.load() != nil {
                        Button("Remove saved login", role: .destructive) {
                            DexcomShareKeychain.clear()
                            Task { await hub.resetShareSession() }
                            hub.applySettings()
                        }
                    }
                }
            } header: { Text("Dexcom Share (internet)") } footer: {
                Text("Turn on Share in the Dexcom app first. Used when this phone isn't in range of the sensor. Your login stays in this iPhone's Keychain and only ever goes to Dexcom.")
            }

            Section {
                Toggle("Import from Apple Health", isOn: $healthKitEnabled)
                Button("Import last 90 days now") { Task { await hub.importHealthKit(days: 90) } }
                if !hub.healthStatus.isEmpty { Text(hub.healthStatus).font(.footnote) }
            } header: { Text("History") } footer: {
                Text("Dexcom writes to Apple Health three hours late, so it fills history and gaps rather than live values.")
            }

            Section("Finger-prick") {
                TextField(unitRaw == GlucoseUnit.mmol.rawValue ? "Value (mmol/L)" : "Value (mg/dL)", text: $manualValue)
                    .keyboardType(.decimalPad)
                DatePicker("Taken", selection: $manualDate)
                Button("Add reading") {
                    let raw = Double(manualValue.replacingOccurrences(of: ",", with: ".")) ?? 0
                    let mgdl = unitRaw == GlucoseUnit.mmol.rawValue ? raw * mgdlPerMmol : raw
                    guard mgdl >= 20, mgdl <= 600 else { return }
                    hub.addManual(mgdl: mgdl, at: manualDate)
                    manualValue = ""
                }
            }

            Section {
                LabeledContent("Stored readings", value: "\(hub.storedCount)")
                ShareLink(item: GlucoseCSV(), preview: SharePreview("glucose.csv")) { Label("Export CSV", systemImage: "square.and.arrow.up") }
                Button("Delete all glucose data", role: .destructive) { confirmDelete = true }
            } header: { Text("Your data") }
        }
        .navigationTitle("Glucose settings")
        .onChange(of: bleEnabled) { _, _ in hub.applySettings() }
        .onChange(of: shareEnabled) { _, _ in hub.applySettings() }
        .onAppear {
            if let c = DexcomShareKeychain.load() { username = c.username; password = c.password; region = c.region }
        }
        .confirmationDialog("Delete every stored glucose reading?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { hub.store.deleteAll(); hub.reload() }
        }
    }
}

/// Lazily-built CSV for ShareLink.
struct GlucoseCSV: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { _ in
            Data(GlucoseStore.shared.csv().utf8)
        }
        .suggestedFileName("nooppro-glucose.csv")
    }
}
#endif
