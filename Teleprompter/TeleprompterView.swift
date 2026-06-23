import SwiftUI

/// Plynule scrollující text přes náhled kamery. Rychlost v bodech za sekundu.
struct TeleprompterView: View {
    let text: String
    let fontSize: CGFloat
    let speed: Double
    let isRunning: Bool
    let mirror: Bool
    var voiceProgress: Double? = nil   // nil = posun rychlostí; jinak posun podle čtení (0…1)

    @State private var offset: CGFloat = 0
    @State private var textHeight: CGFloat = 0
    @State private var containerHeight: CGFloat = 0
    @State private var isDragging = false
    @State private var dragStartOffset: CGFloat = 0

    private let tick = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            Text(text.isEmpty ? "Tap the pencil and write your script here…" : text)
                .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.9), radius: 4, x: 0, y: 1)
                .multilineTextAlignment(.center)
                .lineSpacing(fontSize * 0.3)
                .padding(.horizontal, 20)
                .frame(width: geo.size.width)
                .fixedSize(horizontal: false, vertical: true)   // text v plné výšce, ne oříznutý na okénko
                .background(
                    GeometryReader { tg in
                        Color.clear
                            .onAppear { textHeight = tg.size.height }
                            .onChange(of: tg.size.height) { _, h in textHeight = h }
                    }
                )
                .scaleEffect(x: mirror ? -1 : 1, y: 1)
                .offset(y: offset)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                .clipped()
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !isDragging {          // chytnutí: zapamatuj pozici a pozastav
                                isDragging = true
                                dragStartOffset = offset
                            }
                            offset = dragStartOffset + value.translation.height
                        }
                        .onEnded { _ in
                            isDragging = false        // puštění: pokračuj odsud dál
                        }
                )
                .onAppear {
                    containerHeight = geo.size.height
                    offset = geo.size.height * 0.5
                }
                .onChange(of: geo.size.height) { _, h in containerHeight = h }
                .onReceive(tick) { _ in
                    guard isRunning, !isDragging else { return }   // při tažení stojí
                    if let p = voiceProgress {
                        // Posun podle čtení: cíl = matchnuté slovo na čtecí lince.
                        let readingLineY = containerHeight * 0.35
                        let target = readingLineY - CGFloat(p) * textHeight
                        offset += (target - offset) * 0.12   // plynulé dojetí, ne skok
                    } else {
                        offset -= CGFloat(speed) / 60.0
                        if textHeight > 0, offset < -textHeight {
                            offset = containerHeight   // dojede dolů → vrať nahoru (smyčka)
                        }
                    }
                }
        }
    }
}
