import Darwin
import Foundation

/// File operations for client configs that work from a pinned directory descriptor, so a path that is swapped for a
/// symlink after it was checked can't redirect them, and that create files exclusively (`O_CREAT|O_EXCL|O_NOFOLLOW`).
///
/// Following a config file that is itself a symlink is done once, by `ClientConfig.plan`, on purpose. Everything here
/// then works on the resolved folder and never follows a link in the last component.
final class PinnedDirectory {
    let fd: Int32
    let path: String

    init(path: String) throws {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ClientConfigError("cannot open the folder \(path): \(ClientFiles.reason())") }
        self.fd = fd
        self.path = path
    }

    deinit { close(fd) }

    /// An open descriptor for a regular file in the folder, or nil when it isn't there. A symlink is refused.
    func openFile(_ name: String) throws -> Int32? {
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if file < 0 {
            if errno == ENOENT { return nil }
            throw ClientConfigError("cannot open \(path)/\(name): \(ClientFiles.reason())")
        }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(file)
            throw ClientConfigError("\(path)/\(name) isn't a regular file")
        }
        return file
    }

    /// What a file holds right now, or nil when it isn't there.
    func read(_ name: String) throws -> (data: Data, info: stat)? {
        guard let file = try openFile(name) else { return nil }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0 else { throw ClientConfigError("cannot read \(path)/\(name): \(ClientFiles.reason())") }
        return (try ClientFiles.readAll(file, describing: "\(path)/\(name)"), info)
    }

    /// Creates a file that didn't exist, trying `name(0)`, `name(1)`, … until one is free. An existing file, a
    /// symlink (dangling or not) or a planted name is never opened: it counts as taken.
    func createExclusive(mode: mode_t, name: (Int) -> String) throws -> (name: String, fd: Int32) {
        for attempt in 0..<200 {
            let candidate = name(attempt)
            let file = openat(fd, candidate, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
            if file >= 0 { return (candidate, file) }
            if errno == EEXIST { continue }
            throw ClientConfigError("cannot create \(path)/\(candidate): \(ClientFiles.reason())")
        }
        throw ClientConfigError("cannot find an unused file name in \(path)")
    }

    func remove(_ name: String) { unlinkat(fd, name, 0) }

    /// Whether anything (a link included) has this name.
    func exists(_ name: String) -> Bool {
        var info = stat()
        return fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0
    }

    /// Renames `from` over `to`. With `replacing` false, `to` must not exist: the rename then fails (EEXIST) instead of
    /// overwriting a file someone else just created.
    func rename(_ from: String, to: String, replacing: Bool) -> Int32? {
        let status = replacing ? renameat(fd, from, fd, to) : renameatx_np(fd, from, fd, to, UInt32(RENAME_EXCL))
        return status == 0 ? nil : errno
    }
}

enum ClientFiles {
    static func reason(_ code: Int32 = errno) -> String { String(cString: strerror(code)) }

    static func readAll(_ file: Int32, describing path: String) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(file, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw ClientConfigError("cannot read \(path): \(reason())")
            }
            if n == 0 { return data }
            data.append(contentsOf: buffer[0..<n])
        }
    }

    static func writeAll(_ file: Int32, _ data: Data, describing path: String) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(file, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw ClientConfigError("cannot write \(path): \(reason())")
                }
                offset += n
            }
        }
    }

    /// Gives `destination` the owner, group, permissions and ACL of `source`, and checks that it took. Throws when it
    /// can't, so a file isn't replaced by one that is owned by someone else or open to more people than the original.
    static func copySecurity(from source: Int32, to destination: Int32) throws {
        guard fcopyfile(source, destination, nil, copyfile_flags_t(COPYFILE_SECURITY)) == 0 else {
            throw ClientConfigError("cannot copy the file's owner, permissions and access list: \(reason())")
        }
        var a = stat(), b = stat()
        guard fstat(source, &a) == 0, fstat(destination, &b) == 0 else { throw ClientConfigError("cannot compare file permissions: \(reason())") }
        guard a.st_uid == b.st_uid, a.st_gid == b.st_gid, a.st_mode & 0o7777 == b.st_mode & 0o7777 else {
            throw ClientConfigError("cannot keep the file's owner, group or permissions (it is owned by user \(a.st_uid), group \(a.st_gid))")
        }
        guard aclText(source) == aclText(destination) else { throw ClientConfigError("cannot keep the file's access control list") }
    }

    static func aclText(_ file: Int32) -> String? {
        guard let acl = acl_get_fd_np(file, ACL_TYPE_EXTENDED) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard let text = acl_to_text(acl, nil) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(text)) }
        return String(cString: text)
    }
}

/// Where backups of client configs go: MacMCP's own support folder, which agents can't open (`ProtectedPaths`), and
/// not beside the original, where a client's folder is open to them and the copy would hold every server's `env`.
enum ClientBackups {
    static func directory(home: String) -> String { home + "/Library/Application Support/MacMCP/client-backups" }

    /// The folder, made if need be with mode 0700, and checked: a real folder (not a link), ours and closed to others.
    static func open(home: String) throws -> PinnedDirectory {
        let folder = directory(home: home)
        let support = (folder as NSString).deletingLastPathComponent
        let applicationSupport = (support as NSString).deletingLastPathComponent
        for (path, mode) in [((applicationSupport as NSString).deletingLastPathComponent, mode_t(0o755)), (applicationSupport, 0o755),
                             (support, 0o700), (folder, 0o700)] {
            if mkdir(path, mode) != 0, errno != EEXIST {
                throw ClientConfigError("cannot create \(path) for the backup: \(ClientFiles.reason()); nothing was changed")
            }
        }
        var link = stat()
        guard lstat(folder, &link) == 0, link.st_mode & S_IFMT == S_IFDIR else {
            throw ClientConfigError("\(folder) isn't a plain folder (a symlink or a file?), so it can't hold backups; nothing was changed")
        }
        let pinned = try PinnedDirectory(path: folder)
        var info = stat()
        guard fstat(pinned.fd, &info) == 0, info.st_uid == geteuid() else {
            throw ClientConfigError("\(folder) belongs to another user, so it can't hold backups; nothing was changed")
        }
        if info.st_mode & 0o077 != 0, fchmod(pinned.fd, 0o700) != 0 {
            throw ClientConfigError("cannot make \(folder) private: \(ClientFiles.reason()); nothing was changed")
        }
        return pinned
    }

    /// `<client>-<yyyymmdd-hhmmss>[-n]-<label>`, so the client and the time are clear from the name.
    static func fileName(client: McpClient, label: String, now: Date, attempt: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let tidy = label.drop { $0 == "." }
        return "\(client.rawValue)-\(formatter.string(from: now))" + (attempt == 0 ? "" : "-\(attempt + 1)") + "-" + (tidy.isEmpty ? "config" : String(tidy))
    }

    /// Writes `data` as a new 0600 file in the backup folder, reads it back, and returns its path.
    static func write(_ data: Data, client: McpClient, label: String, home: String, now: Date) throws -> (path: String, name: String, folder: PinnedDirectory) {
        let folder = try open(home: home)
        let created = try folder.createExclusive(mode: 0o600) { fileName(client: client, label: label, now: now, attempt: $0) }
        let path = folder.path + "/" + created.name
        do {
            defer { close(created.fd) }
            try ClientFiles.writeAll(created.fd, data, describing: path)
            guard fsync(created.fd) == 0 else { throw ClientConfigError("cannot write \(path): \(ClientFiles.reason())") }
            guard try folder.read(created.name)?.data == data else { throw ClientConfigError("\(path) read back differently") }
        } catch {
            folder.remove(created.name)
            throw ClientConfigError("cannot write a backup to \(path) (\(error)); nothing was changed")
        }
        return (path, created.name, folder)
    }
}
