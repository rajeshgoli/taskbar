import AppKit

enum IconClickFeedback {
    static func show(on view: NSView) {
        view.wantsLayer = true

        guard let layer = view.layer else {
            return
        }

        layer.removeAnimation(forKey: "deskbar.iconClickBounce")

        let animation = CAKeyframeAnimation(keyPath: "transform.scale")
        animation.values = [1.0, 1.18, 0.94, 1.0]
        animation.keyTimes = [0, 0.35, 0.7, 1]
        animation.duration = 0.24
        animation.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeOut)
        ]
        layer.add(animation, forKey: "deskbar.iconClickBounce")
    }
}
