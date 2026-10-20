import SwiftUI

struct WalkthroughView: View {
    @EnvironmentObject private var store: ProgressStore
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0
    @State private var connectingKind: PrinterKind?
    var onFinish: () -> Void = {}

    private var pageCount: Int {
        #if os(macOS)
        4
        #else
        3
        #endif
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch page {
                    case 0: welcome
                    case 1: connections
                    case 2: widgets
                    default:
                        #if os(macOS)
                        menuBar
                        #else
                        widgets
                        #endif
                    }
                }
                .padding(28).frame(maxWidth: 540).frame(maxWidth: .infinity, alignment: .center)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 16) {
                    HStack(spacing: 7) {
                        ForEach(0..<pageCount, id: \.self) { index in
                            Capsule().fill(index == page ? ProgressStyle.green : Color.secondary.opacity(0.2))
                                .frame(width: index == page ? 20 : 6, height: 6)
                        }
                    }
                    .accessibilityLabel("Step \(page + 1) of \(pageCount)")
                    HStack {
                        Button("Back") { page -= 1 }.disabled(page == 0)
                        Spacer()
                        Button(page == pageCount - 1 ? "Get started" : "Continue") {
                            if page == pageCount - 1 { finish() } else { page += 1 }
                        }
                        .buttonStyle(.borderedProminent).tint(ProgressStyle.green)
                    }
                }
                .padding(.horizontal, 28).padding(.vertical, 20).background(.regularMaterial)
            }
            .navigationTitle("Welcome to Print Progress")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Skip") { finish() } } }
        }
        .sheet(item: $connectingKind) { kind in AddPrinterView(initialKind: kind).environmentObject(store) }
        #if os(macOS)
        .frame(width: 530, height: 610)
        #endif
    }
    private func finish() { onFinish(); dismiss() }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image("BrandMark").resizable().scaledToFit().frame(width: 116, height: 116)
                .clipShape(RoundedRectangle(cornerRadius: 26))
            Text("Your next print,\nat a glance.").font(.largeTitle.bold())
            Text("Keep an eye on progress, time remaining, and chamber temperature without opening your slicer.")
                .font(.title3).foregroundStyle(.secondary)
            Label("Bambu, Klipper, OctoPrint, Prusa and more", systemImage: "printer")
            Label("Connects directly over your network", systemImage: "wifi")
            Label("No account or subscription", systemImage: "person.crop.circle.badge.checkmark")
        }
    }
    private var connections: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connect a printer").font(.title.bold())
            Text("Keep your device and printer on the same network. Choose the type below to check the connection.")
                .foregroundStyle(.secondary)
            ForEach(PrinterKind.allCases) { kind in
                Button { connectingKind = kind } label: {
                    connectionOption(kind.title, detail: kind.connectionHelp, symbol: kind.connectionSymbol)
                }
                .buttonStyle(.plain)
            }
            if !store.profiles.isEmpty {
                Label("\(store.profiles.count) printer\(store.profiles.count == 1 ? "" : "s") added", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(ProgressStyle.green).font(.callout)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Allow Local Network access").font(.subheadline.bold())
                #if os(macOS)
                Text("If the connection is blocked, open System Settings → Privacy & Security → Local Network and enable Print Progress.")
                #else
                Text("Tap Allow when asked for Local Network access. You can also enable it in Settings → Privacy & Security → Local Network → Print Progress.")
                #endif
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func connectionOption(_ title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 15) {
            Image(systemName: symbol).font(.title2).foregroundStyle(ProgressStyle.green).frame(width: 28)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
    }
    private var widgets: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "square.grid.2x2.fill").font(.system(size: 40)).foregroundStyle(ProgressStyle.green)
            Text("Put progress where you’ll see it").font(.title.bold())
            #if os(macOS)
            step("1", title: "Open the widget gallery", detail: "Control-click an empty part of your desktop and choose Edit Widgets.")
            step("2", title: "Find Print Progress", detail: "Choose a small widget for one printer, or a wider widget for multiple printers.")
            step("3", title: "Choose a printer", detail: "Control-click your widget to edit it. Leave the printer on automatic to show active jobs first.")
            #else
            step("1", title: "Add a Home Screen widget", detail: "Touch and hold your Home Screen, then choose Edit → Add Widget and search for Print Progress.")
            step("2", title: "Choose your printer", detail: "Touch and hold a widget and choose Edit Widget. Leave it automatic to prioritize active jobs.")
            step("3", title: "Try the Lock Screen too", detail: "Touch and hold your Lock Screen, choose Customize, and add a Print Progress widget.")
            #endif
            Text("Widgets refresh periodically and show the time of the last reading. Use the refresh arrow to open the app and get a current reading.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func step(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Text(number).font(.subheadline.bold()).foregroundStyle(ProgressStyle.green)
                .frame(width: 28, height: 28).background(ProgressStyle.green.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
    #if os(macOS)
    private var menuBar: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "menubar.rectangle").font(.system(size: 40)).foregroundStyle(ProgressStyle.green)
            Text("A quiet spot in your menu bar").font(.title.bold())
            Text("Keep a progress circle, percentage, or remaining time beside your other menu bar items. Click it for full printer details.")
                .foregroundStyle(.secondary)
            Form { MenuBarOptionsView().environmentObject(store) }.formStyle(.grouped).frame(height: 240)
            Text("You can change this anytime from Preferences.").font(.caption).foregroundStyle(.secondary)
        }
    }
    #endif
}
