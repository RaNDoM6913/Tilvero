// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI

/// The look of a pill button on the Charge page, split in two: whether it is on offer (dims it, steadily) and whether the
/// model is busy for a moment (a read or an apply in flight). Busy only ignores taps; it never changes the look, so
/// applying a new limit does not make the neighbouring buttons blink.
struct SteadyControlLook: Equatable {
    var offered: Bool
    var busy: Bool
    var dimmedOpacity: Double = 0.45

    var opacity: Double { offered ? 1 : dimmedOpacity }
    var acceptsTaps: Bool { offered && !busy }
}

extension View {
    /// Dims by `look.opacity` only; busy blocks hit testing instead of `.disabled`, which would dim the label too.
    func steadyControl(_ look: SteadyControlLook) -> some View {
        opacity(look.opacity).allowsHitTesting(look.acceptsTaps)
    }
}
