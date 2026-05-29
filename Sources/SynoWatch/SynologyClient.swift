import Foundation

/// Result of a Synology update check.
enum UpdateCheckResult {
    case noUpdates
    case updatesAvailable(firmwareVersion: String?, packages: [String])
    /// Login failed because MFA is enabled and no valid device ID is stored.
    /// The user must open Settings and register a trusted device with their OTP.
    case otpRequired
    case error(String)
}

/// Client for the Synology DSM 7 REST API.
///
/// Uses an ephemeral URLSession to avoid caching credentials in memory longer than necessary.
/// The DSM password is passed as a query parameter as required by the Synology API —
/// use HTTPS in production to ensure it is encrypted in transit.
struct SynologyClient {
    private let baseURL: URL
    private let session: URLSession

    init(host: String, port: Int, useHTTPS: Bool) {
        let scheme = useHTTPS ? "https" : "http"
        // Safe: host and port are validated in SettingsView before being persisted.
        self.baseURL = URL(string: "\(scheme)://\(host):\(port)")!
        self.session = URLSession(configuration: .ephemeral)
    }

    // MARK: - Public API

    /// Logs in, checks for DSM firmware and package updates, logs out, and returns the result.
    ///
    /// Pass a stored `deviceId` to bypass MFA on subsequent calls after initial registration.
    func checkForUpdates(username: String, password: String, deviceId: String?) async -> UpdateCheckResult {
        let loginResult = await login(username: username, password: password, deviceId: deviceId)

        switch loginResult {
        case .otpRequired:
            return .otpRequired
        case .failed(let message):
            return .error(message)
        case .success(let sid, _):
            async let firmware = checkFirmwareUpdate(sid: sid)
            async let packages = checkPackageUpdates(sid: sid)
            let (firmwareResult, packageResult) = await (firmware, packages)
            await logout(sid: sid)

            if firmwareResult != nil || !packageResult.isEmpty {
                return .updatesAvailable(firmwareVersion: firmwareResult, packages: packageResult)
            }
            return .noUpdates
        }
    }

    /// Performs a one-time login with an OTP code to register this app as a trusted device.
    ///
    /// On success, returns the `device_id` that should be stored in the Keychain and
    /// passed to subsequent `checkForUpdates` calls to skip MFA.
    func registerTrustedDevice(username: String, password: String, otpCode: String) async -> RegistrationResult {
        let loginResult = await login(
            username: username,
            password: password,
            otpCode: otpCode
        )
        switch loginResult {
        case .success(let sid, let deviceId):
            await logout(sid: sid)
            guard let did = deviceId else {
                return .failure("Login succeeded but DSM did not return a device token. Check that 'Trusted devices' is enabled in your DSM account settings.")
            }
            return .success(did)
        case .otpRequired:
            return .failure("OTP code was rejected. Make sure you entered the current code from your authenticator app.")
        case .failed(let message):
            return .failure(message)
        }
    }

    // MARK: - Private

    enum RegistrationResult {
        case success(String)
        case failure(String)
    }

    private enum LoginResult {
        case success(sid: String, deviceId: String?)
        case otpRequired
        case failed(String)
    }

    private func login(
        username: String,
        password: String,
        otpCode: String? = nil,
        deviceId: String? = nil
    ) async -> LoginResult {
        var params: [String: String] = [
            "api": "SYNO.API.Auth",
            "version": "6",
            "method": "login",
            "account": username,
            "passwd": password,
            "session": "SynoWatch",
            "format": "sid",
        ]
        if let did = deviceId {
            params["device_id"] = did
        }
        if let otp = otpCode {
            params["otp_code"] = otp
            params["device_name"] = "SynoWatch"
            params["enable_device_token"] = "yes"
        }

        guard let url = makeURL(path: "webapi/auth.cgi", params: params),
              let data = await fetch(url) else {
            return .failed("Could not reach the Synology host. Check the host address and port.")
        }

        guard let response = try? JSONDecoder().decode(AuthResponse.self, from: data) else {
            return .failed("Unexpected response from DSM.")
        }

        if response.success, let sid = response.data?.sid {
            return .success(sid: sid, deviceId: response.data?.did)
        }

        // DSM error codes for MFA:
        //   403 – OTP not specified
        //   404 – OTP incorrect
        //   406 – MFA enforced (account requires 2FA)
        switch response.error?.code {
        case 403, 404, 406:
            return .otpRequired
        default:
            return .failed("Login failed (DSM error \(response.error?.code ?? -1)). Check username and password.")
        }
    }

    private func logout(sid: String) async {
        guard let url = makeURL(path: "webapi/auth.cgi", params: [
            "api": "SYNO.API.Auth",
            "version": "6",
            "method": "logout",
            "session": "SynoWatch",
            "_sid": sid,
        ]) else { return }
        _ = await fetch(url)
    }

    /// Returns the new firmware version string if an update is available, otherwise nil.
    private func checkFirmwareUpdate(sid: String) async -> String? {
        guard let url = makeURL(path: "webapi/entry.cgi", params: [
            "api": "SYNO.Core.System.Update",
            "version": "1",
            "method": "check",
            "_sid": sid,
        ]) else { return nil }

        guard let data = await fetch(url),
              let response = try? JSONDecoder().decode(SystemUpdateResponse.self, from: data),
              response.success,
              response.data?.available == true else { return nil }
        return response.data?.version
    }

    /// Returns the display names of installed packages that have an available update.
    private func checkPackageUpdates(sid: String) async -> [String] {
        // Step 1: installed packages, keyed by package ID.
        guard let installedURL = makeURL(path: "webapi/entry.cgi", params: [
            "api": "SYNO.Core.Package",
            "version": "2",
            "method": "list",
            "_sid": sid,
        ]),
        let installedData = await fetch(installedURL),
        let installedResp = try? JSONDecoder().decode(PackageListResponse.self, from: installedData),
        installedResp.success,
        let installedPackages = installedResp.data?.packages else { return [] }

        let installedMap = Dictionary(uniqueKeysWithValues: installedPackages.map { ($0.id, $0) })

        // Step 2: packages available on the Synology package server.
        guard let serverURL = makeURL(path: "webapi/entry.cgi", params: [
            "api": "SYNO.Core.Package.Server",
            "version": "2",
            "method": "list",
            "_sid": sid,
        ]),
        let serverData = await fetch(serverURL),
        let serverResp = try? JSONDecoder().decode(PackageServerResponse.self, from: serverData),
        serverResp.success,
        let serverPackages = serverResp.data?.packages else { return [] }

        // Step 3: packages whose server version is newer than the installed version.
        return serverPackages.compactMap { serverPkg in
            guard let pkgId = serverPkg.id,
                  let installed = installedMap[pkgId],
                  let serverVersion = serverPkg.version,
                  let installedVersion = installed.version,
                  isNewerVersion(serverVersion, than: installedVersion) else { return nil }
            return installed.displayName
        }
    }

    /// Returns true if `serverVersion` is strictly newer than `installedVersion`.
    ///
    /// Synology version strings have the form `major.minor.patch-build`.
    /// Compares the dotted version tuple first; falls back to build number if equal.
    private func isNewerVersion(_ serverVersion: String, than installedVersion: String) -> Bool {
        func parse(_ v: String) -> ([Int], Int) {
            let parts = v.split(separator: "-", maxSplits: 1)
            let version = (parts.first ?? "").split(separator: ".").compactMap { Int($0) }
            let build = parts.count > 1 ? (Int(String(parts[1])) ?? 0) : 0
            return (version, build)
        }
        let (sv, sb) = parse(serverVersion)
        let (iv, ib) = parse(installedVersion)
        if iv.lexicographicallyPrecedes(sv) { return true }
        if sv.lexicographicallyPrecedes(iv) { return false }
        return ib < sb
    }

    private func makeURL(path: String, params: [String: String]) -> URL? {
        var comps = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        comps?.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        return comps?.url
    }

    private func fetch(_ url: URL) async -> Data? {
        return try? await session.data(from: url).0
    }

    // MARK: - System monitor

    /// Logs in, fetches CPU, memory, volume, and fan data concurrently, logs out, and returns a snapshot.
    func fetchSystemInfo(username: String, password: String, deviceId: String?) async -> Result<SystemSnapshot, SynoError> {
        let loginResult = await login(username: username, password: password, deviceId: deviceId)
        switch loginResult {
        case .otpRequired:
            return .failure(SynoError("OTP required — open Settings to register a trusted device."))
        case .failed(let message):
            return .failure(SynoError(message))
        case .success(let sid, _):
            // Fans, system info, and utilization (which includes volume names) run concurrently.
            // Volume capacities are fetched afterwards because they need the volume names
            // from the utilization response.
            async let utilization = fetchUtilization(sid: sid)
            async let fans = fetchFans(sid: sid)
            async let sysInfo = fetchSystemInfo(sid: sid)
            let (util, fanList, hwInfo) = await (utilization, fans, sysInfo)

            guard let util else {
                await logout(sid: sid)
                return .failure(SynoError("Failed to fetch system utilization from DSM."))
            }

            let volumes = await fetchVolumes(sid: sid, volumeNames: util.volumeNames)
            await logout(sid: sid)

            let snapshot = SystemSnapshot(
                timestamp: Date(),
                cpuUsage: util.cpu,
                memoryUsed: util.memUsed,
                memoryTotal: util.memTotal,
                volumes: volumes,
                fans: fanList,
                systemTemp: hwInfo?.temp,
                tempWarning: hwInfo?.tempWarning ?? false
            )
            return .success(snapshot)
        }
    }

    /// Fetches CPU, memory utilization, and volume display names.
    ///
    /// Returns nil if the API call fails.
    private func fetchUtilization(sid: String) async -> (cpu: Double, memUsed: Int, memTotal: Int, volumeNames: [String])? {
        guard let url = makeURL(path: "webapi/entry.cgi", params: [
            "api": "SYNO.Core.System.Utilization",
            "version": "1",
            "method": "get",
            "_sid": sid,
        ]) else { return nil }

        guard let data = await fetch(url),
              let response = try? JSONDecoder().decode(UtilizationResponse.self, from: data),
              response.success,
              let d = response.data else { return nil }

        let cpu = Double(d.cpu?.user_load ?? 0)
        // DSM returns memory_size in KB and real_usage as a percentage (0–100).
        let totalKB = d.memory?.memory_size ?? 0
        let usedKB = totalKB * (d.memory?.real_usage ?? 0) / 100
        let volumeNames = (d.space?.volume ?? []).compactMap(\.display_name)
        return (cpu: cpu, memUsed: usedKB * 1024, memTotal: totalKB * 1024, volumeNames: volumeNames)
    }

    /// Fetches storage volume capacity via the FileStation share list.
    ///
    /// Each share exposes a `volume_status` with `freespace` and `totalspace`.
    /// Shares are deduplicated by `totalspace` to produce one entry per physical volume.
    /// Volume display names come from the utilization API's `space.volume` field.
    private func fetchVolumes(sid: String, volumeNames: [String]) async -> [VolumeInfo] {
        guard let url = makeURL(path: "webapi/entry.cgi", params: [
            "api": "SYNO.FileStation.List",
            "version": "2",
            "method": "list_share",
            "additional": "volume_status",
            "_sid": sid,
        ]) else { return [] }

        guard let data = await fetch(url),
              let response = try? JSONDecoder().decode(ShareListResponse.self, from: data),
              response.success,
              let shares = response.data?.shares else { return [] }

        // Deduplicate shares by totalspace — each unique value is one volume.
        var seen = Set<Int64>()
        var uniqueVolumes: [(free: Int64, total: Int64)] = []
        for share in shares {
            guard let vs = share.additional?.volume_status,
                  let total = vs.totalspace, total > 0,
                  let free = vs.freespace,
                  seen.insert(total).inserted else { continue }
            uniqueVolumes.append((free: free, total: total))
        }

        return uniqueVolumes.enumerated().map { i, vol in
            let name = i < volumeNames.count ? volumeNames[i] : "Volume \(i + 1)"
            return VolumeInfo(name: name, used: vol.total - vol.free, total: vol.total)
        }
    }

    /// Fetches system board temperature and warning flag from `SYNO.Core.System`.
    ///
    /// Returns nil if the API call fails.
    private func fetchSystemInfo(sid: String) async -> (temp: Int, tempWarning: Bool)? {
        guard let url = makeURL(path: "webapi/entry.cgi", params: [
            "api": "SYNO.Core.System",
            "version": "3",
            "method": "info",
            "_sid": sid,
        ]) else { return nil }

        guard let data = await fetch(url),
              let response = try? JSONDecoder().decode(SystemInfoResponse.self, from: data),
              response.success,
              let d = response.data else { return nil }

        return (temp: d.sys_temp ?? 0, tempWarning: d.anyTempWarning)
    }

    /// Fetches fan sensor data.
    ///
    /// Returns an empty array if the `SYNO.Core.Hardware.Fan` API is unavailable on this model.
    private func fetchFans(sid: String) async -> [FanInfo] {
        guard let url = makeURL(path: "webapi/entry.cgi", params: [
            "api": "SYNO.Core.Hardware.Fan",
            "version": "1",
            "method": "list",
            "_sid": sid,
        ]) else { return [] }

        guard let data = await fetch(url),
              let response = try? JSONDecoder().decode(FanListResponse.self, from: data),
              response.success,
              let fans = response.data?.fans else { return [] }

        return fans.map { FanInfo(id: $0.id, status: $0.status ?? "unknown", rpm: $0.rpm) }
    }
}

// MARK: - Response models

private struct AuthResponse: Decodable {
    let success: Bool
    let data: AuthData?
    let error: ErrorCode?

    struct AuthData: Decodable {
        let sid: String?
        /// Device token returned by DSM after a successful OTP login.
        /// Field name in the API is "did".
        let did: String?
    }

    struct ErrorCode: Decodable {
        let code: Int
    }
}

private struct SystemUpdateResponse: Decodable {
    let success: Bool
    let data: UpdateData?

    struct UpdateData: Decodable {
        let available: Bool?
        let version: String?
    }
}

private struct PackageListResponse: Decodable {
    let success: Bool
    let data: PackageData?

    struct PackageData: Decodable {
        let packages: [Package]?
    }
}

private struct Package: Decodable {
    let id: String
    let name: String?
    let version: String?

    var displayName: String { name ?? id }
}

private struct PackageServerResponse: Decodable {
    let success: Bool
    let data: ServerData?

    struct ServerData: Decodable {
        let packages: [ServerPackage]?
    }
}

private struct ServerPackage: Decodable {
    let id: String?
    let version: String?
}

// MARK: - System monitor error type

/// Wraps a human-readable error message returned by SynologyClient system-monitor calls.
struct SynoError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// MARK: - System monitor response models

private struct UtilizationResponse: Decodable {
    let success: Bool
    let data: UtilizationData?

    struct UtilizationData: Decodable {
        let cpu: CPUData?
        let memory: MemoryData?
        let space: SpaceData?
    }

    struct CPUData: Decodable {
        let user_load: Int?
    }

    struct MemoryData: Decodable {
        /// Total physical RAM, in KB.
        let memory_size: Int?
        /// RAM usage as a percentage (0–100).
        let real_usage: Int?
    }

    struct SpaceData: Decodable {
        let volume: [VolumeEntry]?

        struct VolumeEntry: Decodable {
            let display_name: String?
        }
    }
}

private struct ShareListResponse: Decodable {
    let success: Bool
    let data: ShareData?

    struct ShareData: Decodable {
        let shares: [Share]?
    }

    struct Share: Decodable {
        let additional: ShareAdditional?

        struct ShareAdditional: Decodable {
            let volume_status: VolumeStatus?

            struct VolumeStatus: Decodable {
                let freespace: Int64?
                let totalspace: Int64?
            }
        }
    }
}

private struct SystemInfoResponse: Decodable {
    let success: Bool
    let data: SystemInfoData?

    struct SystemInfoData: Decodable {
        let sys_temp: Int?
        let sys_tempwarn: Bool?
        let systempwarn: Bool?
        let temperature_warning: Bool?

        var anyTempWarning: Bool {
            (sys_tempwarn ?? false) || (systempwarn ?? false) || (temperature_warning ?? false)
        }
    }
}

private struct FanListResponse: Decodable {
    let success: Bool
    let data: FanData?

    struct FanData: Decodable {
        let fans: [FanEntry]?
    }

    struct FanEntry: Decodable {
        let id: String
        let status: String?
        let rpm: Int?

        enum CodingKeys: String, CodingKey {
            case id, status, rpm, speed
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            status = try? c.decode(String.self, forKey: .status)
            rpm = (try? c.decode(Int.self, forKey: .rpm))
                ?? (try? c.decode(Int.self, forKey: .speed))
        }
    }
}

