import Foundation

extension Error {
    /// The caller stopped waiting — a screen closed, a task was cancelled —
    /// rather than the request failing. Nothing to tell anyone about.
    var isCancellation: Bool {
        if self is CancellationError { return true }
        let error = self as NSError
        return error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
    }
}
