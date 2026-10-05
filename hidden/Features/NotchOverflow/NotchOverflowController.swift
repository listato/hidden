//
//  NotchOverflowController.swift
//  Hidden Bar
//
//  Created by Nadir on 2026/03/30.
//  Copyright © 2026 Dwarves Foundation. All rights reserved.
//

import AppKit
import ApplicationServices

// MARK: - Menu Bar Extra Info

struct MenuBarExtraInfo {
  let element: AXUIElement
  let appName: String
  let appIcon: NSImage?
  let title: String?
  let pid: pid_t
  let position: CGPoint
  let size: CGSize
}

// MARK: - Notch Geometry

/// Pure geometry: where the notch is and which X coordinates on the menu-bar
/// row it makes unreachable. Kept free of NSScreen/AppKit calls so it can be
/// unit-tested with synthetic screen values instead of live hardware.
struct NotchBoundary: Equatable {
  let hasNotch: Bool
  /// The leftmost X, in screen coordinates, at which a status item is
  /// guaranteed clear of the notch. Items positioned left of this are
  /// either under the notch or squeezed off past its left edge.
  let overflowThresholdX: CGFloat
}

enum NotchGeometry {
  // Matches the pre-fix behavior's default (half of a common 1728pt-wide
  // screen) so a screen that unexpectedly can't report safeAreaInsets still
  // gets a sane threshold instead of 0.
  static let fallbackThresholdX: CGFloat = 972

  /// - Parameters:
  ///   - screenFrame: the candidate screen's full frame (`NSScreen.frame`).
  ///   - safeAreaInsetsTop: `NSScreen.safeAreaInsets.top`; > 0 on notched Macs.
  ///   - auxiliaryTopRightAreaMinX: `NSScreen.auxiliaryTopRightArea?.minX`,
  ///     Apple's own safe-rect boundary for content right of the notch.
  static func computeBoundary(
    screenFrame: CGRect,
    safeAreaInsetsTop: CGFloat,
    auxiliaryTopRightAreaMinX: CGFloat?
  ) -> NotchBoundary {
    let hasNotch = safeAreaInsetsTop > 0
    guard hasNotch, let thresholdX = auxiliaryTopRightAreaMinX else {
      return NotchBoundary(hasNotch: hasNotch, overflowThresholdX: fallbackThresholdX)
    }
    return NotchBoundary(hasNotch: true, overflowThresholdX: thresholdX)
  }
}

// MARK: - Extras Classification

/// Pure classification of already-fetched extras against a boundary. Split
/// from AX enumeration so the sorting/filtering rules are testable without
/// a live Accessibility permission or other running apps.
enum MenuBarExtraClassifier {
  static func classify(
    _ extras: [MenuBarExtraInfo],
    boundary: CGFloat
  ) -> (hidden: [MenuBarExtraInfo], visible: [MenuBarExtraInfo]) {
    let renderable = extras.filter { $0.size.width > 0 && $0.size.height > 0 }
    let hidden = renderable
      .filter { $0.position.x < boundary }
      .sorted { $0.position.x > $1.position.x }
    let visible = renderable
      .filter { $0.position.x >= boundary }
      .sorted { $0.position.x > $1.position.x }
    return (hidden, visible)
  }
}

// MARK: - NotchOverflowController

class NotchOverflowController: NSObject {

  // Diagnostic messages are evaluated and printed only in Debug builds.
  private func log(_ message: @autoclosure () -> String) {
    #if DEBUG
    NSLog("[HiddenBar Notch] %@", message())
    #endif
  }

  // MARK: - Notch Detection

  private static func currentBoundary() -> NotchBoundary {
    guard let screen = NSScreen.main else {
      return NotchBoundary(hasNotch: false, overflowThresholdX: NotchGeometry.fallbackThresholdX)
    }
    let safeAreaTop: CGFloat
    let auxRightMinX: CGFloat?
    if #available(macOS 12.0, *) {
      safeAreaTop = screen.safeAreaInsets.top
      auxRightMinX = screen.auxiliaryTopRightArea?.minX
    } else {
      safeAreaTop = 0
      auxRightMinX = nil
    }
    return NotchGeometry.computeBoundary(
      screenFrame: screen.frame,
      safeAreaInsetsTop: safeAreaTop,
      auxiliaryTopRightAreaMinX: auxRightMinX
    )
  }

  static var hasNotch: Bool {
    currentBoundary().hasNotch
  }

  /// Show overflow menu anchored to a status item (called from StatusBarController)
  func showOverflowMenuFromSeparator(near item: NSStatusItem) {
    log("Richiesta apertura elenco; app=\(Bundle.main.bundleURL.path), pid=\(ProcessInfo.processInfo.processIdentifier)")
    guard ensureAccessibility() else {
      log("Apertura interrotta: permesso Accessibilità mancante.")
      return
    }
    let menu = buildOverflowMenu()
    // Wait until the originating context menu has finished its action.
    DispatchQueue.main.async { [weak self] in
      guard let button = item.button else {
        self?.log("Apertura interrotta: pulsante della barra assente.")
        return
      }
      self?.log("Apertura menu con \(menu.items.count) righe.")
      menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: button)
      self?.log("Menu chiuso.")
    }
  }

  // MARK: - Menu Building

  func buildOverflowMenu(
    extras: [MenuBarExtraInfo]? = nil,
    boundary: CGFloat? = nil
  ) -> NSMenu {
    let allExtras = extras ?? getAllMenuBarExtras()
    let resolvedBoundary = boundary ?? Self.currentBoundary().overflowThresholdX
    let (hiddenExtras, visibleExtras) = MenuBarExtraClassifier.classify(allExtras, boundary: resolvedBoundary)

    #if DEBUG
    let excluded = allExtras.filter { $0.size.width <= 0 || $0.size.height <= 0 }
    log("Rilevate=\(allExtras.count), nascoste=\(hiddenExtras.count), visibili=\(visibleExtras.count), escluse=\(excluded.count), sogliaX=\(resolvedBoundary)")
    for info in excluded {
      log("Esclusa: \(info.appName), pid=\(info.pid), posizione=\(info.position), dimensioni=\(info.size)")
    }

    #endif

    let menu = NSMenu()
    menu.autoenablesItems = false

    // Title
    menu.addItem(makeSectionHeader(title: "Notch Overflow".localized, fontSize: 12))
    menu.addItem(NSMenuItem.separator())

    // Hidden section
    if !hiddenExtras.isEmpty {
      menu.addItem(makeSectionHeader(title: String(format: "Hidden Behind Notch (%d)".localized, hiddenExtras.count)))
      menu.addItem(NSMenuItem.separator())

      for info in hiddenExtras {
        menu.addItem(makeMenuItem(for: info, hidden: true))
      }
    }

    // Visible section
    if !visibleExtras.isEmpty {
      if !hiddenExtras.isEmpty { menu.addItem(NSMenuItem.separator()) }
      menu.addItem(makeSectionHeader(title: String(format: "Visible (%d)".localized, visibleExtras.count)))
      menu.addItem(NSMenuItem.separator())

      for info in visibleExtras {
        menu.addItem(makeMenuItem(for: info, hidden: false))
      }
    }

    // Empty state
    if hiddenExtras.isEmpty && visibleExtras.isEmpty {
      let emptyItem = NSMenuItem(
        title: "No items found (grant Accessibility permission)".localized,
        action: nil, keyEquivalent: "")
      emptyItem.isEnabled = false
      menu.addItem(emptyItem)
    }

    return menu
  }

  // Disabled, non-interactive label. Bold + labelColor (full contrast) rather
  // than secondaryLabelColor/AppKit's default disabled-item dimming, which
  // read poorly against a dark selection highlight.
  private func makeSectionHeader(title: String, fontSize: CGFloat = 13) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    item.attributedTitle = NSAttributedString(
      string: title,
      attributes: [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
        .foregroundColor: NSColor.labelColor
      ])
    return item
  }

  private func makeMenuItem(for info: MenuBarExtraInfo, hidden: Bool = false) -> NSMenuItem {
    let item = NSMenuItem()
    let displayTitle = (info.title?.isEmpty == false) ? info.title! : info.appName

    if hidden {
      // Color alone isn't an accessible way to convey "hidden" (colorblind
      // users get nothing from it, and systemOrange reads poorly against a
      // dark selection highlight). A glyph + bold weight works in any theme.
      item.attributedTitle = NSAttributedString(
        string: "\u{26A0}\u{FE0F} \(displayTitle)",
        attributes: [
          .font: NSFont.boldSystemFont(ofSize: 13),
          .foregroundColor: NSColor.labelColor
        ])
    } else {
      item.title = displayTitle
    }

    if let icon = info.appIcon {
      item.image = hidden ? icon.resizedForMenu(tinted: true) : icon.resizedForMenu()
    }
    item.representedObject = info
    item.target = self
    item.action = #selector(activateItem(_:))
    return item
  }

  @objc private func activateItem(_ sender: NSMenuItem) {
    guard let info = sender.representedObject as? MenuBarExtraInfo else { return }
    // Let the overflow menu finish tracking before asking another app to open its menu.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
      self?.log("Invio AXPress dopo la chiusura dell’elenco: \(info.appName)")
      let result = AXUIElementPerformAction(info.element, kAXPressAction as CFString)
      self?.log("Attivazione \(info.appName), pid=\(info.pid): AXPress=\(result.rawValue) (0=successo)")
    }
  }

  // MARK: - Accessibility

  private func ensureAccessibility() -> Bool {
    let trusted = AXIsProcessTrusted()
    log("Accessibilità autorizzata: \(trusted)")
    if trusted { return true }
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
    AXIsProcessTrustedWithOptions(opts)
    return false
  }

  // MARK: - AX Enumeration

  private func getAllMenuBarExtras() -> [MenuBarExtraInfo] {
    var results: [MenuBarExtraInfo] = []
    let myPID = ProcessInfo.processInfo.processIdentifier

    let applications = NSWorkspace.shared.runningApplications
    log("App in esecuzione da interrogare: \(applications.count)")
    for app in applications {
      if app.processIdentifier == myPID { continue }

      let axApp = AXUIElementCreateApplication(app.processIdentifier)
      var extrasRef: AnyObject?
      let err = AXUIElementCopyAttributeValue(
        axApp, "AXExtrasMenuBar" as CFString, &extrasRef)
      log("\(app.localizedName ?? "Unknown") pid=\(app.processIdentifier): AXExtrasMenuBar=\(err.rawValue)")
      guard err == .success, let extrasRef = extrasRef else { continue }

      var childrenRef: AnyObject?
      let childErr = AXUIElementCopyAttributeValue(
        extrasRef as! AXUIElement,
        kAXChildrenAttribute as CFString, &childrenRef)
      log("\(app.localizedName ?? "Unknown"): AXChildren=\(childErr.rawValue), elementi=\((childrenRef as? [AXUIElement])?.count ?? 0)")
      guard childErr == .success,
        let children = childrenRef as? [AXUIElement]
      else { continue }

      for child in children {
        var titleRef: AnyObject?
        AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef)

        var posRef: AnyObject?
        let posErr = AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &posRef)
        var pos = CGPoint.zero
        if let pv = posRef { AXValueGetValue(pv as! AXValue, .cgPoint, &pos) }

        var sizeRef: AnyObject?
        let sizeErr = AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeRef)
        var size = CGSize.zero
        if let sv = sizeRef { AXValueGetValue(sv as! AXValue, .cgSize, &size) }

        log("Icona \(app.localizedName ?? "Unknown"): posizione=\(pos) [AX=\(posErr.rawValue)], dimensioni=\(size) [AX=\(sizeErr.rawValue)]")
        results.append(MenuBarExtraInfo(
          element: child,
          appName: app.localizedName ?? "Unknown",
          appIcon: app.icon,
          title: titleRef as? String,
          pid: app.processIdentifier,
          position: pos,
          size: size
        ))
      }
    }
    return results
  }

}

// MARK: - NSImage Extension

private extension NSImage {
  func resizedForMenu(tinted: Bool = false) -> NSImage {
    let target = NSSize(width: 18, height: 18)
    return NSImage(size: target, flipped: false) { rect in
      self.draw(in: rect,
                from: NSRect(origin: .zero, size: self.size),
                operation: .sourceOver, fraction: tinted ? 0.5 : 1.0)
      return true
    }
  }
}
