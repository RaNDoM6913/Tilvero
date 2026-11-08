// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI

/// Rounded card around one overview metric: subtle fill, hairline border and
/// inner padding, all from semantic colours so light and dark both work.
struct MetricCardChrome: ViewModifier {
    static let cornerRadius: CGFloat = 12
    static let defaultPadding: CGFloat = 12
    var padding: CGFloat = MetricCardChrome.defaultPadding

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous).strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
    }
}

extension View {
    func metricCardChrome(padding: CGFloat = MetricCardChrome.defaultPadding) -> some View {
        modifier(MetricCardChrome(padding: padding))
    }
}
// tlv-origin:7d2b9f40c6e1a583
