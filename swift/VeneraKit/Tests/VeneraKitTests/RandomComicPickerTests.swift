import XCTest
@testable import VeneraKit

final class RandomComicPickerTests: XCTestCase {
    func testDoesNotRepeatUntilCandidatesAreExcluded() {
        let first = FavoriteItem(id: "1", name: "First", coverPath: "", author: "", type: 1, tags: [])
        let second = FavoriteItem(id: "2", name: "Second", coverPath: "", author: "", type: 1, tags: [])
        let picker = UniformRandomComicPicker()

        let firstDraw = try! XCTUnwrap(picker.pick([first, second]))
        let secondDraw = try! XCTUnwrap(picker.pick([first, second], excluding: [firstDraw.comicID]))

        XCTAssertNotEqual(firstDraw.comicID, secondDraw.comicID)
        XCTAssertNil(picker.pick([first, second], excluding: [first.comicID, second.comicID]))
    }

    func testSameIdFromDifferentTypesIsDistinct() {
        let local = FavoriteItem(id: "same", name: "Local", coverPath: "", author: "", type: 1, tags: [])
        let network = FavoriteItem(id: "same", name: "Network", coverPath: "", author: "", type: 2, tags: [])
        let picker = UniformRandomComicPicker()

        let result = picker.pick([local, network], excluding: [local.comicID])

        XCTAssertEqual(result?.comicID, network.comicID)
    }
}
