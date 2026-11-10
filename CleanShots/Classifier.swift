import Vision
import UIKit

/// Локальный классификатор скриншотов.
/// Прогоняет картинку через Vision OCR (русский + английский) и ищет
/// характерные для маркетплейсов фразы: кнопки покупки, цены, скидки,
/// названия площадок. Если набирается порог — это карточка товара.
/// Переписки, документы и заметки такие слова почти не содержат,
/// поэтому попадают в «важное».
enum Classifier {

    /// Фраза → её «вес». Нулевой вес — совпадение запоминаем, но в счёт не берём.
    static let junkTerms: [(phrase: String, weight: Int)] = [
        // Сами площадки — самый сильный сигнал
        ("ozon", 4), ("озон", 4), ("доставка ozon", 4),
        ("wildberries", 4), ("вайлдберриз", 4),
        ("яндекс маркет", 4), ("маркет", 2),
        // Элементы карточки товара
        ("в корзину", 3), ("добавить в корзину", 3), ("купить в 1 клик", 3),
        ("купить", 1), ("корзина", 1), ("о товаре", 2), ("характеристики", 1),
        ("пункт выдачи", 2), ("в избранное", 1), ("отзывы", 1),
        ("рейтинг", 1), ("оценки", 1), ("продавец", 2), ("оригинал", 1),
        ("осталось", 1), ("скидка", 1), ("акция", 1), ("только сегодня", 2),
        ("доставка", 0), ("завтра", 0), ("бесплатно", 0),
        // Цены
        ("₽", 1), ("руб", 1), ("%", 0)
    ]

    /// Сколько «веса» нужно набрать, чтобы признать скриншот мусором
    static let junkThreshold = 3

    /// Возвращает вердикт и список сработавших фраз (для подписи в интерфейсе).
    /// Синхронная — вызывать НЕ с главного потока (например, через Task.detached).
    static func verdict(for image: UIImage) -> (ShotVerdict, [String]) {
        guard let cgImage = image.cgImage else { return (.keep, []) }

        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["ru-RU", "en-US"]
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Карточки товаров плотные по тексту — смотрим всё
        request.minimumTextHeight = 0.015

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])

        let text = ((request.results) ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
            .lowercased()

        var score = 0
        var hits: [String] = []
        for term in junkTerms where text.contains(term.phrase) {
            score += term.weight
            if term.weight > 0 { hits.append(term.phrase) }
        }

        // Несколько ценных характеров «₽» — почти наверняка витрина
        let priceSymbols = text.filter { $0 == "₽" }.count
        if priceSymbols >= 2 { score += 2 } else if priceSymbols == 1 { score += 1 }

        let verdict: ShotVerdict = score >= junkThreshold ? .junk : .keep
        return (verdict, Array(hits.prefix(4)))
    }
}
