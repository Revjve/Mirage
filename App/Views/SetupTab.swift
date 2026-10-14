// One-time setup: a pairing file for the phone, and Apple's developer disk image.
// Both land in Application Support; the DDI download is ~20 MB and only happens once
// per iOS major version (the cryptex/personalized split changes at 26.4).

import SwiftUI

struct SetupTab: View {
    @EnvironmentObject private var controller: SpoofController
    @EnvironmentObject private var pairingHost: PairingHost
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

                    switch pairingHost.state {
                    case .waiting(let service, let port):
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Waiting for this iPhone to connect…").font(.subheadline)
                            }
                            Text("\(service) · port \(String(port))")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Button(role: .destructive) { pairingHost.stop() } label: {
                            Label("Cancel", systemImage: "xmark")
                        }

                    case .pin(let pin):
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Enter this code if asked").font(.caption).foregroundStyle(.secondary)
                            Text(pin)
                                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                                .numeric()
                        }

                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)

                    case .paired:
                        Label("Pairing file created", systemImage: "checkmark.circle.fill")
                            .font(.subheadline).foregroundStyle(.green)

                    case .idle:
                        EmptyView()
                    }

                    if !pairingHost.isRunning {
                        Button {
                            Haptic.tap()
                            pairingHost.start()
                        } label: {
                            Label(pairingReady ? "Create a new pairing file" : "Create pairing file",
                                  systemImage: "wave.3.right.circle")
                        }
                    }

                    Button {
                        importingPairing = true
                    } label: {
                        Label("Import a file instead…", systemImage: "doc.badge.plus")
                    }
                } header: {
                    Text("Step 1 — Pair")
                } footer: {
                    Text("Mirage can act as its own pairing host: it advertises over Bonjour and this iPhone pairs with it, so StikPair and a computer are both unnecessary. Failing that, drop \(PairingStore.fileName) into On My iPhone → Mirage in the Files app.")
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
                    Toggle(isOn: $controller.snapToRoads) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Follow roads")
                            Text("Routes use MapKit driving directions. Off means a straight line.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Driving")
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
            .onChange(of: pairingHost.state) { _, _ in refresh() }
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
