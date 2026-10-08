import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import AirThrowCore
#endif

/// The native track and knob retain AppKit's drag, keyboard and accessibility
/// behavior. Only verified/loaded ranges are added to the track drawing.
struct SeekProgressSlider: NSViewRepresentable {
    @Binding var value: Double
    let bounds: ClosedRange<Double>
    let readyRanges: [SeekRange]
    let onEditingChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> ProgressSlider {
        let slider = ProgressSlider(frame: .zero)
        slider.cell = ProgressSliderCell()
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.onEditingChanged = { [weak coordinator = context.coordinator, weak slider] editing in
            if editing, let slider { coordinator?.parent.value = slider.doubleValue }
            coordinator?.parent.onEditingChanged(editing)
        }
        return slider
    }
    func updateNSView(_ slider: ProgressSlider, context: Context) {
        context.coordinator.parent = self
        slider.minValue = bounds.lowerBound
        slider.maxValue = bounds.upperBound
        if !slider.isScrubbing { slider.doubleValue = min(max(value, slider.minValue), slider.maxValue) }
        slider.isEnabled = context.environment.isEnabled
        slider.controlSize = .regular
        (slider.cell as? ProgressSliderCell)?.readyRanges = readyRanges
        slider.needsDisplay = true
    }

    @MainActor final class Coordinator: NSObject {
        var parent: SeekProgressSlider
        init(_ parent: SeekProgressSlider) { self.parent = parent }
        @objc func changed(_ slider: ProgressSlider) {
            parent.value = slider.doubleValue
            if !slider.isScrubbing { parent.onEditingChanged(false) }
        }
    }
}

@MainActor final class ProgressSlider: NSSlider {
    private(set) var isScrubbing = false
    var onEditingChanged: ((Bool) -> Void)?
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isScrubbing = true
        onEditingChanged?(true)
        super.mouseDown(with: event)
        isScrubbing = false
        onEditingChanged?(false)
    }
}

@MainActor final class ProgressSliderCell: NSSliderCell {
    var readyRanges: [SeekRange] = []
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        super.drawBar(inside: rect, flipped: flipped)
        guard maxValue > minValue, rect.width > 0 else { return }
        let ranges = SeekRange.merged(readyRanges, within: SeekRange(start: minValue, end: maxValue))
        let track = NSRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: 4)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).addClip()
        NSColor.controlAccentColor.withAlphaComponent(isEnabled ? 0.45 : 0.3).setFill()
        for range in ranges {
            let start = (range.start - minValue) / (maxValue - minValue)
            let end = (range.end - minValue) / (maxValue - minValue)
            NSRect(x: track.minX + start * track.width, y: track.minY,
                   width: (end - start) * track.width, height: track.height).fill()
        }
    }
}
