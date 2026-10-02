import SwiftUI

/// The macOS 27 SDK turns `@State` into a macro whose plugin ships only with Xcode.
/// Naming the property wrapper struct through an alias keeps the project buildable
/// with just the Command Line Tools.
typealias ViewState<Value> = SwiftUI.State<Value>
