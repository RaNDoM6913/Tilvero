// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI

/// Settings › Quick menu. For now the existing quick-panel builder inside one tile; the presets editor (IA §5) replaces
/// this single view.
@MainActor struct SettingsQuickMenuPane: View {
    var model: TilveroModel
    var body: some View {
        SettingsScroll {
            WindowTile { QuickPanelBuilder(model: model) }
        }
    }
}
