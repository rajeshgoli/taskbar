import AppKit

struct WindowSwitcherItem: Equatable {
    let id: String
    let cgWindowID: CGWindowID?
    let appName: String
    let title: String
    let icon: NSImage?
}

@MainActor
final class WindowSwitcherThumbnailProvider {
    typealias Completion = (NSImage?) -> Void

    private let thumbnailService: ThumbnailService
    private let thumbnailSize: CGSize
    private var captureSessionTask: Task<ThumbnailCaptureSession, Never>?
    private var workerTask: Task<Void, Never>?
    private var pendingWindowIDs: [CGWindowID] = []
    private var pendingWindowIDSet = Set<CGWindowID>()
    private var inFlightWindowIDs = Set<CGWindowID>()
    private var completionsByWindowID: [CGWindowID: [Completion]] = [:]

    init(
        thumbnailService: ThumbnailService,
        thumbnailSize: CGSize = CGSize(width: 360, height: 230)
    ) {
        self.thumbnailService = thumbnailService
        self.thumbnailSize = thumbnailSize
    }

    func cachedThumbnail(for windowID: CGWindowID) -> NSImage? {
        thumbnailService.cachedThumbnail(windowID: windowID)
    }

    func requestThumbnail(
        windowID: CGWindowID,
        completion: @escaping Completion
    ) {
        guard windowID != 0 else {
            completion(nil)
            return
        }

        if let cachedThumbnail = cachedThumbnail(for: windowID) {
            completion(cachedThumbnail)
            return
        }

        completionsByWindowID[windowID, default: []].append(completion)

        if !pendingWindowIDSet.contains(windowID), !inFlightWindowIDs.contains(windowID) {
            pendingWindowIDs.append(windowID)
            pendingWindowIDSet.insert(windowID)
        }

        startWorkerIfNeeded()
    }

    func prioritize(windowID: CGWindowID) {
        guard let index = pendingWindowIDs.firstIndex(of: windowID), index > 0 else {
            return
        }

        pendingWindowIDs.remove(at: index)
        pendingWindowIDs.insert(windowID, at: 0)
    }

    func cancel() {
        workerTask?.cancel()
        captureSessionTask?.cancel()
        workerTask = nil
        captureSessionTask = nil
        pendingWindowIDs.removeAll()
        pendingWindowIDSet.removeAll()
        inFlightWindowIDs.removeAll()
        completionsByWindowID.removeAll()
    }

    private func startWorkerIfNeeded() {
        guard workerTask == nil else {
            return
        }

        workerTask = Task { @MainActor [weak self] in
            await self?.runWorker()
        }
    }

    private func runWorker() async {
        defer {
            workerTask = nil

            if !pendingWindowIDs.isEmpty {
                startWorkerIfNeeded()
            }
        }

        let captureSession = await resolvedCaptureSession()

        while !Task.isCancelled, !pendingWindowIDs.isEmpty {
            let windowID = pendingWindowIDs.removeFirst()
            pendingWindowIDSet.remove(windowID)
            inFlightWindowIDs.insert(windowID)

            let image = await captureSession.captureThumbnail(
                windowID: windowID,
                size: thumbnailSize
            )

            inFlightWindowIDs.remove(windowID)

            let completions = completionsByWindowID.removeValue(forKey: windowID) ?? []
            completions.forEach { $0(image) }
        }
    }

    private func resolvedCaptureSession() async -> ThumbnailCaptureSession {
        if let captureSessionTask {
            return await captureSessionTask.value
        }

        let task = Task { @MainActor [thumbnailService] in
            await thumbnailService.makeCaptureSession()
        }
        captureSessionTask = task
        return await task.value
    }
}

final class WindowSwitcherPanel: NSPanel {
    private let switcherView = WindowSwitcherOverlayView()

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isFloatingPanel = true
        ignoresMouseEvents = true
        level = .screenSaver
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        contentView = switcherView
    }

    func update(
        screen: NSScreen,
        items: [WindowSwitcherItem],
        selectedIndex: Int,
        thumbnailProvider: WindowSwitcherThumbnailProvider
    ) {
        setFrame(screen.frame, display: true)
        switcherView.update(
            items: items,
            selectedIndex: selectedIndex,
            thumbnailProvider: thumbnailProvider
        )
    }

    func closeSwitcher() {
        orderOut(nil)
        switcherView.clear()
    }
}

private final class WindowSwitcherOverlayView: NSView {
    private let backdropView = NSVisualEffectView()
    private let dimmingView = NSView()
    private let glassView = LiquidGlassContainerView()
    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    private var cardViews: [WindowSwitcherCardView] = []
    private var generation = UUID()
    private var selectedIndex = 0
    private var currentItemIDs: [String] = []
    private var currentItems: [WindowSwitcherItem] = []
    private weak var thumbnailProvider: WindowSwitcherThumbnailProvider?

    private var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    private var increaseContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        backdropView.material = .hudWindow
        backdropView.blendingMode = .behindWindow
        backdropView.state = .active
        addSubview(backdropView)

        dimmingView.wantsLayer = true
        addSubview(dimmingView)

        glassView.wantsLayer = true
        addSubview(glassView)

        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 28, bottom: 0, right: 28)
        addSubview(scrollView)

        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 18
        stackView.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        scrollView.documentView = stackView
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()

        backdropView.frame = bounds
        dimmingView.frame = bounds

        let availableWidth = max(360, bounds.width - 120)
        let desiredWidth = CGFloat(max(1, min(cardViews.count, 5))) * 286 + 92
        let width = min(availableWidth, max(460, desiredWidth))
        let height = min(max(260, bounds.height - 160), selectedIndexCardHeight + 84)
        glassView.frame = CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
        scrollView.frame = glassView.frame.insetBy(dx: 22, dy: 22)
        stackView.frame.size = stackView.fittingSize
        updateColors()
        centerSelectedCard()
    }

    func update(
        items: [WindowSwitcherItem],
        selectedIndex: Int,
        thumbnailProvider: WindowSwitcherThumbnailProvider
    ) {
        let nextItemIDs = items.map(\.id)
        self.selectedIndex = min(max(0, selectedIndex), max(0, items.count - 1))
        self.thumbnailProvider = thumbnailProvider

        if nextItemIDs == currentItemIDs {
            currentItems = items
            updateCardSelection()
            prioritizeSelectedThumbnail()
            needsLayout = true
            layoutSubtreeIfNeeded()
            centerSelectedCard()
            return
        }

        generation = UUID()
        currentItemIDs = nextItemIDs
        currentItems = items

        while let view = stackView.arrangedSubviews.first {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        cardViews = items.enumerated().map { index, item in
            let cardView = WindowSwitcherCardView()
            cardView.update(item: item, isSelected: index == self.selectedIndex)
            stackView.addArrangedSubview(cardView)
            return cardView
        }

        loadThumbnails(for: items, thumbnailProvider: thumbnailProvider, generation: generation)
        needsLayout = true
        layoutSubtreeIfNeeded()
        centerSelectedCard()
    }

    func clear() {
        generation = UUID()
        currentItemIDs.removeAll()
        currentItems.removeAll()
        thumbnailProvider = nil
    }

    private var selectedIndexCardHeight: CGFloat {
        246
    }

    private func loadThumbnails(
        for items: [WindowSwitcherItem],
        thumbnailProvider: WindowSwitcherThumbnailProvider,
        generation: UUID
    ) {
        for index in Self.thumbnailLoadOrder(count: items.count, selectedIndex: selectedIndex) {
            let item = items[index]
            guard let cgWindowID = item.cgWindowID else {
                continue
            }

            if let cachedThumbnail = thumbnailProvider.cachedThumbnail(for: cgWindowID) {
                cardViews[index].thumbnail = cachedThumbnail
                continue
            }

            thumbnailProvider.requestThumbnail(windowID: cgWindowID) { [weak self] image in
                guard let self,
                      self.generation == generation,
                      self.cardViews.indices.contains(index) else {
                    return
                }

                self.cardViews[index].thumbnail = image
            }
        }
    }

    private func prioritizeSelectedThumbnail() {
        guard
            let thumbnailProvider,
            currentItems.indices.contains(selectedIndex),
            let cgWindowID = currentItems[selectedIndex].cgWindowID
        else {
            return
        }

        thumbnailProvider.prioritize(windowID: cgWindowID)
        guard cardViews.indices.contains(selectedIndex), cardViews[selectedIndex].thumbnail == nil else {
            return
        }

        let generation = generation
        let selectedIndex = selectedIndex
        thumbnailProvider.requestThumbnail(windowID: cgWindowID) { [weak self] image in
            guard let self,
                  self.generation == generation,
                  self.cardViews.indices.contains(selectedIndex) else {
                return
            }

            self.cardViews[selectedIndex].thumbnail = image
        }
    }

    private static func thumbnailLoadOrder(count: Int, selectedIndex: Int) -> [Int] {
        guard count > 0 else {
            return []
        }

        let selectedIndex = min(max(0, selectedIndex), count - 1)
        var orderedIndexes: [Int] = []
        var seenIndexes = Set<Int>()

        for distance in 0..<count {
            for index in [selectedIndex + distance, selectedIndex - distance] {
                guard index >= 0, index < count, seenIndexes.insert(index).inserted else {
                    continue
                }

                orderedIndexes.append(index)
            }
        }

        return orderedIndexes
    }

    private func updateCardSelection() {
        for (index, cardView) in cardViews.enumerated() {
            cardView.updateSelection(isSelected: index == selectedIndex)
        }
    }

    private func updateColors() {
        backdropView.alphaValue = reduceTransparency ? 0 : 0.28
        let dimAlpha: CGFloat
        if increaseContrast {
            dimAlpha = 0.42
        } else if reduceTransparency {
            dimAlpha = 0.78
        } else {
            dimAlpha = 0.16
        }
        dimmingView.layer?.backgroundColor = NSColor.black.withAlphaComponent(dimAlpha).cgColor
        glassView.configure(reduceTransparency: reduceTransparency, increaseContrast: increaseContrast)
    }

    private func centerSelectedCard() {
        guard cardViews.indices.contains(selectedIndex) else {
            return
        }

        let selectedFrame = cardViews[selectedIndex].convert(cardViews[selectedIndex].bounds, to: scrollView.documentView)
        let clipBounds = scrollView.contentView.bounds
        let targetX = selectedFrame.midX - clipBounds.width / 2
        let maxX = max(0, stackView.bounds.width - clipBounds.width)
        let clampedX = min(max(0, targetX), maxX)
        scrollView.contentView.scroll(to: CGPoint(x: clampedX, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

private final class LiquidGlassContainerView: NSVisualEffectView {
    private let rimLayer = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 34
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.42
        layer?.shadowRadius = 34
        layer?.shadowOffset = CGSize(width: 0, height: 18)

        rimLayer.startPoint = CGPoint(x: 0, y: 0)
        rimLayer.endPoint = CGPoint(x: 1, y: 1)
        rimLayer.cornerRadius = 34
        rimLayer.cornerCurve = .continuous
        layer?.addSublayer(rimLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        rimLayer.frame = bounds
    }

    func configure(reduceTransparency: Bool, increaseContrast: Bool) {
        if reduceTransparency {
            alphaValue = 1
            material = .windowBackground
            layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        } else {
            alphaValue = increaseContrast ? 0.52 : 0.32
            material = .hudWindow
            layer?.backgroundColor = NSColor.white.withAlphaComponent(increaseContrast ? 0.10 : 0.02).cgColor
        }

        rimLayer.colors = [
            NSColor.white.withAlphaComponent(increaseContrast ? 0.66 : 0.24).cgColor,
            NSColor.controlAccentColor.withAlphaComponent(increaseContrast ? 0.26 : 0.10).cgColor,
            NSColor.black.withAlphaComponent(0.04).cgColor
        ]
        rimLayer.borderWidth = increaseContrast ? 1.5 : 1
        rimLayer.borderColor = NSColor.white.withAlphaComponent(increaseContrast ? 0.58 : 0.28).cgColor
    }
}

private final class WindowSwitcherCardView: NSView {
    private let backgroundView = NSVisualEffectView()
    private let thumbnailView = NSImageView()
    private let fallbackIconView = NSImageView()
    private let iconBadgeView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let appField = NSTextField(labelWithString: "")
    private let footerView = NSView()
    private var item: WindowSwitcherItem?
    private var isSelected = false

    override var intrinsicContentSize: NSSize {
        NSSize(width: isSelected ? 316 : 258, height: isSelected ? 258 : 210)
    }

    var thumbnail: NSImage? {
        get { thumbnailView.image }
        set {
            thumbnailView.image = newValue
            thumbnailView.isHidden = newValue == nil
            fallbackIconView.isHidden = newValue != nil
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        backgroundView.material = .hudWindow
        backgroundView.blendingMode = .withinWindow
        backgroundView.state = .active
        backgroundView.wantsLayer = true
        addSubview(backgroundView)

        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 18
        thumbnailView.layer?.cornerCurve = .continuous
        thumbnailView.layer?.masksToBounds = true
        thumbnailView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        addSubview(thumbnailView)

        fallbackIconView.imageScaling = .scaleProportionallyUpOrDown
        fallbackIconView.alphaValue = 0.36
        addSubview(fallbackIconView)

        footerView.wantsLayer = true
        addSubview(footerView)

        iconBadgeView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconBadgeView)

        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.textColor = .labelColor
        addSubview(titleField)

        appField.font = .systemFont(ofSize: 11, weight: .medium)
        appField.lineBreakMode = .byTruncatingTail
        appField.textColor = .secondaryLabelColor
        addSubview(appField)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        let selectedInset: CGFloat = isSelected ? 10 : 14
        backgroundView.frame = bounds.insetBy(dx: 2, dy: 2)
        backgroundView.layer?.cornerRadius = isSelected ? 26 : 22
        backgroundView.layer?.cornerCurve = .continuous

        let imageFrame = bounds.insetBy(dx: selectedInset, dy: selectedInset)
        let footerHeight: CGFloat = isSelected ? 66 : 58
        thumbnailView.frame = CGRect(
            x: imageFrame.minX,
            y: imageFrame.minY + footerHeight,
            width: imageFrame.width,
            height: max(64, imageFrame.height - footerHeight)
        )
        fallbackIconView.frame = thumbnailView.frame.insetBy(dx: thumbnailView.frame.width * 0.32, dy: thumbnailView.frame.height * 0.18)
        footerView.frame = CGRect(
            x: imageFrame.minX,
            y: imageFrame.minY,
            width: imageFrame.width,
            height: footerHeight
        )
        iconBadgeView.frame = CGRect(
            x: footerView.frame.minX + 12,
            y: footerView.frame.midY - 16,
            width: 32,
            height: 32
        )
        titleField.frame = CGRect(
            x: iconBadgeView.frame.maxX + 10,
            y: footerView.frame.midY + 1,
            width: max(1, footerView.frame.width - 62),
            height: 18
        )
        appField.frame = CGRect(
            x: iconBadgeView.frame.maxX + 10,
            y: footerView.frame.midY - 18,
            width: max(1, footerView.frame.width - 62),
            height: 16
        )
        updateLayerStyle()
    }

    func update(item: WindowSwitcherItem, isSelected: Bool) {
        self.item = item
        self.isSelected = isSelected
        iconBadgeView.image = item.icon
        fallbackIconView.image = item.icon
        titleField.stringValue = item.title
        appField.stringValue = item.appName
        thumbnail = nil
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    func updateSelection(isSelected: Bool) {
        guard self.isSelected != isSelected else {
            return
        }

        self.isSelected = isSelected
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func updateLayerStyle() {
        layer?.cornerRadius = isSelected ? 28 : 24
        layer?.cornerCurve = .continuous
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = isSelected ? 0.46 : 0.22
        layer?.shadowRadius = isSelected ? 22 : 12
        layer?.shadowOffset = CGSize(width: 0, height: isSelected ? 12 : 7)
        layer?.borderWidth = isSelected ? 2.5 : 1
        layer?.borderColor = (isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.92)
            : NSColor.white.withAlphaComponent(0.28)
        ).cgColor
        backgroundView.alphaValue = isSelected ? 0.92 : 0.78
        footerView.layer?.cornerRadius = 16
        footerView.layer?.cornerCurve = .continuous
        footerView.layer?.backgroundColor = NSColor.black.withAlphaComponent(isSelected ? 0.46 : 0.34).cgColor
        titleField.textColor = .white
        appField.textColor = NSColor.white.withAlphaComponent(0.72)
    }
}
