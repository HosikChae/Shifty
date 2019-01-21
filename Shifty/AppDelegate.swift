//
//  AppDelegate.swift
//  Shifty
//
//  Created by Nate Thompson on 5/3/17.
//
//

import Cocoa
import ServiceManagement
import LetsMove
import Fabric
import Crashlytics
import MASPreferences_Shifty
import AXSwift
import SwiftLog
import Sparkle

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    let prefs = UserDefaults.standard
    @IBOutlet weak var statusMenu: NSMenu!
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var statusItemClicked: (() -> Void)?

    lazy var preferenceWindowController: PrefWindowController = {
        return PrefWindowController(
            viewControllers: [
                PrefGeneralViewController(),
                PrefShortcutsViewController(),
                PrefAboutViewController()],
            title: NSLocalizedString("prefs.title", comment: "Preferences"))
    }()

    var setupWindow: NSWindow!
    var setupWindowController: NSWindowController!

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        #if !DEBUG
            PFMoveToApplicationsFolderIfNecessary()
        #endif
        
        UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": true])
        
        let userDefaults = PrefManager.shared.userDefaults
        
        if userDefaults.bool(forKey: Keys.fabricCrashlyticsPermission) {
            Fabric.with([Crashlytics.self])
        } else if userDefaults.bool(forKey: Keys.hasSetupWindowShown) && userDefaults.value(forKey: Keys.lastInstalledShiftyVersion) == nil {
            // If updated from beta version
            userDefaults.set(true, forKey: Keys.fabricCrashlyticsPermission)
        }
        
        
        let versionObject = Bundle.main.infoDictionary?["CFBundleShortVersionString"]
        userDefaults.set(versionObject as? String ?? "", forKey: Keys.lastInstalledShiftyVersion)
        
        
        Event.appLaunched(preferredLocalization: Bundle.main.preferredLocalizations.first ?? "").record()

        logw("")
        logw("App launched")
        logw("macOS \(ProcessInfo().operatingSystemVersionString)")
        logw("Shifty Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")

        verifyOperatingSystemVersion()
        verifySupportsNightShift()

        let launcherAppIdentifier = "io.natethompson.ShiftyHelper"

        let startedAtLogin = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == launcherAppIdentifier
        }

        if startedAtLogin {
            DistributedNotificationCenter.default().post(name: .terminateApp, object: Bundle.main.bundleIdentifier!)
        }

        //Show alert if accessibility permissions have been revoked while app is not running
        if UserDefaults.standard.bool(forKey: Keys.isWebsiteControlEnabled) && !UIElement.isProcessTrusted() {
            logw("Accessibility permissions revoked while app was not running")
            showAccessibilityDeniedAlert()
            UserDefaults.standard.set(false, forKey: Keys.isWebsiteControlEnabled)
        }
        
        observeAccessibilityApiNotifications()
        
        NightShiftManager.initialize()
        RuleManager.initialize()

        logw("Night Shift state: \(NightShiftManager.isNightShiftEnabled)")
        logw("Schedule: \(NightShiftManager.schedule)")
        logw("")

        updateMenuBarIcon()
        setStatusToggle()
        
        let hasSetupWindowShown = userDefaults.bool(forKey: Keys.hasSetupWindowShown)
        
        if hasSetupWindowShown {
            checkForUpdatesInBackground()
        }

        if (!hasSetupWindowShown && !UIElement.isProcessTrusted()) || ProcessInfo.processInfo.environment["show_setup"] == "true" {
            showSetupWindow()
        }
    }
    
    
    
    //MARK: Called after application launch
    
    func verifyOperatingSystemVersion() {
        if !ProcessInfo().isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 10, minorVersion: 12, patchVersion: 4)) {
            Event.oldMacOSVersion(version: ProcessInfo().operatingSystemVersionString).record()
            logw("Operating system version not supported")
            NSApplication.shared.activate(ignoringOtherApps: true)
            
            let alert: NSAlert = NSAlert()
            alert.messageText = NSLocalizedString("alert.version_message", comment: "This version of macOS does not support Night Shift")
            alert.informativeText = NSLocalizedString("alert.version_informative", comment: "Update your Mac to version 10.12.4 or higher to use Shifty.")
            alert.alertStyle = NSAlert.Style.warning
            alert.addButton(withTitle: NSLocalizedString("general.ok", comment: "OK"))
            alert.runModal()
            
            NSApplication.shared.terminate(self)
        }
    }
    
    func verifySupportsNightShift() {
        if !NightShiftManager.supportsNightShift {
            Event.unsupportedHardware.record()
            logw("System does not support Night Shift")
            NSApplication.shared.activate(ignoringOtherApps: true)
            
            let alert: NSAlert = NSAlert()
            alert.messageText = NSLocalizedString("alert.hardware_message", comment: "Your Mac does not support Night Shift")
            alert.informativeText = NSLocalizedString("alert.hardware_informative", comment: "A newer Mac is required to use Shifty.")
            alert.alertStyle = NSAlert.Style.warning
            alert.addButton(withTitle: NSLocalizedString("general.ok", comment: "OK"))
            alert.runModal()
            
            NSApplication.shared.terminate(self)
        }
    }
    
    func showAccessibilityDeniedAlert() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        
        let alert: NSAlert = NSAlert()
        alert.messageText = NSLocalizedString("alert.accessibility_disabled_message", comment: "Accessibility permissions for Shifty have been disabled")
        alert.informativeText = NSLocalizedString("alert.accessibility_disabled_informative", comment: "Accessibility must be allowed to enable website shifting. Grant access to Shifty in Security & Privacy preferences, located in System Preferences.")
        alert.alertStyle = NSAlert.Style.warning
        alert.addButton(withTitle: NSLocalizedString("alert.open_preferences", comment: "Open System Preferences"))
        alert.addButton(withTitle: NSLocalizedString("alert.not_now", comment: "Not now"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            logw("Open System Preferences button clicked")
        } else {
            logw("Not now button clicked")
        }
    }
    
    /// Checks for updates and only notifies user if there is an update available. Limited to once every 24 hours.
    func checkForUpdatesInBackground() {
        // For some reason, Sparkle isn't doing this on its own.
        // Called on app launch and menu close
        
        guard let dateLastChecked = UserDefaults.standard.value(forKey: Keys.dateLastCheckedForUpdates) as? Date,
            let dayBeforeTimeInterval = TimeInterval(exactly: -86400) else { return }
        
        let date24HoursAgo = Date(timeIntervalSinceNow: dayBeforeTimeInterval)
        
        if dateLastChecked < date24HoursAgo {
            SUUpdater.shared()?.checkForUpdatesInBackground()
            UserDefaults.standard.set(Date(), forKey: Keys.dateLastCheckedForUpdates)
        }
    }
    
    func showSetupWindow() {
        let storyboard = NSStoryboard(name: "Setup", bundle: nil)
        setupWindowController = storyboard.instantiateInitialController() as? NSWindowController
        setupWindow = setupWindowController.window
        
        NSApplication.shared.activate(ignoringOtherApps: true)
        setupWindowController.showWindow(self)
        setupWindow.makeMain()
        
        UserDefaults.standard.set(true, forKey: Keys.hasSetupWindowShown)
    }
    
    func observeAccessibilityApiNotifications() {
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: nil) { _ in
            logw("Accessibility permissions changed: \(UIElement.isProcessTrusted(withPrompt: false))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: {
                if UIElement.isProcessTrusted(withPrompt: false) {
                    UserDefaults.standard.set(true, forKey: Keys.isWebsiteControlEnabled)
                } else {
                    UserDefaults.standard.set(false, forKey: Keys.isWebsiteControlEnabled)
                }
            })
        }
    }
    
    
    
    //MARK: Status menu item

    func updateMenuBarIcon() {
        var icon: NSImage
        if UserDefaults.standard.bool(forKey: Keys.isIconSwitchingEnabled),
            !NightShiftManager.isNightShiftEnabled {
            icon = #imageLiteral(resourceName: "sunOpenIcon")
        } else {
            icon = #imageLiteral(resourceName: "shiftyMenuIcon")
        }
        icon.isTemplate = true
        DispatchQueue.main.async {
            self.statusItem.button?.image = icon
        }
    }

    func setStatusToggle() {
        if prefs.bool(forKey: Keys.isStatusToggleEnabled) {
            statusItem.menu = nil
            if let button = statusItem.button {
                button.action = #selector(statusBarButtonClicked)
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
        } else {
            statusItem.menu = statusMenu
        }
    }

    @objc func statusBarButtonClicked(sender: NSStatusBarButton) {
        let event = NSApp.currentEvent!

        if event.type == NSEvent.EventType.rightMouseUp || event.modifierFlags.contains(.control) {
            statusItem.menu = statusMenu
            statusItem.popUpMenu(statusMenu)
            statusItem.menu = nil
        } else {
            statusItemClicked?()
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        logw("App terminated")
    }


}
