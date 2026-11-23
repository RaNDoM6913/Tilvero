// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI

/// Settings › Quick menu: the blocks builder and the sleep presets editor (IA §5).
@MainActor struct SettingsQuickMenuPane: View {
    var model: TilveroModel
    var body: some View {
        SettingsScroll {
            QuickMenuSettingsEditor(model: model)
        }
    }
}
