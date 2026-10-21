import Foundation
import AudioCore

extension BackendLibraryStore {
    func startWorker(_ request: WorkerRequest) throws {
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        _ = try self.request("/api/v1/jobs/start", method: "POST", body: body)
    }
    func ingestWorker(_ event: WorkerEvent, request: WorkerRequest) throws -> Bool? {
        let eventObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event))
        let requestObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
        let response = try self.request("/api/v1/jobs/event", method: "POST", body: ["event": eventObject, "request": requestObject])
        return (try JSONSerialization.jsonObject(with: response) as? [String: Any])?["activated"] as? Bool
    }
    func stopWorker(_ id: String, state: String) throws { _ = try request("/api/v1/jobs/\(id)/stop", method: "POST", body: ["state": state]) }
}
