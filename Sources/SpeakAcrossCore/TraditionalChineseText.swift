import Foundation

public enum TraditionalChineseText {
    private static let hansToHant = StringTransform("Hans-Hant")

    public static func normalize(_ text: String) -> String {
        text.applyingTransform(hansToHant, reverse: false) ?? text
    }

    public static func isTraditionalScript(_ text: String) -> Bool {
        normalize(text) == text
    }
}

public enum SimplifiedChineseText {
    private static let hantToHans = StringTransform("Hant-Hans")

    public static func normalize(_ text: String) -> String {
        text.applyingTransform(hantToHans, reverse: false) ?? text
    }
}
