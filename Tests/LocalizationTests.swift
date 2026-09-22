import XCTest
@testable import TMEjectGuardCore

/// Reads the real .lproj folders off disk and checks them against the keys the
/// source actually asks for.
///
/// Translations are the one part of the app where a mistake is invisible until
/// someone running that language sees it, which for Czech or German is likely
/// to be never. So this checks three things a human review would miss:
/// every key exists in every language, no language carries a key nothing uses,
/// and the format specifiers match - a "%@" translated as "%d" does not show
/// wrong text, it reads whatever is at that address.
final class LocalizationTests: XCTestCase {
    private static let languages = ["en", "sk", "cs", "de"]

    /// The repository, found from this file rather than from a bundle: these
    /// are source files, and SwiftPM does not copy them into the test bundle.
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // repo root

    // MARK: - Reading

    private func keysUsedInSource() throws -> Set<String> {
        let sources = Self.root.appendingPathComponent("Sources")
        var keys: Set<String> = []
        let pattern = try NSRegularExpression(pattern: #"Loc\.t\(\s*"([^"]+)""#)

        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                if let r = Range(match.range(at: 1), in: text) {
                    keys.insert(String(text[r]))
                }
            }
        }
        return keys
    }

    /// Both files for one language, merged the way the bundle merges them.
    private func strings(for language: String) throws -> [String: String] {
        let folder = Self.root
            .appendingPathComponent("Resources")
            .appendingPathComponent("\(language).lproj")

        let plain = folder.appendingPathComponent("Localizable.strings")
        guard let table = NSDictionary(contentsOf: plain) as? [String: String] else {
            XCTFail("\(language): Localizable.strings is missing or not a valid strings file")
            return [:]
        }

        var merged = table
        let plurals = folder.appendingPathComponent("Localizable.stringsdict")
        if let dict = NSDictionary(contentsOf: plurals) as? [String: Any] {
            for (key, value) in dict {
                // The plural forms themselves are checked separately; here only
                // the key has to exist.
                merged[key] = (value as? [String: Any])
                    .flatMap { $0["NSStringLocalizedFormatKey"] as? String } ?? ""
            }
        }
        return merged
    }

    private func pluralForms(for language: String) -> [String: [String: String]] {
        let url = Self.root
            .appendingPathComponent("Resources")
            .appendingPathComponent("\(language).lproj")
            .appendingPathComponent("Localizable.stringsdict")
        guard let dict = NSDictionary(contentsOf: url) as? [String: Any] else { return [:] }

        var result: [String: [String: String]] = [:]
        for (key, value) in dict {
            guard let entry = value as? [String: Any],
                  let variable = entry["count"] as? [String: Any] else { continue }
            result[key] = variable.compactMapValues { $0 as? String }
                .filter { !$0.key.hasPrefix("NSString") }
        }
        return result
    }

    /// "%1$@ in %2$d min" -> ["@", "d"], in the order the arguments are consumed.
    private func specifiers(in format: String) -> [String] {
        var found: [(position: Int, type: String)] = []
        var implicit = 0
        let pattern = try! NSRegularExpression(pattern: #"%(?:(\d+)\$)?([@dsf%])"#)
        let range = NSRange(format.startIndex..., in: format)
        for match in pattern.matches(in: format, range: range) {
            guard let typeRange = Range(match.range(at: 2), in: format) else { continue }
            let type = String(format[typeRange])
            if type == "%" { continue }   // an escaped percent sign consumes nothing
            let position: Int
            if let r = Range(match.range(at: 1), in: format), let n = Int(format[r]) {
                position = n
            } else {
                implicit += 1
                position = implicit
            }
            found.append((position, type))
        }
        return found.sorted { $0.position < $1.position }.map(\.type)
    }

    // MARK: - Tests

    func testEveryKeyTheSourceUsesIsTranslatedEverywhere() throws {
        let used = try keysUsedInSource()
        XCTAssertFalse(used.isEmpty, "found no Loc.t call sites - has the helper been renamed?")

        for language in Self.languages {
            let table = try strings(for: language)
            let missing = used.subtracting(table.keys).sorted()
            XCTAssertTrue(missing.isEmpty, "\(language) is missing: \(missing.joined(separator: ", "))")
        }
    }

    func testNoLanguageCarriesAKeyNothingUses() throws {
        let used = try keysUsedInSource()
        for language in Self.languages {
            let orphans = Set(try strings(for: language).keys).subtracting(used).sorted()
            XCTAssertTrue(orphans.isEmpty, "\(language) has unused keys: \(orphans.joined(separator: ", "))")
        }
    }

    func testNoTranslationIsEmpty() throws {
        for language in Self.languages {
            for (key, value) in try strings(for: language) where value.isEmpty {
                XCTFail("\(language): \(key) is empty")
            }
        }
    }

    /// The one that matters: `String(format:)` reads its arguments according to
    /// the format, so a translation claiming an argument that is not there
    /// reads past the end of the argument list.
    func testFormatSpecifiersMatchEnglish() throws {
        let english = try strings(for: "en")
        for language in Self.languages where language != "en" {
            let table = try strings(for: language)
            for (key, reference) in english {
                guard let translated = table[key] else { continue }
                XCTAssertEqual(
                    specifiers(in: translated), specifiers(in: reference),
                    "\(language): \(key) does not take the same arguments as English")
            }
        }
    }

    func testPluralFormsMatchEnglishArguments() throws {
        let english = pluralForms(for: "en")
        XCTAssertFalse(english.isEmpty, "no plural rules found in en.lproj")

        for language in Self.languages {
            let forms = pluralForms(for: language)
            XCTAssertEqual(Set(forms.keys), Set(english.keys),
                           "\(language) does not define the same plural keys")
            for (key, cases) in forms {
                XCTAssertNotNil(cases["other"], "\(language): \(key) has no 'other' form")
                guard let reference = english[key]?["other"] else { continue }
                for (name, text) in cases {
                    XCTAssertEqual(
                        specifiers(in: text), specifiers(in: reference),
                        "\(language): \(key)/\(name) does not take the same arguments as English")
                }
            }
        }
    }

    /// Slovak and Czech have a separate form for 2-4, which English and German
    /// do not. Getting this wrong reads as broken grammar to every native
    /// speaker, so it is asserted rather than left to review.
    func testSlavicLanguagesDefineTheFewForm() {
        for language in ["sk", "cs"] {
            for (key, cases) in pluralForms(for: language) {
                XCTAssertNotNil(cases["few"],
                                "\(language): \(key) has no 'few' form for 2-4")
            }
        }
    }
}
