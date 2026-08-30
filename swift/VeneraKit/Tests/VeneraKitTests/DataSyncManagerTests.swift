import XCTest
@testable import VeneraKit

final class DataSyncManagerTests: XCTestCase {
    func testDataSyncTaskClampsProgressAndRoundTrips() throws {
        let task = DataSyncTask(
            operation: .download,
            backupName: "backup.venera",
            progress: 2,
            phase: "Downloading"
        )
        XCTAssertEqual(task.progress, 1)
        XCTAssertTrue(task.isRunning)

        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(DataSyncTask.self, from: data)
        XCTAssertEqual(decoded.id, task.id)
        XCTAssertEqual(decoded.operation, .download)
        XCTAssertEqual(decoded.backupName, "backup.venera")
        XCTAssertEqual(decoded.progress, 1)

        let importTask = DataSyncTask(operation: .import, fileName: "data.venera")
        XCTAssertEqual(importTask.operation, DataSyncTask.Operation.import)
        XCTAssertEqual(importTask.fileName, "data.venera")

        let exportTask = DataSyncTask(operation: .export)
        let exportData = try JSONEncoder().encode(exportTask)
        let decodedExport = try JSONDecoder().decode(DataSyncTask.self, from: exportData)
        XCTAssertEqual(decodedExport.operation, .export)
    }

    func testDataSyncTaskStatusAndOperationAreCodable() throws {
        let task = DataSyncTask(
            operation: .upload,
            forceUpload: true,
            status: .failed,
            progress: 0.4,
            phase: "Failed",
            error: "HTTP 500"
        )
        let decoded = try JSONDecoder().decode(
            DataSyncTask.self,
            from: JSONEncoder().encode(task)
        )
        XCTAssertEqual(decoded.operation, DataSyncTask.Operation.upload)
        XCTAssertEqual(decoded.status, DataSyncTask.Status.failed)
        XCTAssertTrue(decoded.forceUpload)
        XCTAssertFalse(decoded.isRunning)
        XCTAssertEqual(decoded.error, "HTTP 500")
    }
    func testDecodesHistoryWrittenBeforeFileNameWasAdded() throws {
        let json = """
        {"id":"legacy","operation":"upload","backupName":null,"forceUpload":false,"createdAt":0,"finishedAt":null,"status":"completed","progress":1,"phase":"Completed","error":null}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DataSyncTask.self, from: json)
        XCTAssertEqual(decoded.id, "legacy")
        XCTAssertNil(decoded.fileName)
        XCTAssertEqual(decoded.status, DataSyncTask.Status.completed)
    }

}
