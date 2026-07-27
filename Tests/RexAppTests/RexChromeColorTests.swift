import SwiftUI
import Testing
@testable import RexApp

@Test("Light chrome borders preserve visible hierarchy")
func lightChromeBorderHierarchy() {
    let subtle = RexChromeColor.strokeOpacity(.light, level: .subtle)
    let standard = RexChromeColor.strokeOpacity(.light, level: .standard)
    let emphasized = RexChromeColor.strokeOpacity(.light, level: .emphasized)
    let panel = RexChromeColor.strokeOpacity(.light, level: .panel)

    #expect(subtle == 0.11)
    #expect(standard == 0.16)
    #expect(panel == 0.18)
    #expect(emphasized == 0.24)
    #expect(subtle < standard)
    #expect(standard < panel)
    #expect(panel < emphasized)
}

@Test("Dark chrome border strengths remain restrained")
func darkChromeBorderHierarchy() {
    #expect(RexChromeColor.strokeOpacity(.dark, level: .subtle) == 0.08)
    #expect(RexChromeColor.strokeOpacity(.dark, level: .standard) == 0.1)
    #expect(RexChromeColor.strokeOpacity(.dark, level: .panel) == 0.2)
    #expect(RexChromeColor.strokeOpacity(.dark, level: .emphasized) == 0.26)
}

@Test("Increased contrast overrides chrome border strength")
func increasedContrastChromeBorders() {
    for scheme in [ColorScheme.light, .dark] {
        for level in [
            RexChromeStrokeLevel.subtle,
            .standard,
            .emphasized,
            .panel
        ] {
            #expect(RexChromeColor.strokeOpacity(
                scheme,
                level: level,
                increasedContrast: true
            ) == 0.55)
        }
    }
}
