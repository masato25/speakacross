import Foundation

public enum TraditionalChineseText {
    private static let hansToHant = StringTransform("Hans-Hant")

    public static func normalize(_ text: String) -> String {
        text.applyingTransform(hansToHant, reverse: false) ?? text
    }
}
