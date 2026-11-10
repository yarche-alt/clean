import Photos
import UIKit

/// Вердикт классификатора для одного скриншота
enum ShotVerdict {
    case junk   // карточка товара с маркетплейса
    case keep   // переписка, документ, заметка и т.п.
}

/// Одна найденная фотография-скриншот
struct ScreenshotItem: Identifiable, Equatable {
    let id: String          // localIdentifier ассета
    let asset: PHAsset
    var thumbnail: UIImage?
    var verdict: ShotVerdict = .keep
    var matched: [String] = []   // какие маркеры сработали
    var fileBytes: Int = 0

    static func == (lhs: ScreenshotItem, rhs: ScreenshotItem) -> Bool {
        lhs.id == rhs.id
    }
}

enum AppScreen {
    case welcome
    case scanning
    case results
    case review
    case success
}

extension Int {
    /// Человекочитаемый размер: «21,6 МБ»
    var humanSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNumericUnits = true
        return formatter.string(fromByteCount: Int64(self))
    }
}
