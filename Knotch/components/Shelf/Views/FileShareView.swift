//
//  FileShareView.swift
//  Knotch
//
//  Created by Alexander on 2025-09-24.
//

import AppKit
import Defaults
import SwiftUI
import UniformTypeIdentifiers
import os

private let dragDiagnosticsLogger = Logger(subsystem: "seshyweshyy.Knotch", category: "DragDropDiagnostics")

struct FileShareView: View {
    @EnvironmentObject private var vm: KnotchViewModel
    @StateObject private var quickShare = QuickShareService.shared
    @StateObject private var localSend = LocalSendService.shared
    @Default(.quickShareProvider) var quickShareProvider: String

    @State private var hostView: NSView?
    @State private var interactionNonce: UUID = .init()
    @State private var isProcessing = false
    @State private var pendingDropProviders: [NSItemProvider]?
    @State private var showLocalSendDevicePicker = false
    @State private var showQuickSharePopover = false
    @State private var isSwitchHover = false
    
    private var selectedProvider: QuickShareProvider {
        quickShare.availableProviders.first(where: { $0.id == quickShareProvider }) ?? QuickShareProvider(id: "Share Menu", imageData: nil, supportsRawText: true)
    }

    var body: some View {
        dropArea
            .background(NSViewHost(view: $hostView))
            .onAppear { localSend.startDiscovery() }
            .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data, .image], isTargeted: $vm.dropZoneTargeting) { providers in
                interactionNonce = .init()
                vm.dropEvent = true
                if selectedProvider.id == "LocalSend" {
                    pendingDropProviders = providers
                    showLocalSendDevicePicker = true
                } else {
                    Task { await handleDrop(providers) }
                }
                return true
            }
            .onTapGesture {
                if selectedProvider.id == "LocalSend" {
                    showLocalSendDevicePicker = true
                } else {
                    Task { await handleClick() }
                }
            }
            // TEMP DIAGNOSTIC — remove once the drop-zone highlight bug is root-caused.
            .onChange(of: vm.dropZoneTargeting) { old, new in
                dragDiagnosticsLogger.debug("[ShareZone] dropZoneTargeting \(old) -> \(new)")
            }
            .onChange(of: showLocalSendDevicePicker) { _, show in
                if show {
                    LocalSendDevicePickerWindowManager.shared.show(
                        onDeviceSelected: { device in
                            localSend.selectedDeviceID = device.id
                            showLocalSendDevicePicker = false
                            if let providers = pendingDropProviders {
                                Task {
                                    await handleDrop(providers)
                                    pendingDropProviders = nil
                                }
                            }
                        },
                        onDismiss: {
                            showLocalSendDevicePicker = false
                            pendingDropProviders = nil
                        }
                    )
                } else {
                    LocalSendDevicePickerWindowManager.shared.hide()
                }
            }
    }

    private var dropArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 32)
                .fill(Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 32)
                        .stroke(
                            vm.dropZoneTargeting
                                ? Color.accentColor.opacity(0.9)
                                : Color.white.opacity(0.1),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [10])
                        )
                )

            // Content
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(
                            vm.dropZoneTargeting ? 0.11 : 0.09
                        ))
                        .frame(width: 55, height: 55)
                    Image(systemName: "square.and.arrow.up")
                    Group {
                        if let imgData = selectedProvider.imageData, let nsImg = NSImage(data: imgData) {
                            Image(nsImage: nsImg)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        } else {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    .frame(width: 34, height: 34)
                        .foregroundStyle(
                            vm.dropZoneTargeting ? Color.accentColor : Color.gray
                        )
                        .scaleEffect(
                            vm.dropZoneTargeting ? 1.06 : 1.0
                        )
                        .animation(.spring(response: 0.36, dampingFraction: 0.7), value: vm.dropZoneTargeting)

                    // Loading overlay — sits inside the circle ZStack so it's centred on it
                    if isProcessing || quickShare.isPickerOpen {
                        Circle()
                            .fill(.black.opacity(0.4))
                            .frame(width: 55, height: 55)
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.8)
                    }
                }

                Text(selectedProvider.id)
                    .font(.system(.headline, design: .rounded))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)

            }
            .padding(18)

            // Switch button pinned to top-right corner
            VStack {
                HStack {
                    Spacer()
                    Button {
                        SharingStateManager.shared.beginInteraction()
                        showQuickSharePopover.toggle()
                    } label: {
                        Image(systemName: "switch.2")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 12, height: 12)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 7).fill(isSwitchHover ? Color.white.opacity(0.12) : Color.clear))
                            .foregroundColor(isSwitchHover ? .accentColor : .gray)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .onHover { hovering in isSwitchHover = hovering }
                    .popover(isPresented: $showQuickSharePopover, arrowEdge: .bottom) {
                        quickSharePopoverContent
                    }
                    .padding(.trailing, 6)
                    .padding(.top, 6)
                }
                Spacer()
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onChange(of: showQuickSharePopover) { _, isOpen in
            if !isOpen { SharingStateManager.shared.endInteraction() }
        }
    }

    private var quickSharePopoverContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick Share")
                .font(.headline)

            Picker("Quick Share Service", selection: $quickShareProvider) {
                ForEach(quickShare.availableProviders, id: \.id) { provider in
                    QuickShareProviderRow(provider: provider, iconSize: 25)
                        .tag(provider.id)
                }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 260)

            if let selected = quickShare.availableProviders.first(where: { $0.id == quickShareProvider }) {
                HStack(alignment: .top, spacing: 8) {
                    if let imgData = selected.imageData, let nsImg = NSImage(data: imgData) {
                        Image(nsImage: nsImg)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 20, height: 20)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .frame(width: 20, height: 20)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Currently: \(selected.id)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Files shared from the shelf will use this service")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
    }

    // MARK: - Actions

    private func handleDrop(_ providers: [NSItemProvider]) async {
        isProcessing = true
        defer { isProcessing = false }
        await quickShare.shareDroppedFiles(providers, using: selectedProvider, from: hostView)
    }
    
    private func handleClick() async {
        await quickShare.showFilePicker(for: selectedProvider, from: hostView)
    }
}

// MARK: - Host NSView extractor for anchoring share sheet

private struct NSViewHost: NSViewRepresentable {
    @Binding var view: NSView?
    
    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async { self.view = v }
        return v
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { self.view = nsView }
    }
}
