//
//  CompactFileConverterView.swift
//  Knotch
//
//  Converter page for Compact mode: a tappable file tile (re-choosing the
//  source file), a status icon, a format Menu, and a clear/convert-or-
//  show-in-finder button row, scaled down to Compact mode's fixed
//  compactContentHeight. No settings-gear button, since Knotch has no
//  file-converter settings page to open.
//

import SwiftUI

struct CompactFileConverterView: View {
    @EnvironmentObject var vm: KnotchViewModel
    @ObservedObject var converter = FileConverterViewModel.shared

    var body: some View {
        Group {
            if let item = converter.item {
                VStack(spacing: 8) {
                    selectedFileRow(for: item)
                    buttonActionRow
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .frame(height: compactContentHeight, alignment: .top)
        .frame(maxWidth: .infinity)
    }

    private func selectedFileRow(for item: FileConverterItem) -> some View {
        HStack(spacing: 6) {
            chooseFileRow(for: item)
            statusIcon
            menuFormatRow
        }
    }

    private func chooseFileRow(for item: FileConverterItem) -> some View {
        Button {
            converter.chooseFileFromFinder()
        } label: {
            VStack(spacing: 3) {
                Image(nsImage: item.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 26, height: 26)

                Text(item.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 60)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.1)))
        }
        .disabled(converter.isConverting)
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch converter.status {
        case .idle:
            Image(systemName: "arrow.right")
                .foregroundStyle(.white.opacity(0.6))
                .font(.system(size: 14, weight: .semibold))
        case .converting:
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(0.6)
                .frame(width: 16, height: 16)
        case .converted:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 16, weight: .semibold))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.system(size: 16, weight: .semibold))
        }
    }

    private var menuFormatRow: some View {
        Menu {
            ForEach(converter.availableFormats) { format in
                Button(format.title) {
                    converter.selectedFormat = format
                }
            }
        } label: {
            HStack(spacing: 5) {
                VStack(spacing: 2) {
                    Text(converter.selectedFormat.title)
                        .lineLimit(1)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Format")
                        .lineLimit(1)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 60)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.1)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .disabled(converter.isConverting)
    }

    private var buttonActionRow: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.smooth(duration: 0.35)) {
                    vm.dismissCompactConverterPage()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 32, height: 28)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .disabled(converter.isConverting)

            Spacer()

            if case .converted = converter.status {
                Button {
                    converter.revealConvertedFile()
                } label: {
                    Text("Show in Finder")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.blue)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.blue.opacity(0.2)))
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    converter.convert()
                } label: {
                    Text(
                        converter.isConverting
                            ? "Converting file to \(converter.selectedFormat.title)…"
                            : "Convert file to \(converter.selectedFormat.title)"
                    )
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.blue)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.blue.opacity(0.2)))
                }
                .buttonStyle(.plain)
                .disabled(converter.isConverting)
            }
        }
    }
}
