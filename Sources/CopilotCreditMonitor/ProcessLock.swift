import Darwin
import Foundation

final class ProcessLock {
    private var fd: Int32 = -1
    private let lockURL: URL

    init(lockURL: URL) {
        self.lockURL = lockURL
    }

    deinit {
        release()
    }

    func acquire() throws {
        if fd != -1 { return }
        fd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        if fd == -1 {
            throw NSError(domain: "ProcessLock", code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "Cannot open lock file: \(lockURL.path)",
            ])
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            close(fd)
            fd = -1
            if code == EWOULDBLOCK {
                throw NSError(
                    domain: "ProcessLock",
                    code: Int(code),
                    userInfo: [NSLocalizedDescriptionKey: "Another CopilotCreditMonitor instance is already running."]
                )
            }
            throw NSError(domain: "ProcessLock", code: Int(code), userInfo: [
                NSLocalizedDescriptionKey: "Cannot acquire lock: \(lockURL.path)",
            ])
        }
    }

    func release() {
        guard fd != -1 else { return }
        _ = flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }
}
