import Photos
import SwiftUI

extension Color {
    init(_ hex: UInt, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

private let brandBlue = Color(0x005BFF)
private let brandPink = Color(0xCB11AB)
private let brandAmber = Color(0xFFCC00)
private let iosRed = Color(0xFF453A)
private let iosGreen = Color(0x30D158)

struct RootView: View {
    @EnvironmentObject var library: PhotoLibrary

    @State private var screen: AppScreen = .welcome
    @State private var selectedIDs: Set<String> = []
    @State private var history: [(id: String, wasSelected: Bool)] = []
    @State private var scanProgress = 0
    @State private var showAccessAlert = false
    @State private var askDelete = false
    @State private var deleting = false
    @State private var freedBytes = 0
    @State private var deletedCount = 0

    private var junkItems: [ScreenshotItem] { library.items.filter { $0.verdict == .junk } }
    private var keepItems: [ScreenshotItem] { library.items.filter { $0.verdict == .keep } }
    private var selectedItems: [ScreenshotItem] { junkItems.filter { selectedIDs.contains($0.id) } }
    private var selectedBytes: Int { selectedItems.reduce(0) { $0 + $1.fileBytes } }

    var body: some View {
        ZStack {
            backgroundView

            switch screen {
            case .welcome:
                WelcomeView(hasCleaned: deletedCount > 0) { startFlow() }
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))

            case .scanning:
                ScanningView(progress: scanProgress, total: library.items.count, items: library.items)
                    .transition(.opacity)

            case .results:
                ResultsView(
                    junk: junkItems,
                    keep: keepItems,
                    selectedIDs: selectedIDs,
                    onToggle: toggleSelection,
                    onReview: { screen = .review },
                    onDelete: { askDelete = true }
                )
                .transition(.opacity.combined(with: .move(edge: .trailing)))

            case .review:
                ReviewView(
                    junk: junkItems,
                    selectedIDs: selectedIDs,
                    onDecision: handleDecision,
                    onUndo: undoDecision,
                    canUndo: !history.isEmpty,
                    onFinish: { screen = .results }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))

            case .success:
                SuccessView(count: deletedCount, bytes: freedBytes, kept: keepItems.count) {
                    deletedCount = 0
                    screen = .welcome
                }
                .transition(.opacity.combined(with: .scale(scale: 1.04)))
            }

            if deleting {
                DeletingOverlay(count: selectedItems.count, bytes: selectedBytes)
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: screen)
        .alert("Нет доступа к фото", isPresented: $showAccessAlert) {
            Button("Открыть Настройки") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Разрешите полный доступ к Фото, чтобы приложение могло найти и почистить скриншоты.")
        }
        .confirmationDialog(
            "Удалить \(selectedItems.count) скриншотов?",
            isPresented: $askDelete,
            titleVisibility: .visible
        ) {
            Button("Удалить · освободить \(selectedBytes.humanSize)", role: .destructive) {
                performDelete()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Карточки товаров уйдут в «Недавно удалённые» (там они хранятся 30 дней). Переписки и документы останутся нетронутыми.")
        }
    }

    private var backgroundView: some View {
        ZStack {
            Color(0x050508).ignoresSafeArea()
            Circle().fill(brandBlue.opacity(0.22)).frame(width: 420).blur(radius: 120)
                .offset(x: -160, y: -260)
            Circle().fill(brandPink.opacity(0.2)).frame(width: 380).blur(radius: 120)
                .offset(x: 170, y: -40)
            Circle().fill(brandAmber.opacity(0.12)).frame(width: 360).blur(radius: 120)
                .offset(x: -40, y: 320)
        }
        .ignoresSafeArea()
    }

    private func startFlow() {
        Task {
            let granted = await library.requestAccess()
            guard granted else {
                showAccessAlert = true
                return
            }
            scanProgress = 0
            screen = .scanning
            await runScan()
        }
    }

    @MainActor
    private func runScan() async {
        library.fetchScreenshots()
        let all = library.items
        for (index, item) in all.enumerated() {
            let image = await library.loadImage(for: item.asset, targetSize: CGSize(width: 1000, height: 2000))
            var verdict: ShotVerdict = .keep
            var hits: [String] = []
            if let image {
                let result = await Task.detached(priority: .userInitiated) {
                    Classifier.verdict(for: image)
                }.value
                verdict = result.0
                hits = result.1
            }
            library.applyResult(id: item.id, thumbnail: image, verdict: verdict, matched: hits)
            scanProgress = index + 1
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        selectedIDs = Set(junkItems.map { $0.id })
        history = []
        try? await Task.sleep(nanoseconds: 600_000_000)
        screen = .results
    }

    private func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    private func handleDecision(_ id: String, trash: Bool) {
        history.append((id, selectedIDs.contains(id)))
        if trash { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
    }

    private func undoDecision() {
        guard let last = history.popLast() else { return }
        if last.wasSelected { selectedIDs.insert(last.id) } else { selectedIDs.remove(last.id) }
    }

    private func performDelete() {
        let victims = selectedItems
        let bytes = selectedBytes
        let ids = Set(victims.map { $0.id })
        deleting = true
        Task {
            do {
                try await library.delete(itemsToDelete: victims)
                library.removeItems(withIDs: ids)
                freedBytes = bytes
                deletedCount = victims.count
                deleting = false
                screen = .success
            } catch {
                deleting = false
            }
        }
    }
}

private struct WelcomeView: View {
    let hasCleaned: Bool
    let onScan: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [brandBlue, Color(0x7A4DFF), brandPink],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 108, height: 108)
                    .shadow(color: Color(0x7A4DFF).opacity(0.5), radius: 40)
                Image(systemName: "wand.and.stars.inverse")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text("Чистка")
                .font(.system(size: 40, weight: .black))
                .padding(.top, 26)
            Text("Выметает из галереи скриншоты карточек товаров с Ozon, Wildberries и Яндекс Маркета — и бережно оставляет переписки и документы")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
                .padding(.top, 10)

            VStack(spacing: 10) {
                featureRow(icon: "viewfinder", tint: brandBlue, title: "Находит мусор сама", sub: "OCR-анализ каждого скриншота на устройстве")
                featureRow(icon: "checkmark.shield.fill", tint: iosGreen, title: "Важное не трогает", sub: "Переписки, чеки, билеты и заметки в безопасности")
                featureRow(icon: "bolt.fill", tint: brandAmber, title: "Удаление в один тап", sub: "Файлы попадают в «Недавно удалённые» на 30 дней")
            }
            .padding(.top, 32)
            .padding(.horizontal, 24)

            Spacer()

            if hasCleaned {
                Label("Галерея почищена: лишних скриншотов не найдено", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(iosGreen)
                    .padding(.bottom, 12)
            }

            Button(action: onScan) {
                Label("Сканировать скриншоты", systemImage: "sparkle.magnifyingglass")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(LinearGradient(colors: [brandBlue, Color(0x7A4DFF), brandPink], startPoint: .leading, endPoint: .trailing))
                    .clipShape(Capsule())
                    .foregroundStyle(.white)
                    .shadow(color: Color(0x7A4DFF).opacity(0.45), radius: 24, y: 10)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 34)
        }
    }

    private func featureRow(icon: String, tint: Color, title: String, sub: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(tint.gradient)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.bold))
                Text(sub).font(.caption).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
        }
        .padding(10)
        .background(.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1))
    }
}

private struct ScanningView: View {
    let progress: Int
    let total: Int
    let items: [ScreenshotItem]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    // ИСПРАВЛЕНИЕ: Выносим всю математику в отдельные переменные, чтобы Swift не падал
    private var percentage: Int {
        guard total > 0 else { return 0 }
        return Int((Double(progress) / Double(total)) * 100)
    }

    private var progressFraction: Double {
        guard total > 0 else { return 0 }
        return Double(progress) / Double(total)
    }

    var body: some View {
        VStack(spacing: 14) {
            Text("АНАЛИЗ ГАЛЕРЕИ")
                .font(.caption.weight(.bold))
                .tracking(3)
                .foregroundStyle(.white.opacity(0.4))
                .padding(.top, 18)

            Text(total == 0 ? "Скриншотов не найдено" : (progress >= total ? "Анализ завершён" : "Сканирую скриншоты"))
                .font(.title2.weight(.black))

            // ИСПРАВЛЕНИЕ: Упрощённая строка без сложных вычислений
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(percentage)")
                    .font(.system(size: 58, weight: .black, design: .rounded))
                    .monospacedDigit()
                Text("%")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white.opacity(0.4))
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(colors: [brandBlue, Color(0x7A4DFF), brandPink], startPoint: .leading, endPoint: .trailing))
                        // ИСПРАВЛЕНИЕ: Используем готовую переменную progressFraction
                        .frame(width: geo.size.width * progressFraction)
                        .animation(.spring(response: 0.4), value: progress)
                }
            }
            .frame(height: 8)
            .padding(.horizontal, 40)

            Text("Vision OCR распознаёт текст локально, фото никуда не отправляются")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.45))

            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(items) { item in
                        TileView(item: item)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }
        }
    }
}

private struct TileView: View {
    let item: ScreenshotItem

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image = item.thumbnail {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.white.opacity(0.07))
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 130, maxHeight: 130)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(borderColor, lineWidth: item.thumbnail == nil ? 0 : 2))
            .opacity(item.thumbnail == nil ? 0.5 : 1)

            if item.thumbnail != nil {
                Image(systemName: item.verdict == .junk ? "trash.fill" : "checkmark")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(item.verdict == .junk ? iosRed : iosGreen)
                    .clipShape(Circle())
                    .offset(x: 4, y: -4)
            }
        }
        .animation(.spring(response: 0.35), value: item.thumbnail != nil)
    }

    private var borderColor: Color {
        item.verdict == .junk ? iosRed.opacity(0.7) : iosGreen.opacity(0.6)
    }
}

private struct ResultsView: View {
    let junk: [ScreenshotItem]
    let keep: [ScreenshotItem]
    let selectedIDs: Set<String>
    let onToggle: (String) -> Void
    let onReview: () -> Void
    let onDelete: () -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    private var selectedBytes: Int {
        junk.filter { selectedIDs.contains($0.id) }.reduce(0) { $0 + $1.fileBytes }
    }

    // ИСПРАВЛЕНИЕ: Выносим текст кнопки в переменную
    private var deleteButtonLabel: String {
        selectedIDs.isEmpty ? "Ничего не выбрано" : "Удалить \(selectedIDs.count) · \(selectedBytes.humanSize)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerSection
                summaryCard
                junkSection
                keepSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
        }
        .overlay(alignment: .bottom) {
            bottomActionBar
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Результат анализа")
                .font(.title2.weight(.black))
            Text("Проверено скриншотов: \(junk.count + keep.count)")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("МОЖНО ОСВОБОДИТЬ")
                .font(.caption2.weight(.bold))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.45))
            Text(selectedBytes.humanSize)
                .font(.system(size: 44, weight: .black, design: .rounded))
                .monospacedDigit()
            HStack(spacing: 6) {
                statPill(text: "Мусор: \(junk.count)", color: iosRed)
                statPill(text: "Важное: \(keep.count)", color: iosGreen)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.1), lineWidth: 1))
        .padding(.top, 14)
    }

    private var junkSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(title: "На удаление", sub: "Нажмите на карточку, чтобы оставить её", badge: "\(selectedIDs.count) из \(junk.count)", tint: iosRed)
            
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(junk) { item in
                    JunkCell(item: item, isSelected: selectedIDs.contains(item.id)) {
                        onToggle(item.id)
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    private var keepSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(title: "Оставим — это важное", sub: "Переписки, документы и заметки", badge: "\(keep.count) шт", tint: iosGreen)
            
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(keep) { item in
                    KeepCell(item: item)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 120)
        }
    }

    private var bottomActionBar: some View {
        HStack(spacing: 10) {
            Button(action: onReview) {
                Label("Проверить", systemImage: "square.stack.3d.up.fill")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(.white.opacity(0.08))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.12)))
            }
            .foregroundStyle(.white)

            Button(action: onDelete) {
                // ИСПРАВЛЕНИЕ: Используем простую переменную deleteButtonLabel
                Label(deleteButtonLabel, systemImage: "trash.fill")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(deleteButtonBackground)
                    .clipShape(Capsule())
                    .shadow(color: selectedIDs.isEmpty ? .clear : iosRed.opacity(0.4), radius: 18, y: 8)
            }
            .foregroundStyle(selectedIDs.isEmpty ? .white.opacity(0.35) : .white)
            .disabled(selectedIDs.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 22)
        .padding(.top, 30)
        .background(
            LinearGradient(colors: [Color(0x050508).opacity(0), Color(0x050508)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
    }

    private var deleteButtonBackground: AnyShapeStyle {
        if selectedIDs.isEmpty {
            return AnyShapeStyle(.white.opacity(0.08))
        } else {
            return AnyShapeStyle(LinearGradient(colors: [iosRed, Color(0xFF6B3D)], startPoint: .leading, endPoint: .trailing))
        }
    }

    private func statPill(text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.white.opacity(0.06))
        .clipShape(Capsule())
    }

    private func sectionHeader(title: String, sub: String, badge: String, tint: Color) -> some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline.weight(.black))
                Text(sub).font(.caption).foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            Text(badge)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(tint.opacity(0.15))
                .clipShape(Capsule())
        }
        .padding(.top, 26)
    }
}

private struct JunkCell: View {
    let item: ScreenshotItem
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    thumb
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(isSelected ? iosRed : Color.white.opacity(0.1), lineWidth: isSelected ? 2.5 : 1))
                        .opacity(isSelected ? 1 : 0.5)
                        .saturation(isSelected ? 1 : 0.3)

                    Image(systemName: isSelected ? "checkmark" : "plus")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(isSelected ? iosRed : Color.black.opacity(0.45))
                        .clipShape(Circle())
                        .overlay(Circle().stroke(.white.opacity(0.25)))
                        .offset(x: 4, y: -4)
                }
                if !item.matched.isEmpty {
                    Text(item.matched.prefix(2).joined(separator: " · "))
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var thumb: some View {
        Group {
            if let image = item.thumbnail {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.white.opacity(0.07))
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 165, maxHeight: 165)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct KeepCell: View {
    let item: ScreenshotItem

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image = item.thumbnail {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.white.opacity(0.07))
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 165, maxHeight: 165)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(iosGreen.opacity(0.25), lineWidth: 1))

            Image(systemName: "lock.fill")
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(.white)
                .padding(5)
                .background(iosGreen)
                .clipShape(Circle())
                .offset(x: 4, y: -4)
        }
    }
}

private struct ReviewView: View {
    let junk: [ScreenshotItem]
    let selectedIDs: Set<String>
    let onDecision: (String, Bool) -> Void
    let onUndo: () -> Void
    let canUndo: Bool
    let onFinish: () -> Void

    @State private var index = 0
    @State private var offset: CGFloat = 0

    private var current: ScreenshotItem? { index < junk.count ? junk[index] : nil }
    
    // ИСПРАВЛЕНИЕ: Выносим математику анимаций в переменные
    private var rotationAngle: Double { Double(offset) / 18 }
    private var leftStampOpacity: Double { Double(min(1, offset / 90)) }
    private var rightStampOpacity: Double { Double(min(1, -offset / 90)) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            hintText
            Spacer()
            mainContent
            Spacer()
            bottomButtons
        }
    }

    private var topBar: some View {
        HStack {
            Button(action: onFinish) {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .foregroundStyle(.white)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Ручная проверка").font(.headline.weight(.black))
                Text(current == nil ? "Все карточки просмотрены" : "Карточка \(index + 1) из \(junk.count)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            Text("К удалению: \(selectedIDs.count)")
                .font(.caption.weight(.bold))
                .foregroundStyle(iosRed)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.white.opacity(0.06))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private var hintText: some View {
        Text("влево — удалить · вправо — оставить")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.4))
            .padding(.top, 8)
    }

    @ViewBuilder
    private var mainContent: some View {
        if let item = current {
            ZStack {
                if index + 1 < junk.count {
                    card(item: junk[index + 1])
                        .scaleEffect(0.93)
                        .opacity(0.5)
                        .offset(y: 12)
                }
                interactiveCard(item: item)
            }
        } else {
            emptyState
        }
    }

    private func interactiveCard(item: ScreenshotItem) -> some View {
        card(item: item)
            .offset(x: offset)
            .rotationEffect(.degrees(rotationAngle)) // ИСПРАВЛЕНИЕ: используем переменную
            .overlay(swipeStamps)
            .gesture(dragGesture)
            .transition(.opacity)
    }

    private var swipeStamps: some View {
        ZStack {
            stamp(text: "УДАЛЮ", color: iosRed)
                .opacity(rightStampOpacity) // ИСПРАВЛЕНИЕ: используем переменную
                .rotationEffect(.degrees(-12))
                .offset(y: -170)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 16)
            
            stamp(text: "ОСТАВЛЮ", color: iosGreen)
                .opacity(leftStampOpacity) // ИСПРАВЛЕНИЕ: используем переменную
                .rotationEffect(.degrees(12))
                .offset(y: -170)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 16)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { offset = $0.translation.width }
            .onEnded { value in
                if value.translation.width < -100 {
                    dismiss(to: -1)
                } else if value.translation.width > 100 {
                    dismiss(to: 1)
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                        offset = 0
                    }
                }
            }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(iosGreen)
            Text("Проверка завершена")
                .font(.title3.weight(.black))
            Button("Вернуться к результатам", action: onFinish)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(LinearGradient(colors: [brandBlue, Color(0x7A4DFF)], startPoint: .leading, endPoint: .trailing))
                .clipShape(Capsule())
                .foregroundStyle(.white)
                .padding(.horizontal, 40)
        }
    }

    @ViewBuilder
    private var bottomButtons: some View {
        if current != nil {
            HStack(spacing: 26) {
                Button { dismiss(to: -1) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 24, weight: .bold))
                        .frame(width: 64, height: 64)
                        .background(iosRed.opacity(0.15))
                        .clipShape(Circle())
                        .overlay(Circle().stroke(iosRed.opacity(0.4)))
                        .foregroundStyle(iosRed)
                }
                Button(action: {
                    guard index > 0, canUndo else { return }
                    index -= 1
                    offset = 0
                    onUndo()
                }) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 17, weight: .bold))
                        .frame(width: 48, height: 48)
                        .background(.white.opacity(0.08))
                        .clipShape(Circle())
                        .foregroundStyle(canUndo && index > 0 ? .white : .white.opacity(0.3))
                }
                .disabled(!(canUndo && index > 0))
                
                Button { dismiss(to: 1) } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 24, weight: .bold))
                        .frame(width: 64, height: 64)
                        .background(iosGreen.opacity(0.15))
                        .clipShape(Circle())
                        .overlay(Circle().stroke(iosGreen.opacity(0.4)))
                        .foregroundStyle(iosGreen)
                }
            }
            .padding(.bottom, 38)
        }
    }

    private func dismiss(to direction: CGFloat) {
        guard let item = current else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            offset = direction * 500
        }
        onDecision(item.id, direction < 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            offset = 0
            index += 1
        }
    }

    private func card(item: ScreenshotItem) -> some View {
        VStack(spacing: 10) {
            Group {
                if let image = item.thumbnail {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Rectangle().fill(.white.opacity(0.07))
                }
            }
            .frame(maxWidth: 250, maxHeight: 420)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.15)))
            .shadow(color: .black.opacity(0.6), radius: 30, y: 16)

            if !item.matched.isEmpty {
                Text("Нашёл: " + item.matched.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
        }
    }

    private func stamp(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .black))
            .tracking(3)
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(color, lineWidth: 3))
            .background(color.opacity(0.12).clipShape(RoundedRectangle(cornerRadius: 8)))
    }
}

private struct SuccessView: View {
    let count: Int
    let bytes: Int
    let kept: Int
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                Circle().fill(iosGreen.opacity(0.18)).frame(width: 130, height: 130).blur(radius: 30)
                Circle()
                    .fill(iosGreen.opacity(0.15))
                    .frame(width: 104, height: 104)
                    .overlay(Circle().stroke(iosGreen.opacity(0.4), lineWidth: 1))
                Image(systemName: "checkmark")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(iosGreen)
            }
            Text("Галерея почищена")
                .font(.system(size: 30, weight: .black))
                .padding(.top, 24)

            Text("ОСВОБОЖДЕНО")
                .font(.caption2.weight(.bold))
                .tracking(3)
                .foregroundStyle(.white.opacity(0.45))
                .padding(.top, 26)
            Text(bytes.humanSize)
                .font(.system(size: 56, weight: .black, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(LinearGradient(colors: [brandAmber, brandPink], startPoint: .leading, endPoint: .trailing))

            HStack(spacing: 10) {
                stat(value: "\(count)", label: "Удалено", tint: iosRed, icon: "trash.fill")
                stat(value: bytes.humanSize, label: "Места", tint: brandAmber, icon: "internaldrive.fill")
                stat(value: "\(kept)", label: "Важное цело", tint: iosGreen, icon: "checkmark.shield.fill")
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)

            Label("Удалённые файлы ещё 30 дней лежат в «Недавно удалённых» — их легко вернуть", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.top, 18)

            Spacer()

            Button("Готово", action: onDone)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(iosGreen.gradient)
                .clipShape(Capsule())
                .foregroundStyle(.black.opacity(0.85))
                .padding(.horizontal, 24)
                .padding(.bottom, 34)
        }
    }

    private func stat(value: String, label: String, tint: Color, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.subheadline).foregroundStyle(tint)
            Text(value).font(.headline.weight(.black)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.08)))
    }
}

private struct DeletingOverlay: View {
    let count: Int
    let bytes: Int
    @State private var spinning = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.8).ignoresSafeArea()
            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .trim(from: 0, to: 0.7)
                        .stroke(iosRed, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .frame(width: 92, height: 92)
                        .rotationEffect(.degrees(spinning ? 360 : 0))
                        .onAppear {
                            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                                spinning = true
                            }
                        }
                    Image(systemName: "trash.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(iosRed)
                }
                Text("Удаляю \(count) скриншотов…")
                    .font(.headline.weight(.black))
                Text("Отправляю в «Недавно удалённые» · \(bytes.humanSize)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}
