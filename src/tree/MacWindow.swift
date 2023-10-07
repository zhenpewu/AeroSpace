final class MacWindow: Window, CustomStringConvertible {
    let axWindow: AXUIElement
    let app: MacApp
    private var prevUnhiddenEmulationPositionRelativeToWorkspaceAssignedRect: CGPoint?
    fileprivate var previousSize: CGSize?
    private var axObservers: [AxObserverWrapper] = [] // keep observers in memory

    private init(_ id: CGWindowID, _ app: MacApp, _ axWindow: AXUIElement, parent: TreeNode, adaptiveWeight: CGFloat) {
        self.app = app
        self.axWindow = axWindow
        super.init(id: id, parent: parent, adaptiveWeight: adaptiveWeight)
    }

    private static var allWindowsMap: [CGWindowID: MacWindow] = [:]
    static var allWindows: [MacWindow] { Array(allWindowsMap.values) }

    static func get(app: MacApp, axWindow: AXUIElement) -> MacWindow? {
        guard let id = axWindow.windowId() else { return nil }
        if let existing = allWindowsMap[id] {
            return existing
        } else {
            let focusedWorkspace = Workspace.focused
            let workspace: Workspace
            // todo rewrite. Window is appeared on empty space
            if focusedWorkspace == currentEmptyWorkspace &&
                       focusedApp == app &&
                       app.axFocusedWindow?.windowId() == axWindow.windowId() {
                workspace = currentEmptyWorkspace
            } else {
                guard let topLeftCorner = axWindow.get(Ax.topLeftCornerAttr) else { return nil }
                workspace = topLeftCorner.monitorApproximation.getActiveWorkspace()
            }
            let parent: TreeNode
            if shouldFloat(axWindow) {
                parent = workspace
            } else {
                let tilingParent = workspace.mostRecentWindow?.parent as? TilingContainer ?? workspace.rootTilingContainer
                parent = tilingParent
            }
            let window = MacWindow(id, app, axWindow, parent: parent, adaptiveWeight: WEIGHT_AUTO)

            if window.observe(refreshObs, kAXUIElementDestroyedNotification) &&
                       window.observe(refreshObs, kAXWindowDeminiaturizedNotification) &&
                       window.observe(refreshObs, kAXWindowMiniaturizedNotification) &&
                       window.observe(refreshObs, kAXMovedNotification) &&
                       window.observe(refreshObs, kAXResizedNotification) {
                debug("New window detected: \(window)")
                allWindowsMap[id] = window
                return window
            } else {
                window.garbageCollect()
                return nil
            }
        }
    }

    var description: String {
        let description = [
            ("title", title),
            ("role", axWindow.get(Ax.roleAttr)),
            ("subrole", axWindow.get(Ax.subroleAttr)),
            ("value", axWindow.get(Ax.valueAttr)),
            ("modal", axWindow.get(Ax.modalAttr).map { String($0) } ?? ""),
            ("windowId", String(windowId))
        ].map { "\($0.0): '\(String(describing: $0.1))'" }.joined(separator: ", ")
        return "Window(\(description))"
    }

    func garbageCollect() {
        debug("garbageCollectWindow of \(app.title ?? "NO TITLE")")
        MacWindow.allWindowsMap.removeValue(forKey: windowId)
        unbindFromParent()
        for obs in axObservers {
            AXObserverRemoveNotification(obs.obs, obs.ax, obs.notif)
        }
        axObservers = []
    }

    private func observe(_ handler: AXObserverCallback, _ notifKey: String) -> Bool {
        guard let observer = AXObserver.observe(app.nsApp.processIdentifier, notifKey, axWindow, handler) else { return false }
        axObservers.append(AxObserverWrapper(obs: observer, ax: axWindow, notif: notifKey as CFString))
        return true
    }

    override var title: String? {
        axWindow.get(Ax.titleAttr)
    }

    @discardableResult
    override func focus() -> Bool {
        // Raise firstly to make sure that by that time we activate the app, particular window would be already on top
        if axWindow.raise() && app.nsApp.activate(options: .activateIgnoringOtherApps) {
            markAsMostRecentChild()
            return true
        } else {
            return false
        }
    }

    func close() -> Bool {
        guard let closeButton = axWindow.get(Ax.closeButtonAttr) else { return false }
        return AXUIElementPerformAction(closeButton, kAXPressAction as CFString) == AXError.success
    }

    // todo current approach breaks mission control (three fingers up the trackpad). Or is it only because of IDEA?
    // todo hypnotize: change size to cooperate with mission control (make it configurable)
    func hideViaEmulation() {
        //guard let monitorApproximation else { return }
        // Don't accidentally override prevUnhiddenEmulationPosition in case of subsequent
        // `hideEmulation` calls
        if !isHiddenViaEmulation {
            debug("hideViaEmulation: Hide \(self)")
            guard let topLeftCorner = getTopLeftCorner() else { return }
            guard let size = getSize() else { return }
            prevUnhiddenEmulationPositionRelativeToWorkspaceAssignedRect =
                    topLeftCorner - workspace.assignedMonitorOfNotEmptyWorkspace.rect.topLeftCorner
        }
        setTopLeftCorner(allMonitorsRectsUnion.bottomRightCorner)
    }

    func unhideViaEmulation() {
        guard let prevUnhiddenEmulationPositionRelativeToWorkspaceAssignedRect else { return }

        setTopLeftCorner(workspace.assignedMonitorOfNotEmptyWorkspace.rect.topLeftCorner + prevUnhiddenEmulationPositionRelativeToWorkspaceAssignedRect)

        self.prevUnhiddenEmulationPositionRelativeToWorkspaceAssignedRect = nil
    }

    var isHiddenViaEmulation: Bool {
        return prevUnhiddenEmulationPositionRelativeToWorkspaceAssignedRect != nil
    }

    override func setSize(_ size: CGSize) {
        previousSize = getSize()
        axWindow.set(Ax.sizeAttr, size)
    }

    func getSize() -> CGSize? {
        axWindow.get(Ax.sizeAttr)
    }

    override func setTopLeftCorner(_ point: CGPoint) {
        axWindow.set(Ax.topLeftCornerAttr, point)
    }

    private func getTopLeftCorner() -> CGPoint? {
        axWindow.get(Ax.topLeftCornerAttr)
    }

    override func getRect() -> Rect? {
        guard let topLeftCorner = getTopLeftCorner() else { return nil }
        guard let size = getSize() else { return nil }
        return Rect(topLeftX: topLeftCorner.x, topLeftY: topLeftCorner.y, width: size.width, height: size.height)
    }

    static func garbageCollectClosedWindows() {
        for window in allWindows {
            if window.axWindow.windowId() == nil {
                window.garbageCollect()
            }
        }
    }
}

func shouldFloat(_ axWindow: AXUIElement) -> Bool {
    // Don't tile:
    // - Chrome cmd+f window ("AXUnknown" value)
    // - login screen (Yes fuck, it's also a window from Apple's API perspective) ("AXUnknown" value)
    // - XCode "Build succeeded" popup
    // - IntelliJ tooltips, context menus, drop downs
    // - macOS native file picker ("Open..." menu)
    //
    // Minimized windows or windows of a hidden app have subrole "AXDialog"
    axWindow.get(Ax.subroleAttr) != kAXStandardWindowSubrole || config.debugAllWindowsAreFloating
}
