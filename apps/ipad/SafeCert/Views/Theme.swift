import SafeCertKit
import SwiftUI

/// 밝은 미니멀(Figma v3 원칙): 색은 판정에만, 글자 3단계(24/15/13), 회색 바탕 + 흰 카드.
enum Theme {
    static let background = Color(red: 0.955, green: 0.957, blue: 0.965)
    static let card = Color.white
    static let ink = Color(red: 0.09, green: 0.09, blue: 0.11)
    static let secondary = Color(red: 0.42, green: 0.43, blue: 0.47)
    static let hairline = Color(red: 0.88, green: 0.89, blue: 0.91)
    static let reserved = Color(red: 0.43, green: 0.34, blue: 0.81)

    static let titleFont = Font.system(size: 24, weight: .semibold)
    static let bodyFont = Font.system(size: 15)
    static let captionFont = Font.system(size: 13)

    static func color(_ c: VerdictColor) -> Color {
        switch c {
        case .red: Color(red: 0.90, green: 0.26, blue: 0.27)
        case .orange: Color(red: 0.96, green: 0.48, blue: 0.13)
        case .yellow: Color(red: 0.95, green: 0.74, blue: 0.10)
        case .green: Color(red: 0.19, green: 0.62, blue: 0.40)
        case .gray: Color(red: 0.58, green: 0.59, blue: 0.63)
        }
    }
}

struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline, lineWidth: 1))
    }
}

extension View {
    func card() -> some View { modifier(CardModifier()) }
}

/// 주 버튼(검정). 화면당 하나.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(isEnabled ? Theme.ink : Theme.ink.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct ColorDot: View {
    let color: VerdictColor
    var size: CGFloat = 10

    var body: some View {
        Circle().fill(Theme.color(color)).frame(width: size, height: size)
    }
}

struct Chip: View {
    let text: String
    var tint: Color = Theme.secondary

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.10), in: Capsule())
            .lineLimit(1)
            .fixedSize()
    }
}

/// 업로드 → 확인 → 판정 → 결과 4단계 표시.
struct StepperBar: View {
    let current: Int
    /// 좁은 화면(아이폰)은 현재 단계 이름만 보인다.
    @Environment(\.horizontalSizeClass) private var sizeClass

    private let steps = ["업로드", "확인", "판정", "결과"]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, title in
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(i <= current ? Theme.ink : Theme.hairline).frame(width: 20, height: 20)
                        if i < current {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        } else {
                            Text("\(i + 1)").font(.system(size: 11, weight: .semibold)).foregroundStyle(i <= current ? .white : Theme.secondary)
                        }
                    }
                    if sizeClass != .compact || i == current {
                        Text(title).font(Theme.captionFont).foregroundStyle(i <= current ? Theme.ink : Theme.secondary)
                            .fixedSize()
                    }
                }
                if i < steps.count - 1 {
                    Rectangle().fill(i < current ? Theme.ink : Theme.hairline).frame(width: sizeClass == .compact ? 14 : 28, height: 1)
                }
            }
        }
    }
}

/// 「감수 전 · 참고용」 고정 표기.
struct ReviewWatermark: View {
    var body: some View {
        Text("감수 전 · 참고용")
            .font(.system(size: 64, weight: .heavy))
            .foregroundStyle(Theme.ink.opacity(0.05))
            .rotationEffect(.degrees(-24))
            .allowsHitTesting(false)
    }
}
