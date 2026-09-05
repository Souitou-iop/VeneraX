import XCTest
@testable import VeneraKit

/// 阅读器布局规划纯函数回归：画廊每屏页数（横/竖屏 PicNumber + 双页保底）、
/// 分组切分（含首页单图与余数组）、连续模式页间距钳制。
final class ReaderLayoutTests: XCTestCase {
    // MARK: - galleryPagesPerScreen

    func testPagesPerScreenDefaultsToSingle() {
        XCTAssertEqual(
            ReaderModel.galleryPagesPerScreen(twoPageMode: false, landscapeCount: 1, portraitCount: 1, isLandscape: false),
            1
        )
        XCTAssertEqual(
            ReaderModel.galleryPagesPerScreen(twoPageMode: false, landscapeCount: 1, portraitCount: 1, isLandscape: true),
            1
        )
    }

    func testPagesPerScreenTwoPageModeFloorIsTwo() {
        XCTAssertEqual(
            ReaderModel.galleryPagesPerScreen(twoPageMode: true, landscapeCount: 1, portraitCount: 1, isLandscape: false),
            2,
            "双页模式开启时即使 PicNumber 为 1 也至少每屏 2 页"
        )
    }

    func testPagesPerScreenFollowsOrientation() {
        XCTAssertEqual(
            ReaderModel.galleryPagesPerScreen(twoPageMode: false, landscapeCount: 5, portraitCount: 1, isLandscape: true),
            5
        )
        XCTAssertEqual(
            ReaderModel.galleryPagesPerScreen(twoPageMode: false, landscapeCount: 5, portraitCount: 1, isLandscape: false),
            1,
            "竖屏使用竖屏档位"
        )
    }

    func testPagesPerScreenClampsConfiguredValues() {
        XCTAssertEqual(
            ReaderModel.galleryPagesPerScreen(twoPageMode: false, landscapeCount: 9, portraitCount: 1, isLandscape: true),
            5,
            "超过设置上限 5 时钳制"
        )
        XCTAssertEqual(
            ReaderModel.galleryPagesPerScreen(twoPageMode: false, landscapeCount: 0, portraitCount: 1, isLandscape: true),
            1,
            "非法 0 值回退 1"
        )
        XCTAssertEqual(
            ReaderModel.galleryPagesPerScreen(twoPageMode: true, landscapeCount: 9, portraitCount: 1, isLandscape: true),
            5
        )
    }

    // MARK: - gallerySpreads（N 图/屏切分）

    func testSpreadsGroupByN() {
        let spreads = ReaderModel.gallerySpreads(pageCount: 8, pagesPerSpread: 3)
        XCTAssertEqual(spreads.map(\.pageIndices), [[0, 1, 2], [3, 4, 5], [6, 7]], "余数单独成组")
    }

    func testSpreadsExactMultipleOfN() {
        let spreads = ReaderModel.gallerySpreads(pageCount: 6, pagesPerSpread: 3)
        XCTAssertEqual(spreads.map(\.pageIndices), [[0, 1, 2], [3, 4, 5]])
    }

    func testSpreadsSingleFirstPage() {
        let spreads = ReaderModel.gallerySpreads(
            pageCount: 7, pagesPerSpread: 3, showSingleImageOnFirstPage: true
        )
        XCTAssertEqual(spreads.map(\.pageIndices), [[0], [1, 2, 3], [4, 5, 6]], "封面单独一组，其余按 N 切分")
    }

    func testSpreadsFewerPagesThanN() {
        XCTAssertEqual(
            ReaderModel.gallerySpreads(pageCount: 2, pagesPerSpread: 5).map(\.pageIndices),
            [[0, 1]]
        )
        XCTAssertTrue(ReaderModel.gallerySpreads(pageCount: 0, pagesPerSpread: 3).isEmpty)
    }

    func testSpreadIndexForN() {
        XCTAssertEqual(
            ReaderModel.gallerySpreadIndex(forImageIndex: 4, pageCount: 8, pagesPerSpread: 3),
            1,
            "第 5 页落在第二组"
        )
        XCTAssertEqual(
            ReaderModel.gallerySpreadIndex(forImageIndex: 7, pageCount: 8, pagesPerSpread: 3),
            2
        )
        XCTAssertEqual(
            ReaderModel.gallerySpreadIndex(forImageIndex: 0, pageCount: 7, pagesPerSpread: 3, showSingleImageOnFirstPage: true),
            0
        )
        XCTAssertEqual(
            ReaderModel.gallerySpreadIndex(forImageIndex: 1, pageCount: 7, pagesPerSpread: 3, showSingleImageOnFirstPage: true),
            1,
            "封面单图后第 2 页进入第一组 N 图"
        )
    }

    // MARK: - continuousPageSpacing

    func testContinuousPageSpacingClamp() {
        XCTAssertEqual(ReaderModel.continuousPageSpacing(nil), 0)
        XCTAssertEqual(ReaderModel.continuousPageSpacing(0), 0)
        XCTAssertEqual(ReaderModel.continuousPageSpacing(12), 12)
        XCTAssertEqual(ReaderModel.continuousPageSpacing(-5), 0, "负值钳制到 0")
        XCTAssertEqual(ReaderModel.continuousPageSpacing(99), 50, "超出档位上限钳制到 50")
        XCTAssertEqual(ReaderModel.continuousPageSpacing(.nan), 0, "NaN 回退 0")
        XCTAssertEqual(ReaderModel.continuousPageSpacing(.infinity), 0, "无穷大回退 0")
    }
}
