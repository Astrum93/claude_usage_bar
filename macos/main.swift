import Cocoa
import CryptoKit
import Network

extension String: @retroactive Error {}
extension Int: @retroactive Error {}

// MARK: - 자격증명
//
// 토큰 출처 우선순위:
//  1) ~/.claude/cubr-token — 사용자가 직접 넣어둔 장기 토큰(선택). 갱신 없음.
//  2) 앱 전용 로그인 — 메뉴 'Claude 로그인'으로 브라우저 승인 1회. 앱이 자기 토큰만 갱신한다.
//  3) Claude Code 키체인 항목 — 읽기 전용. 절대 갱신하거나 되쓰지 않는다.
//
// 왜 앱 전용 로그인인가: Claude Code와 같은 토큰을 같이 갱신하면 갱신 토큰이 회전될 때
// 한쪽이 든 토큰이 무효가 되고, 실행 중인 Claude Code가 실패하면서 로그인 정보를 지운다.
// 그러면 Claude Code도 로그아웃되고 앱도 멈춘다. 별도 로그인은 서로 건드릴 일이 없다.
//
// 키체인 접근은 전부 Apple 정식 도구 /usr/bin/security 를 거친다 — 키체인이 기본 신뢰하는
// 도구라 허용 창이 뜨지 않고, 앱을 다시 빌드해도 영향이 없다.


let kService = "Claude Code-credentials"   // Claude Code 항목 (읽기 전용)
let kAuthService = "ClaudeUsageBar-auth"     // 앱 전용 로그인 저장 항목
let kClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e" // Claude Code 공개 OAuth 클라이언트
let kAuthorizeURL = "https://claude.com/cai/oauth/authorize"
let kTokenURL = "https://platform.claude.com/v1/oauth/token"
let kUsageURL = "https://api.anthropic.com/api/oauth/usage"
let kScopes = ["user:profile", "user:inference", "user:sessions:claude_code", "user:mcp_servers", "user:file_upload"]

enum CredSource {
    case tokenFile   // ~/.claude/cubr-token (갱신 불가)
    case own         // 앱 전용 로그인 (앱이 갱신)
    case cli         // Claude Code 항목 (읽기 전용 — 만료되면 Claude Code가 갱신할 때까지 대기)
}

struct CredStore {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Double?   // ms epoch
    var source: CredSource

    var isExpired: Bool {
        guard let exp = expiresAt else { return false }
        return exp / 1000 < Date().timeIntervalSince1970 + 60
    }
}

/// /usr/bin/security 실행. 응답이 없는 경우를 대비해 시간 제한을 둔다.
func runSecurity(_ args: [String], timeout: TimeInterval = 30) -> (out: String, err: String, code: Int32, timedOut: Bool) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = args
    let outPipe = Pipe(), errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    do { try p.run() } catch { return ("", "\(error)", -1, false) }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
    var timedOut = false
    if p.isRunning { p.terminate(); timedOut = true }
    let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (out, err, p.terminationStatus, timedOut)
}

// MARK: 앱 전용 로그인 저장소

func readOwnAuth() -> CredStore? {
    let r = runSecurity(["find-generic-password", "-s", kAuthService, "-a", "default", "-w"])
    guard r.code == 0,
          let d = r.out.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let access = o["accessToken"] as? String, !access.isEmpty else { return nil }
    return CredStore(accessToken: access,
                     refreshToken: o["refreshToken"] as? String,
                     expiresAt: o["expiresAt"] as? Double,
                     source: .own)
}

func writeOwnAuth(_ s: CredStore) {
    var o: [String: Any] = ["accessToken": s.accessToken]
    if let r = s.refreshToken { o["refreshToken"] = r }
    if let e = s.expiresAt { o["expiresAt"] = e }
    guard let d = try? JSONSerialization.data(withJSONObject: o),
          let json = String(data: d, encoding: .utf8) else { return }
    _ = runSecurity(["add-generic-password", "-U", "-s", kAuthService, "-a", "default",
                     "-l", "ClaudeUsageBar 로그인", "-w", json])
}

func deleteOwnAuth() {
    _ = runSecurity(["delete-generic-password", "-s", kAuthService, "-a", "default"])
}

/// 토큰 응답(JSON)을 저장소 형태로
func storeFromTokenResponse(_ o: [String: Any], previousRefresh: String?) -> CredStore? {
    guard let access = o["access_token"] as? String, !access.isEmpty else { return nil }
    var exp: Double? = nil
    if let sec = o["expires_in"] as? Double { exp = (Date().timeIntervalSince1970 + sec) * 1000 }
    return CredStore(accessToken: access,
                     refreshToken: (o["refresh_token"] as? String) ?? previousRefresh,
                     expiresAt: exp, source: .own)
}

// MARK: Claude Code 항목 (읽기 전용)

func readCLIItem() -> CredStore? {
    let meta = runSecurity(["find-generic-password", "-s", kService], timeout: 15)
    guard meta.code == 0 else { return nil }
    var args = ["find-generic-password", "-s", kService]
    if let r = meta.out.range(of: #""acct"<blob>="[^"]*""#, options: .regularExpression) {
        let line = String(meta.out[r])
        if let q1 = line.range(of: "=\""), let q2 = line.range(of: "\"", options: .backwards), q1.upperBound < q2.lowerBound {
            args += ["-a", String(line[q1.upperBound..<q2.lowerBound])]
        }
    }
    args.append("-w")
    let r = runSecurity(args)
    guard r.code == 0,
          let d = r.out.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let oauth = o["claudeAiOauth"] as? [String: Any],
          let access = oauth["accessToken"] as? String, !access.isEmpty else { return nil }
    let exp = oauth["expiresAt"] as? Double
    return CredStore(accessToken: access, refreshToken: nil,
                     expiresAt: (exp ?? 0) > 0 ? exp : nil, source: .cli)
}

// MARK: 토큰 선택

var cachedStore: CredStore?
let needLoginMessage = "로그인 필요 — 메뉴에서 'Claude 로그인'을 눌러 주세요"

func loadStore() -> CredStore? {
    if let c = cachedStore, !(c.source == .cli && c.isExpired) { return c }

    // 1) 수동 등록 토큰 파일
    let tokenPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/cubr-token")
    if let raw = try? String(contentsOf: tokenPath, encoding: .utf8),
       let r = raw.range(of: #"sk-ant-[A-Za-z0-9_\-]{20,}"#, options: .regularExpression) {
        cachedStore = CredStore(accessToken: String(raw[r]), refreshToken: nil, expiresAt: nil, source: .tokenFile)
        return cachedStore
    }
    // 2) 앱 전용 로그인
    if let own = readOwnAuth() { cachedStore = own; return own }
    // 3) Claude Code 항목 (읽기 전용, 유효할 때만)
    if let cli = readCLIItem(), !cli.isExpired { cachedStore = cli; return cli }
    cachedStore = nil
    return nil
}

// MARK: 토큰 갱신 (앱 전용 로그인만)

func refreshOwn(_ store: CredStore, completion: @escaping (Result<CredStore, String>) -> Void) {
    guard let refresh = store.refreshToken, !refresh.isEmpty else {
        completion(.failure(needLoginMessage)); return
    }
    postToken([
        "grant_type": "refresh_token",
        "refresh_token": refresh,
        "client_id": kClientID,
        "scope": kScopes.joined(separator: " "),
    ]) { result in
        switch result {
        case .failure(let code):
            cachedStore = nil
            if code == 400 || code == 401 {
                deleteOwnAuth() // 갱신 토큰이 무효 — 다시 로그인해야 함
                completion(.failure(needLoginMessage))
            } else {
                completion(.failure("토큰 갱신 실패(\(code)) — 다음 갱신 때 다시 시도"))
            }
        case .success(let o):
            guard let s = storeFromTokenResponse(o, previousRefresh: refresh) else {
                completion(.failure("토큰 갱신 응답을 해석할 수 없음")); return
            }
            writeOwnAuth(s)
            cachedStore = s
            completion(.success(s))
        }
    }
}

func postToken(_ body: [String: String], completion: @escaping (Result<[String: Any], Int>) -> Void) {
    var req = URLRequest(url: URL(string: kTokenURL)!)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)
    req.timeoutInterval = 30
    URLSession.shared.dataTask(with: req) { data, resp, _ in
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let data = data,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            completion(.failure(code)); return
        }
        completion(.success(o))
    }.resume()
}

func withFreshToken(completion: @escaping (Result<String, String>) -> Void) {
    guard let store = loadStore() else { completion(.failure(needLoginMessage)); return }
    if store.source == .own && store.isExpired {
        refreshOwn(store) { r in completion(r.map { $0.accessToken }) }
    } else {
        completion(.success(store.accessToken))
    }
}

/// 구버전이 만들었던 앱 소유 키체인 항목 정리
func removeLegacyOwnItem() {
    let q: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "ClaudeUsageBar",
    ]
    SecItemDelete(q as CFDictionary)
}

// MARK: - 앱 전용 로그인 (브라우저 승인 → localhost 콜백 → 토큰 교환)

func base64url(_ d: Data) -> String {
    d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

func randomURLSafe(_ bytes: Int) -> String {
    var b = [UInt8](repeating: 0, count: bytes)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
    return base64url(Data(b))
}

final class OAuthLogin {
    private var listener: NWListener?
    private var verifier = ""
    private var state = ""
    private var port: UInt16 = 0
    private var done = false
    private var completion: ((Result<Void, String>) -> Void)?

    func start(completion: @escaping (Result<Void, String>) -> Void) {
        self.completion = completion
        verifier = randomURLSafe(32)
        state = randomURLSafe(32)
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        guard let l = try? NWListener(using: params) else {
            finish(.failure("로그인 준비 실패 (포트를 열 수 없음)")); return
        }
        listener = l
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        l.stateUpdateHandler = { [weak self] st in
            guard let self = self else { return }
            switch st {
            case .ready:
                self.port = l.port?.rawValue ?? 0
                self.openBrowser()
            case .failed(let e):
                self.finish(.failure("로그인 준비 실패: \(e.localizedDescription)"))
            default: break
            }
        }
        l.start(queue: .main)
        // 5분 안에 승인이 안 오면 정리
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
            self?.finish(.failure("로그인 시간 초과 — 다시 시도해 주세요"))
        }
    }

    private func openBrowser() {
        let challenge = base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        var c = URLComponents(string: kAuthorizeURL)!
        c.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: kClientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: "http://localhost:\(port)/callback"),
            URLQueryItem(name: "scope", value: kScopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self = self else { conn.cancel(); return }
            let req = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let firstLine = req.split(separator: "\r\n").first.map(String.init) ?? ""
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2, parts[1].hasPrefix("/callback"),
                  let comps = URLComponents(string: "http://localhost" + parts[1]) else {
                self.respond(conn, status: "404 Not Found", body: "Not found"); return
            }
            let items = comps.queryItems ?? []
            let code = items.first { $0.name == "code" }?.value
            let st = items.first { $0.name == "state" }?.value
            guard let code = code, st == self.state else {
                self.respond(conn, status: "400 Bad Request", body: self.page("로그인 실패", "승인 정보가 올바르지 않습니다. 메뉴에서 다시 시도해 주세요."))
                self.finish(.failure("로그인 실패 — 승인 정보 불일치")); return
            }
            self.respond(conn, status: "200 OK", body: self.page("로그인 완료", "ClaudeUsageBar 로그인이 끝났습니다. 이 창은 닫아도 됩니다."))
            self.exchange(code: code)
        }
    }

    private func exchange(code: String) {
        postToken([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": "http://localhost:\(port)/callback",
            "client_id": kClientID,
            "code_verifier": verifier,
            "state": state,
        ]) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let c): self?.finish(.failure("토큰 교환 실패(\(c)) — 다시 시도해 주세요"))
                case .success(let o):
                    guard let s = storeFromTokenResponse(o, previousRefresh: nil) else {
                        self?.finish(.failure("토큰 응답을 해석할 수 없음")); return
                    }
                    writeOwnAuth(s)
                    cachedStore = s
                    self?.finish(.success(()))
                }
            }
        }
    }

    private func page(_ title: String, _ msg: String) -> String {
        "<!doctype html><meta charset=utf-8><title>\(title)</title>" +
        "<body style='font-family:-apple-system,sans-serif;text-align:center;padding-top:15vh'>" +
        "<h2>✳ \(title)</h2><p>\(msg)</p></body>"
    }

    private func respond(_ conn: NWConnection, status: String, body: String) {
        let b = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(b.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + b, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func finish(_ r: Result<Void, String>) {
        guard !done else { return }
        done = true
        listener?.cancel()
        listener = nil
        completion?(r)
    }
}

// MARK: - 사용량 API

struct UsageWindow {
    let key: String
    let utilization: Double // 0-100
    let resetsAt: Date?
}

let windowLabels: [String: String] = [
    "five_hour": "5시간",
    "seven_day": "주간 (전체)",
    "seven_day_sonnet": "주간 (Sonnet)",
    "seven_day_opus": "주간 (Opus)",
    "seven_day_oauth_apps": "주간 (연동 앱)",
]

func parseUsage(_ data: Data) -> [UsageWindow] {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
    let iso = ISO8601DateFormatter()
    let isoFrac = ISO8601DateFormatter()
    isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var out: [UsageWindow] = []
    for (key, value) in obj {
        // 5시간·주간 창이 null이면 그 창에 사용 기록이 없다는 뜻 → 0%로 표시
        if value is NSNull, key == "five_hour" || key == "seven_day" {
            out.append(UsageWindow(key: key, utilization: 0, resetsAt: nil))
            continue
        }
        // utilization 은 이미 0~100 퍼센트다 (2.0 = 2%). 비율로 보고 ×100 하면 1%가 100%로 보인다.
        guard let dict = value as? [String: Any], let util = dict["utilization"] as? Double else { continue }
        var resets: Date?
        if let s = dict["resets_at"] as? String {
            resets = isoFrac.date(from: s) ?? iso.date(from: s)
        } else if let t = dict["resets_at"] as? Double {
            resets = Date(timeIntervalSince1970: t > 1e12 ? t / 1000 : t)
        }
        out.append(UsageWindow(key: key, utilization: util, resetsAt: resets))
    }
    let order = ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus", "seven_day_oauth_apps"]
    out.sort { (order.firstIndex(of: $0.key) ?? 99) < (order.firstIndex(of: $1.key) ?? 99) }
    return out
}

func fetchUsage(completion: @escaping (Result<[UsageWindow], String>) -> Void) {
    withFreshToken { result in
        switch result {
        case .failure(let msg): completion(.failure(msg))
        case .success(let token):
            var req = URLRequest(url: URL(string: kUsageURL)!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.timeoutInterval = 15
            URLSession.shared.dataTask(with: req) { data, resp, err in
                if let err = err { completion(.failure("네트워크 오류: \(err.localizedDescription)")); return }
                guard let http = resp as? HTTPURLResponse, let data = data else {
                    completion(.failure("응답 없음")); return
                }
                guard http.statusCode == 200 else {
                    if http.statusCode == 429 {
                        completion(.failure("일시 요청 제한 — 다음 갱신 때 자동 재시도")); return
                    }
                    if http.statusCode == 401 {
                        // 토큰이 무효 — 앱 전용 로그인이면 다음 갱신 때 새로 발급, 아니면 다시 읽음
                        if var c = cachedStore, c.source == .own {
                            c.expiresAt = 0; cachedStore = c
                        } else {
                            cachedStore = nil
                        }
                        completion(.failure("인증 만료 — 다음 갱신 때 자동 재시도")); return
                    }
                    let body = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
                    completion(.failure("API 오류 \(http.statusCode): \(body)")); return
                }
                if CommandLine.arguments.contains("--raw") {
                    print(String(data: data, encoding: .utf8) ?? "")
                }
                let windows = parseUsage(data)
                if windows.isEmpty {
                    let body = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
                    completion(.failure("사용량 데이터 없음: \(body)"))
                } else {
                    completion(.success(windows))
                }
            }.resume()
        }
    }
}

// MARK: - 표시 포맷

func resetString(_ date: Date?) -> String {
    guard let date = date else { return "" }
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "ko_KR")
    fmt.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M/d(E) HH:mm"
    return " · 리셋 \(fmt.string(from: date))"
}

// MARK: - CLI 검증 모드 (--once, --login)

if CommandLine.arguments.contains("--login") {
    let login = OAuthLogin()
    login.start { r in
        switch r {
        case .success: print("로그인 성공")
        case .failure(let m): print("ERROR: \(m)")
        }
        exit(0)
    }
    RunLoop.main.run()
}

if CommandLine.arguments.contains("--once") {
    let sem = DispatchSemaphore(value: 0)
    fetchUsage { result in
        switch result {
        case .failure(let msg): print("ERROR: \(msg)")
        case .success(let windows):
            for w in windows {
                let label = windowLabels[w.key] ?? w.key
                print("\(label): \(String(format: "%.0f", w.utilization))%\(resetString(w.resetsAt))")
            }
        }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

// MARK: - 메뉴바 앱

// Claude 앱 아이콘에서 추출한 주황색 (#E28560)
let claudeOrange = NSColor(srgbRed: 0xE2 / 255.0, green: 0x85 / 255.0, blue: 0x60 / 255.0, alpha: 1)

// 메뉴바 모양(라이트/다크)에 따라 그릴 때마다 색이 정해지는 동적 색
func dynamicColor(dark: NSColor, light: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    }
}

// 메뉴바 게이지 한 줄: 라벨(색·크기 비율) + 사용률
struct GaugeRow {
    let label: String
    let pct: Double
    let labelColor: NSColor
    let labelScale: CGFloat
}

// MARK: - 드롭다운 메뉴 뷰

// 사용률 구간 색 (메뉴바 바와 같은 기준)
func usageColor(_ pct: Double) -> NSColor {
    pct < 50 ? .systemGreen : (pct < 80 ? .systemYellow : .systemRed)
}

// 숫자 글자색 — 라이트 모드에서는 노랑이 흐려서 주황으로 대신한다
func usageTextColor(_ pct: Double) -> NSColor {
    pct < 50 ? .systemGreen : (pct < 80 ? dynamicColor(dark: .systemYellow, light: .systemOrange) : .systemRed)
}

// 둥근 진행 바 — draw() 안에서 색을 정해 라이트/다크 전환에 자동 대응
final class MenuBarGaugeView: NSView {
    let pct: Double
    init(pct: Double) {
        self.pct = pct
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 6).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        let track = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        track.fill()
        let frac = CGFloat(min(max(pct / 100, 0), 1))
        guard frac > 0 else { return }
        let w = max(r.height, r.width * frac) // 아주 작은 값도 점으로는 보이게
        let fill = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: r.height),
                                xRadius: r.height / 2, yRadius: r.height / 2)
        usageColor(pct).setFill()
        fill.fill()
    }
}

func menuLabel(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
               color: NSColor = .labelColor, monoDigits: Bool = false) -> NSTextField {
    let f = NSTextField(labelWithString: text)
    f.font = monoDigits ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
                        : .systemFont(ofSize: size, weight: weight)
    f.textColor = color
    f.lineBreakMode = .byTruncatingTail
    return f
}

func symbolView(_ name: String, size: CGFloat, color: NSColor) -> NSImageView {
    let v = NSImageView()
    v.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size, weight: .medium))
    v.contentTintColor = color
    v.setContentHuggingPriority(.required, for: .horizontal)
    return v
}

// 메뉴 상단 카드: 헤더(마크·제목·갱신 시각) + 오류 + 창별 사용량
func makeUsagePanel(windows: [UsageWindow], error: String?, lastUpdate: Date?,
                    stale: Bool, mark: NSImage?) -> NSView {
    let width = menuWidth
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.edgeInsets = NSEdgeInsets(top: 8, left: menuPad, bottom: 10, right: menuPad)
    stack.translatesAutoresizingMaskIntoConstraints = false

    // 헤더
    let iconView = NSImageView()
    if let mark = mark {
        iconView.image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            mark.draw(in: rect)
            claudeOrange.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
    } else {
        iconView.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)
        iconView.contentTintColor = claudeOrange
    }
    iconView.setContentHuggingPriority(.required, for: .horizontal)
    let title = menuLabel("Claude 사용량", size: 13, weight: .semibold)
    var updateText = "갱신 대기 중"
    if let t = lastUpdate {
        let fmt = DateFormatter()
        fmt.dateFormat = Calendar.current.isDateInToday(t) ? "HH:mm:ss" : "M/d HH:mm"
        updateText = "마지막 갱신 \(fmt.string(from: t))" + (stale ? " (오래된 값)" : "")
    }
    let update = menuLabel(updateText, size: 10.5, color: stale ? .systemOrange : .secondaryLabelColor,
                           monoDigits: true)
    // 제목 아래 줄에 갱신 시각 — 오래된 값 표시가 붙어도 제목이 잘리지 않게
    let titles = NSStackView(views: [title, update])
    titles.orientation = .vertical
    titles.alignment = .leading
    titles.spacing = 1
    let header = NSStackView(views: [iconView, titles])
    header.spacing = 8
    header.alignment = .centerY
    stack.addArrangedSubview(header)

    // 오류
    if let err = error {
        let msg = NSTextField(wrappingLabelWithString: err)
        msg.font = .systemFont(ofSize: 11)
        msg.textColor = .secondaryLabelColor
        msg.preferredMaxLayoutWidth = width - menuPad * 2 - 22
        let icon = symbolView("exclamationmark.triangle.fill", size: 12, color: .systemOrange)
        let sp = NSView()
        sp.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [msg, sp, icon]) // 텍스트 왼쪽, 아이콘 오른쪽
        row.alignment = .top
        row.spacing = 8
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalToConstant: width - menuPad * 2).isActive = true
    }

    // 창별 사용량
    for w in windows {
        let name = menuLabel(windowLabels[w.key] ?? w.key, size: 12, weight: .medium)
        let pctLabel = menuLabel("\(Int(w.utilization.rounded()))%", size: 13, weight: .semibold,
                                 color: usageTextColor(w.utilization), monoDigits: true)
        let sp = NSView()
        sp.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let top = NSStackView(views: [name, sp, pctLabel])
        let bar = MenuBarGaugeView(pct: w.utilization)
        var rows: [NSView] = [top, bar]
        let reset = resetString(w.resetsAt).replacingOccurrences(of: " · ", with: "")
        if !reset.isEmpty {
            rows.append(menuLabel(reset, size: 10.5, color: .secondaryLabelColor, monoDigits: true))
        }
        let block = NSStackView(views: rows)
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 5
        for v in [top, bar] {
            v.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
        }
        stack.addArrangedSubview(block)
        block.widthAnchor.constraint(equalToConstant: width - menuPad * 2).isActive = true
    }
    header.widthAnchor.constraint(equalToConstant: width - menuPad * 2).isActive = true

    let container = NSView()
    container.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        stack.topAnchor.constraint(equalTo: container.topAnchor),
        stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        stack.widthAnchor.constraint(equalToConstant: width),
    ])
    container.frame = NSRect(origin: .zero, size: container.fittingSize)
    return container
}

// 메뉴 안 토글 스위치. 기본 NSSwitch는 메뉴(비활성 창)에서 켜짐 색이 빠져 회색으로만 보여서 직접 그린다.
// 켜짐 = Claude 주황, 꺼짐 = 회색 트랙. 잠김(마지막 하나라 끌 수 없음)일 때는 흐리게.
final class MenuToggle: NSView {
    var isOn = true { didSet { needsDisplay = true } }
    var isLocked = false { didSet { needsDisplay = true } }
    var onChange: ((Bool) -> Void)?
    private let size = NSSize(width: 30, height: 17)

    init() {
        super.init(frame: NSRect(origin: .zero, size: size))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size.width).isActive = true
        heightAnchor.constraint(equalToConstant: size.height).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let track = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        let onColor = claudeOrange.withAlphaComponent(isLocked ? 0.55 : 1)
        let offColor = NSColor.labelColor.withAlphaComponent(0.18)
        (isOn ? onColor : offColor).setFill()
        track.fill()
        // 손잡이 — 그림자 있는 흰 원
        let d = r.height - 3
        let x = isOn ? r.maxX - d - 1.5 : r.minX + 1.5
        let knob = NSBezierPath(ovalIn: NSRect(x: x, y: r.minY + 1.5, width: d, height: d))
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        NSColor.white.withAlphaComponent(isLocked ? 0.85 : 1).setFill()
        knob.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard !isLocked else { return }
        isOn.toggle()
        onChange?(isOn)
    }
}

// 드롭다운 공통 치수 — 모든 줄의 텍스트는 왼쪽 menuPad, 아이콘·체크·토글은 오른쪽 menuPad에 맞춘다
let menuWidth: CGFloat = 280
let menuPad: CGFloat = 16

// 드롭다운 한 줄: 왼쪽 텍스트 + 오른쪽 액세서리(아이콘/체크/토글).
// 기본 NSMenuItem은 체크·아이콘 칸 때문에 텍스트 시작 위치가 달라져서, 모든 줄을 이 뷰로 그린다.
final class MenuRow: NSView {
    let label: NSTextField
    let accessory: NSView?
    let accessoryTint: NSColor?
    var onClick: (() -> Void)?
    var closesMenu = true      // 누르면 메뉴를 닫을지 (토글 줄은 열어 둔다)
    var highlightable = true   // 마우스를 올렸을 때 강조 배경을 그릴지
    var enabled = true { didSet { needsDisplay = true } }
    private let baseColor: NSColor

    init(title: String, accessory: NSView? = nil, accessoryTint: NSColor? = nil, height: CGFloat = 24,
         font: NSFont = .systemFont(ofSize: 13), color: NSColor = .labelColor) {
        label = NSTextField(labelWithString: title)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        baseColor = color
        self.accessory = accessory
        self.accessoryTint = accessoryTint
        super.init(frame: NSRect(x: 0, y: 0, width: menuWidth, height: height))
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        var cs = [
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: menuPad),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        if let acc = accessory {
            acc.translatesAutoresizingMaskIntoConstraints = false
            addSubview(acc)
            cs += [
                acc.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -menuPad),
                acc.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.trailingAnchor.constraint(lessThanOrEqualTo: acc.leadingAnchor, constant: -8),
            ]
        } else {
            cs.append(label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -menuPad))
        }
        NSLayoutConstraint.activate(cs)
    }
    required init?(coder: NSCoder) { fatalError() }

    // 메뉴가 강조 상태를 바꿀 때마다 다시 그려진다
    override func draw(_ dirtyRect: NSRect) {
        let hi = highlightable && enabled && onClick != nil && (enclosingMenuItem?.isHighlighted ?? false)
        if hi {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 4, yRadius: 4).fill()
        }
        label.textColor = hi ? .white : (enabled ? baseColor : .tertiaryLabelColor)
        if let iv = accessory as? NSImageView {
            iv.contentTintColor = hi ? .white : (enabled ? accessoryTint : .tertiaryLabelColor)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard enabled, let action = onClick else { return }
        if closesMenu {
            enclosingMenuItem?.menu?.cancelTracking()
            DispatchQueue.main.async { action() } // 메뉴가 닫힌 뒤 실행
        } else {
            action()
        }
    }
}

func menuItem(_ view: NSView) -> NSMenuItem {
    let item = NSMenuItem()
    item.view = view
    return item
}

// 섹션 제목 줄 — 작은 회색 굵은 글씨, 텍스트 시작 위치는 다른 줄과 같다
func sectionHeader(_ title: String) -> NSMenuItem {
    let row = MenuRow(title: title, height: 22, font: .systemFont(ofSize: 11, weight: .semibold),
                      color: .secondaryLabelColor)
    row.highlightable = false
    return menuItem(row)
}

// 오른쪽 아이콘 (SF Symbol)
func accessoryIcon(_ name: String, color: NSColor = .secondaryLabelColor, size: CGFloat = 12) -> NSImageView {
    let v = symbolView(name, size: size, color: color)
    return v
}

func symbol(_ name: String) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var lastWindows: [UsageWindow] = []
    var lastError: String?
    var lastUpdate: Date?

    // 메뉴바에 표시할 줄 (five_hour, seven_day) — 최소 한 줄은 켜져 있어야 한다. 재시작 후에도 유지
    let displayKeys = ["five_hour", "seven_day"]
    func isShown(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: "show_\(key)") as? Bool ?? true
    }
    func setShown(_ key: String, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: "show_\(key)")
    }
    var displaySwitches: [String: MenuToggle] = [:]

    // 켜진 줄이 하나뿐이면 그 스위치는 끌 수 없게 비활성화
    func updateSwitchLocks() {
        let onCount = displayKeys.filter(isShown).count
        for (key, sw) in displaySwitches {
            sw.isOn = isShown(key)
            sw.isLocked = onCount == 1 && isShown(key)
        }
    }

    func toggleDisplay(_ key: String, _ on: Bool) {
        if !on && displayKeys.filter(isShown).count <= 1 { return }
        setShown(key, on)
        updateSwitchLocks()
        updateTitle()
    }

    // 메뉴 안 토글 한 줄: 제목 + 스위치 (클릭해도 메뉴가 닫히지 않는다)
    func makeSwitchRow(_ title: String, key: String) -> NSView {
        let sw = MenuToggle()
        sw.onChange = { [weak self] on in self?.toggleDisplay(key, on) }
        displaySwitches[key] = sw
        let row = MenuRow(title: title, accessory: sw, height: 26)
        row.highlightable = false
        row.closesMenu = false
        // 글자 쪽을 눌러도 토글된다
        row.onClick = { [weak sw] in
            guard let sw = sw, !sw.isLocked else { return }
            sw.isOn.toggle()
            sw.onChange?(sw.isOn)
        }
        return row
    }

    // 갱신 주기(초) — 기본 3분. 잦은 요청은 API 429 제한을 유발할 수 있음
    var refreshInterval: Double {
        get { let v = UserDefaults.standard.double(forKey: "refreshInterval"); return v > 0 ? v : 180 }
        set { UserDefaults.standard.set(newValue, forKey: "refreshInterval") }
    }

    func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // 노치 맥북은 메뉴바 공간이 부족하면 아이콘을 통째로 숨기므로 폭을 최소화한다.
    func setBarText(_ s: String) {
        statusItem.button?.image = nil
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        statusItem.button?.attributedTitle = NSAttributedString(string: s, attributes: [.font: font])
    }

    // Claude 데스크톱 앱의 메뉴바 마크를 실행 시 읽어 온다 (저장소에 상표 이미지를 넣지 않기 위해).
    // 데스크톱 앱이 없으면 nil → ✳ 문자로 대신 그린다.
    lazy var claudeMark: NSImage? = Bundle(path: "/Applications/Claude.app")?.image(forResource: "TrayIconTemplate")

    // 두 줄 게이지: 위 = 5시간 창, 아래 = 주간 한도. 각 줄은 100% 기준 진행 바 + 숫자.
    // 바 색은 사용률(50/80% 경계)에 따라 초록/노랑/빨강.
    // drawingHandler 방식이라 라이트/다크 메뉴바 전환 시 자동으로 다시 그려진다.
    func setBarGauge(_ rows: [GaugeRow], mark: String) {
        guard !rows.isEmpty else { return }
        let iconSize: CGFloat = 16, gap: CGFloat = 3
        let barWidth: CGFloat = 36, barHeight: CGFloat = 5
        let textGap: CGFloat = 4, rowGap: CGFloat = 2
        // 숫자 높이(capHeight)가 바 높이의 1.5배가 되도록 글자 크기를 정한다
        let probe = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        let fontSize = barHeight * 1.5 / (probe.capHeight / 10)
        let textFont = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
        let rowHeight = max(barHeight, textFont.capHeight)
        // 바 오른쪽 사용량 숫자는 라벨보다 살짝 작게 (85%)
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: fontSize * 0.85, weight: .semibold)
        // ⚠ 는 첫 줄 숫자 뒤에만 붙인다
        let texts = rows.enumerated().map { i, r in "\(Int(r.pct.rounded()))%" + (i == 0 ? mark : "") }
        // 바 왼쪽 라벨(5h, W) — 오른쪽 정렬해서 두 바의 시작점을 맞춘다
        let labelGap: CGFloat = 3
        // 라벨 글꼴은 줄마다 크기 비율(labelScale)을 따로 적용한다
        let labelFonts = rows.map {
            // 라벨 전체를 10% 줄인 뒤 줄마다 비율 적용
            NSFont.monospacedDigitSystemFont(ofSize: fontSize * 0.9 * $0.labelScale, weight: .semibold)
        }
        let labelWidth = zip(rows, labelFonts).map {
            ceil(NSAttributedString(string: $0.label, attributes: [.font: $1]).size().width)
        }.max() ?? 0
        let barX = iconSize + gap + labelWidth + labelGap
        let textWidth = texts.map {
            ceil(NSAttributedString(string: $0, attributes: [.font: numberFont]).size().width)
        }.max() ?? 0
        let blockHeight = rowHeight * CGFloat(rows.count) + rowGap * CGFloat(rows.count - 1)
        let height = max(iconSize, ceil(blockHeight))
        let total = NSSize(width: barX + barWidth + textGap + textWidth, height: height)
        let icon = claudeMark
        let image = NSImage(size: total, flipped: false) { _ in
            // 1) Claude 마크 — 세로 가운데, Claude 앱 아이콘의 주황색으로 칠한다 (라이트/다크 공통)
            let iconRect = NSRect(x: 0, y: (height - iconSize) / 2, width: iconSize, height: iconSize)
            if let icon = icon {
                icon.draw(in: iconRect)
                claudeOrange.setFill()
                iconRect.fill(using: .sourceAtop)
            } else {
                let font = NSFont.systemFont(ofSize: 13, weight: .medium)
                let s = NSAttributedString(string: "✳", attributes: [.font: font, .foregroundColor: claudeOrange])
                let sz = s.size()
                s.draw(at: NSPoint(x: iconRect.midX - sz.width / 2, y: iconRect.midY - sz.height / 2))
            }
            // 2) 줄마다 바 + 숫자 (위에서부터)
            let top = (height + blockHeight) / 2
            for (i, row) in rows.enumerated() {
                let pct = row.pct
                let centerY = top - rowHeight / 2 - CGFloat(i) * (rowHeight + rowGap)
                let frac = CGFloat(min(max(pct / 100, 0), 1))
                let fillColor: NSColor = pct < 50 ? .systemGreen : (pct < 80 ? .systemYellow : .systemRed)
                let barRect = NSRect(x: barX, y: centerY - barHeight / 2, width: barWidth, height: barHeight)
                let r = barRect.insetBy(dx: 0.5, dy: 0.5)
                let track = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
                NSColor.labelColor.withAlphaComponent(0.15).setFill()
                track.fill()
                if frac > 0 {
                    NSGraphicsContext.saveGraphicsState()
                    track.addClip()
                    fillColor.setFill()
                    NSRect(x: r.minX, y: r.minY, width: r.width * frac, height: r.height).fill()
                    NSGraphicsContext.restoreGraphicsState()
                }
                NSColor.labelColor.withAlphaComponent(0.45).setStroke()
                track.lineWidth = 1
                track.stroke()
                // 숫자 가운데를 바 가운데에 맞춘다
                if let ctx = NSGraphicsContext.current?.cgContext {
                    let attr = NSAttributedString(string: texts[i], attributes: [
                        .font: numberFont, .foregroundColor: row.labelColor, // 숫자도 라벨과 같은 색
                    ])
                    ctx.textPosition = CGPoint(x: barRect.maxX + textGap, y: centerY - numberFont.capHeight / 2)
                    CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
                    // 라벨 — 줄마다 지정한 색·크기, 세로 가운데는 바에 맞춘다
                    let lf = labelFonts[i]
                    let lab = NSAttributedString(string: row.label, attributes: [
                        .font: lf, .foregroundColor: row.labelColor,
                    ])
                    let lw = lab.size().width
                    ctx.textPosition = CGPoint(x: barX - labelGap - lw, y: centerY - lf.capHeight / 2)
                    CTLineDraw(CTLineCreateWithAttributedString(lab), ctx)
                }
            }
            return true
        }
        guard let button = statusItem.button else { return }
        button.image = image
        button.imagePosition = .imageOnly
        button.title = ""
    }

    // 마지막 성공 후 이만큼 지나면 '오래된 값'으로 본다 (갱신 주기 3회분 + 여유)
    var isStale: Bool {
        guard let t = lastUpdate else { return true }
        return Date().timeIntervalSince(t) > refreshInterval * 3 + 60
    }

    func updateTitle() {
        guard !lastWindows.isEmpty else { return }
        // 위 = 5시간 창, 아래 = 주간 한도 (응답에 없는 창은 건너뛴다)
        // 5h = 다크 흰색 / 라이트 검정, W = 다크 밝은 하늘색 / 라이트 진한 파랑 (+ 조금 작게)
        let specs: [(key: String, label: String, color: NSColor, scale: CGFloat)] = [
            ("five_hour", "5h", dynamicColor(dark: .white, light: .black), 1.0),
            ("seven_day", "W", dynamicColor(
                dark: NSColor(srgbRed: 0.45, green: 0.78, blue: 1.0, alpha: 1),
                light: NSColor(srgbRed: 0.0, green: 0.38, blue: 0.80, alpha: 1)), 0.85),
        ]
        let rows = specs.filter { isShown($0.key) }.compactMap { sp in
            lastWindows.first { $0.key == sp.key }.map {
                GaugeRow(label: sp.label, pct: $0.utilization, labelColor: sp.color, labelScale: sp.scale)
            }
        }
        // 갱신이 끊긴 채 옛 수치를 보여줄 때는 ⚠ 를 붙여 정상값처럼 보이지 않게 한다
        let mark = (lastError != nil || isStale) ? "⚠" : ""
        setBarGauge(rows.isEmpty
            ? [GaugeRow(label: "", pct: lastWindows[0].utilization, labelColor: .labelColor, labelScale: 1)]
            : rows, mark: mark)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        removeLegacyOwnItem()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "ClaudeUsageBar" // 사용자가 ⌘드래그로 옮긴 위치를 기억
        setBarText("✳…")
        rebuildMenu()
        refresh()
        startTimer()
    }

    var refreshing = false

    func refresh() {
        if refreshing { return } // 허용 창 대기 등으로 길어질 때 중복 실행 방지
        refreshing = true
        // 키체인 조회가 길어져도(허용 창 대기) 메뉴바가 멈추지 않도록 백그라운드에서 실행
        DispatchQueue.global(qos: .utility).async {
            fetchUsage { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.refreshing = false
                    switch result {
                    case .success(let windows):
                        self.lastWindows = windows
                        self.lastError = nil
                        self.lastUpdate = Date()
                    case .failure(let msg):
                        self.lastError = msg
                    }
                    if self.lastError == needLoginMessage {
                        self.setBarText("✳로그인") // 숫자 대신 로그인 필요를 바로 보이게
                    } else if self.lastWindows.isEmpty {
                        self.setBarText(self.lastError == nil ? "✳…" : "✳–")
                    } else {
                        self.updateTitle() // 옛 수치 유지 + 오류 시 ⚠ 표시
                    }
                    self.rebuildMenu()
                }
            }
        }
    }

    func rebuildMenu() {
        let menu = NSMenu()
        // 상단 사용량 카드 (오류·창별 사용량·마지막 갱신을 한 패널에)
        let panel = NSMenuItem()
        panel.view = makeUsagePanel(windows: lastWindows, error: lastError, lastUpdate: lastUpdate,
                                    stale: lastUpdate != nil && isStale, mark: claudeMark)
        menu.addItem(panel)
        menu.addItem(.separator())
        menu.addItem(sectionHeader("메뉴바 표시"))
        displaySwitches = [:]
        for (key, title) in [("five_hour", "5시간 (5h)"), ("seven_day", "주간 (W)")] {
            menu.addItem(menuItem(makeSwitchRow(title, key: key)))
        }
        updateSwitchLocks()
        menu.addItem(.separator())
        menu.addItem(sectionHeader("갱신 주기"))
        let intervals: [(Double, String)] = [
            (60, "1분"),
            (120, "2분"),
            (180, "3분"),
        ]
        for (sec, label) in intervals {
            let selected = refreshInterval == sec
            let row = MenuRow(title: label,
                              accessory: selected ? accessoryIcon("checkmark", color: claudeOrange) : nil,
                              accessoryTint: claudeOrange)
            row.onClick = { [weak self] in
                self?.refreshInterval = sec
                self?.startTimer()
                self?.rebuildMenu()
            }
            menu.addItem(menuItem(row))
        }
        menu.addItem(.separator())
        let loggedIn = (cachedStore?.source == .own)
        let loginTitle = loginInProgress ? "로그인 진행 중… (브라우저에서 승인)"
            : (loggedIn ? "Claude 다시 로그인" : "Claude 로그인 (브라우저)")
        let loginRow = MenuRow(title: loginTitle,
                               accessory: accessoryIcon(loginInProgress ? "hourglass" : "person.crop.circle"),
                               accessoryTint: .secondaryLabelColor)
        loginRow.enabled = !loginInProgress
        loginRow.onClick = { [weak self] in self?.startLogin() }
        menu.addItem(menuItem(loginRow))

        let refreshRow = MenuRow(title: "지금 갱신", accessory: accessoryIcon("arrow.clockwise"),
                                 accessoryTint: .secondaryLabelColor)
        refreshRow.onClick = { [weak self] in self?.refreshNow() }
        let refreshItem = menuItem(refreshRow)
        // 단축키(⌘R)는 보이지 않아도 메뉴가 열린 상태에서 동작하도록 유지
        refreshItem.keyEquivalent = "r"
        refreshItem.action = #selector(refreshNow)
        refreshItem.target = self
        menu.addItem(refreshItem)

        let quitRow = MenuRow(title: "종료", accessory: accessoryIcon("power"), accessoryTint: .secondaryLabelColor)
        quitRow.onClick = { NSApp.terminate(nil) }
        let quitItem = menuItem(quitRow)
        quitItem.keyEquivalent = "q"
        quitItem.action = #selector(NSApplication.terminate(_:))
        quitItem.target = NSApp
        menu.addItem(quitItem)
        // 뷰 항목은 action이 없어도 강조(호버)되도록 자동 비활성화를 끈다
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    var login: OAuthLogin?
    var loginInProgress = false

    @objc func startLogin() {
        loginInProgress = true
        rebuildMenu()
        let l = OAuthLogin()
        login = l
        l.start { [weak self] r in
            guard let self = self else { return }
            self.loginInProgress = false
            self.login = nil
            if case .failure(let m) = r { self.lastError = m }
            self.rebuildMenu()
            self.refresh()
        }
    }

    @objc func refreshNow() {
        cachedStore = nil // 수동 갱신은 토큰도 원본에서 다시 읽는다
        refresh()
    }

}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
