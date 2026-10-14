// One-time setup: a pairing file for the phone, and Apple's developer disk image.
// Both land in Application Support; the DDI download is ~20 MB and only happens once
// per iOS major version (the cryptex/personalized split changes at 26.4).

import SwiftUI

struct SetupTab: View {
    @EnvironmentObject private var controller: SpoofController
    @State private var importingPairing = false
    @State private var pairingReady = false
    @State private var ddiReady = false
    @State private var downloading = false
    @State private var downloadNote = ""
    @State private var setupError = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    row("Pairing file", ok: pairingReady)
                    Button {
                        importingPairing = true
                    } label: {
                        Label(pairingReady ? "Replace pairing file…" : "Import pairing file…",
                              systemImage: "doc.badge.plus")
                    }
                } header: {
                    Text("Step 1 — Pair")
                } footer: {
                    Text("Generate one on-device with StikPair, or drop \(PairingStore.fileName) into On My iPhone → Mirage in the Files app and Mirage will pick it up.")
                }

                Section {
                    row("Developer disk image", ok: ddiReady)
                    if downloading {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(downloadNote).font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Button {
                            download()
                        } label: {
                            Label(ddiReady ? "Re-download image" : "Download image",
                                  systemImage: "arrow.down.circle")
                        }
                    }
                } header: {
                    Text("Step 2 — Disk image")
                } footer: {
                    Text("This device needs the \(DDIStore.useCryptex ? "cryptex" : "personalized") variant. It stays mounted until the phone reboots.")
                }

                Section {
                    LabeledContent("Tunnel") {
                        TextField("10.7.0.1", text: $controller.targetAddress)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled()
                    }
                    VStack(alignment: .leading) {
                        LabeledContent("Jitter", value: String(format: "±%.0f%%", controller.jitter * 100))
                        Slider(value: $controller.jitter, in: 0...0.5, step: 0.05)
                    }
                } header: {
                    Text("Engine")
                } footer: {
                    Text("The loopback address the RemotePairing tunnel listens on. Leave it at 10.7.0.1 unless your tunnel provider uses something else.")
                }

                Section {
                    LabeledContent("Link", value: controller.connected ? "Up" : "Down")
                    Button(role: .destructive) {
                        Task { await controller.disconnect() }
                    } label: {
                        Label("Disconnect", systemImage: "bolt.horizontal.circle")
                    }
                    .disabled(!controller.connected)
                }

                if !setupError.isEmpty {
                    Section { Text(setupError).font(.caption).foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Setup")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { StatusPill() } }
            .onAppear(perform: refresh)
            .fileImporter(isPresented: $importingPairing,
                          allowedContentTypes: PairingStore.contentTypes) { result in
                setupError = ""
                do {
                    try PairingStore.importFile(from: try result.get())
                } catch {
                    setupError = error.localizedDescription
                }
                refresh()
            }
        }
    }

    private func row(_ title: String, ok: Bool) -> some View {
        LabeledContent(title) {
            Label(ok ? "Ready" : "Missing", systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(ok ? .green : .secondary)
                .font(.subheadline)
        }
    }

    private func refresh() {
        pairingReady = PairingStore.exists
        ddiReady = DDIStore.isReady
    }

    private func download() {
        downloading = true
        setupError = ""
        Task {
            do {
                try await DDIStore.download { note in
                    Task { @MainActor in downloadNote = note }
                }
            } catch {
                setupError = error.localizedDescription
            }
            downloading = false
            downloadNote = ""
            refresh()
        }
    }
}
