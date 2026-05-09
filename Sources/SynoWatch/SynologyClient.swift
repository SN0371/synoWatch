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
        guard let url = makeURL(path: "webapi/entry.cgi", params: [
            "api": "SYNO.Core.Package",
            "version": "2",
            "method": "list",
            "additional": "[\"status\",\"update_info\"]",
            "_sid": sid,
        ]) else { return [] }

        guard let data = await fetch(url),
              let response = try? JSONDecoder().decode(PackageListResponse.self, from: data),
              response.success,
              let packages = response.data?.packages else { return [] }

        return packages.filter(\.hasUpdate).map(\.displayName)
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
    /// DSM 7 sets this to "upgradable" for packages with an available update.
    let status: String?
    /// Fallback field used by some DSM versions.
    let update_available: Bool?

    var hasUpdate: Bool {
        status == "upgradable" || update_available == true
    }

    var displayName: String { name ?? id }
}
