// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation

public enum ComfortBackendError: Error, Equatable, Sendable {
    /// The framework or device is not there; nothing was written.
    case unavailable
    /// A symbol or property of a system interface is missing or behaves differently; nothing was written.
    case interfaceChanged
    /// None, or more than one, built-in display: never guess which panel to write.
    case noBuiltInDisplay
    case invalidReading
    case invalidValue
    case writeRejected
    /// The audio device from the journal is gone (unplugged, disconnected).
    case deviceMissing
    case notSettable
}

/// Handle for an event subscription; cancelling is idempotent.
public protocol ComfortSubscription: AnyObject, Sendable { func cancel() }
