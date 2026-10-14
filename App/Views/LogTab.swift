// The tunnel fails in a dozen boring ways (stale pairing file, unmounted image,
// provider not running). This is where you find out which one.

import SwiftUI
import UIKit // UIPasteboard isn't re-exported by SwiftUI

struct LogTab: View {
    @EnvironmentObject private var controller: SpoofController

    var body: some View {
        NavigationStack {
            Group {
                if controller.log.isEmpty {
                    ContentUnavailableView("No activity yet",
                                           systemImage: "list.bullet.rectangle",
                                           description: Text("Connect or set a location and the steps show up here."))
                } else {
                    ScrollViewReader { proxy in
                        List {
                            ForEach(Array(controller.log.enumerated()), id: \.offset) { entry in
                                Text(entry.element)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(entry.element.contains("⚠︎") ? .orange : .primary)
                                    .textSelection(.enabled)
                                    .id(entry.offset)
                            }
                        }
                        .listStyle(.plain)
                        .onChange(of: controller.log.count) { _, count in
                            withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) }
                        }
                    }
                }
            }
            .navigationTitle("Log")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            UIPasteboard.general.string = controller.log.joined(separator: "\n")
                        } label: {
                            Label("Copy all", systemImage: "doc.on.doc")
                        }
                        Button(role: .destructive, action: controller.clearLog) {
                            Label("Clear", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(controller.log.isEmpty)
                }
            }
        }
    }
}
