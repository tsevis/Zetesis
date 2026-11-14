import XCTest

/// A topic made in the sidebar has no books yet, so the index knows nothing of it: the list must
/// carry it, once, and a second spelling of a name in use must not start a twin.
final class TopicListTests: XCTestCase {
    func testTopicWithoutBooksIsListedAfterTheOthers() {
        let entries = TopicList.entries(bookTopics: ["Art", "Maths", "Art"], declared: ["Illusion"])
        XCTAssertEqual(entries.map(\.name), ["Art", "Maths", "Illusion"])
        XCTAssertEqual(entries.map(\.count), [2, 1, 0])
    }

    func testDeclaredTopicThatHasBooksIsListedOnce() {
        let entries = TopicList.entries(bookTopics: ["Illusion"], declared: ["Illusion"])
        XCTAssertEqual(entries.map(\.name), ["Illusion"])
        XCTAssertEqual(entries.map(\.count), [1])
    }

    func testNameInUseIsFoundWhateverItsCaseAccentsOrSpaces() {
        XCTAssertEqual(TopicList.existing("  illusion ", in: ["Art", "Illusion"]), "Illusion")
        XCTAssertEqual(TopicList.existing("ψευδαισθηση", in: ["Ψευδαίσθηση"]), "Ψευδαίσθηση")
        XCTAssertNil(TopicList.existing("Illusions", in: ["Art", "Illusion"]))
    }

    func testNameIsTrimmedAndBlankIsRefused() {
        XCTAssertEqual(TopicList.cleaned("  Optical Illusion\n"), "Optical Illusion")
        XCTAssertNil(TopicList.cleaned("   "))
    }
}
