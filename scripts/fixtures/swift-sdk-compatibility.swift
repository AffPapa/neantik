// No app, credentials, networking or execution: this is a compiler/SDK probe.
import AppKit
import Combine
import CommonCrypto
import CoreFoundation
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import Network
import OSLog
import JavaScriptCore
import ObjectiveC
import Security
import SwiftUI
import UniformTypeIdentifiers
import WebKit

@MainActor
func checkManagerAPIs(_ view: WKWebView, _ window: NSWindow) {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    _ = WKWebsiteDataStore(forIdentifier: UUID())
    config.preferences.javaScriptCanOpenWindowsAutomatically = false
    view.stopLoading()
    window.contentView = view
    _ = Text("Compatibility").accessibilityLabel("Compatibility")
    _ = UTType.json
    _ = NWEndpoint.Host("127.0.0.1")
    _ = SHA256.hash(data: Data())
    _ = kSecClassGenericPassword
    _ = CC_SHA256_DIGEST_LENGTH
}
