import AppKit

/// Native menu content; dragging previews the value and commits once on release.
@MainActor final class GrayscaleIntensityMenuView: NSView {
    private let slider: MenuIntensitySlider
    private let percentage = NSTextField(labelWithString: "")
    private let onCommit: (Double) -> Void

    init(intensity: Double, enabled: Bool, filterEnabled: Bool,
        onEditingChanged: @escaping (Bool) -> Void, onCommit: @escaping (Double) -> Void) {
        slider = MenuIntensitySlider(value: min(1, max(0, intensity)) * 100,
            minValue: 0, maxValue: 100, target: nil, action: nil)
        self.onCommit = onCommit
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 88))
        autoresizingMask = [.width]

        let title = NSTextField(labelWithString: "Grayscale intensity")
        title.font = .menuFont(ofSize: 13)
        addSubview(title)

        percentage.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        percentage.alignment = .right
        addSubview(percentage)

        slider.isContinuous = true
        let canEdit = enabled && filterEnabled
        slider.isEnabled = canEdit
        slider.target = self
        slider.action = #selector(valueChanged(_:))
        slider.onEditingChanged = onEditingChanged
        slider.onCommit = { [weak self] in self?.commit() }
        slider.setAccessibilityLabel("Grayscale intensity, percent")
        slider.toolTip = "0% is the lowest supported intensity. Turn grayscale off to remove the filter."
        addSubview(slider)

        let hint = NSTextField(labelWithString: filterEnabled ? "Applied when you release the slider." : "Enable grayscale to adjust intensity.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        addSubview(hint)
        for view in [title, percentage, slider, hint] { view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            title.heightAnchor.constraint(equalToConstant: 18),
            title.trailingAnchor.constraint(lessThanOrEqualTo: percentage.leadingAnchor, constant: -8),
            percentage.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            percentage.topAnchor.constraint(equalTo: title.topAnchor),
            percentage.widthAnchor.constraint(equalToConstant: 46),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            slider.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            slider.heightAnchor.constraint(equalToConstant: 24),
            hint.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            hint.topAnchor.constraint(equalTo: slider.bottomAnchor, constant: 4),
            hint.heightAnchor.constraint(equalToConstant: 16)
        ])
        if !canEdit {
            title.textColor = .disabledControlTextColor
            percentage.textColor = .disabledControlTextColor
        }
        updatePercentage()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func valueChanged(_ sender: NSSlider) {
        updatePercentage()
        // Accessibility/discrete changes have no mouse tracking session.
        if !slider.isTrackingMouse { commit() }
    }

    private func updatePercentage() {
        percentage.stringValue = "\(Int(slider.doubleValue.rounded()))%"
    }

    private func commit() {
        guard slider.isEnabled else { return }
        updatePercentage()
        onCommit(slider.doubleValue / 100)
    }
}

@MainActor private final class MenuIntensitySlider: NSSlider {
    private(set) var isTrackingMouse = false
    var onEditingChanged: ((Bool) -> Void)?
    var onCommit: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isTrackingMouse = true
        onEditingChanged?(true)
        super.mouseDown(with: event)
        isTrackingMouse = false
        onEditingChanged?(false)
        onCommit?()
    }
}
