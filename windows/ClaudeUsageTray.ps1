# ClaudeUsageTray — 윈도우 작업표시줄 트레이에 Claude 사용량 표시
# 필요: Claude Code 로그인 (%USERPROFILE%\.claude\.credentials.json 이 있어야 함)
# 실행: powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File ClaudeUsageTray.ps1
# 오류 기록: %LOCALAPPDATA%\ClaudeUsageBar\cubr.log

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 구형 윈도우/PowerShell 5.1은 기본이 TLS 1.0이라 api.anthropic.com 접속이 실패할 수 있다
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$script:CredPath = Join-Path $env:USERPROFILE ".claude\.credentials.json"
$script:ClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"  # Claude Code 공개 OAuth 클라이언트
$script:TokenUrl = "https://console.anthropic.com/v1/oauth/token"
$script:UsageUrl = "https://api.anthropic.com/api/oauth/usage"
$script:LogDir   = Join-Path $env:LOCALAPPDATA "ClaudeUsageBar"
$script:LogPath  = Join-Path $script:LogDir "cubr.log"

$script:WindowLabels = @{
    "five_hour"           = "5시간"
    "seven_day"           = "주간 (전체)"
    "seven_day_sonnet"    = "주간 (Sonnet)"
    "seven_day_opus"      = "주간 (Opus)"
    "seven_day_oauth_apps"= "주간 (연동 앱)"
}
$script:WindowOrder = @("five_hour","seven_day","seven_day_sonnet","seven_day_opus","seven_day_oauth_apps")

# 상태
$script:LastWindows = $null
$script:LastUpdate  = $null
$script:LastError   = $null

function Write-Log([string]$msg) {
    try {
        if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
        if ((Test-Path $script:LogPath) -and ((Get-Item $script:LogPath).Length -gt 200KB)) {
            Move-Item $script:LogPath ($script:LogPath + ".old") -Force
        }
        $line = "{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $msg
        [System.IO.File]::AppendAllText($script:LogPath, $line + "`r`n", (New-Object System.Text.UTF8Encoding $false))
    } catch {}
}

# ---- 설정 (레지스트리, 재시작 후 유지) ----
$script:CfgReg = "HKCU:\Software\ClaudeUsageBar"
# New-Item -Force 는 이미 있는 레지스트리 키를 다시 만들면서 다른 설정값을 지울 수 있어서, 없을 때만 만든다
function Ensure-CfgKey {
    if (-not (Test-Path $script:CfgReg)) { New-Item -Path $script:CfgReg -Force | Out-Null }
}
# 트레이에 표시할 줄 (five_hour, seven_day) — 최소 한 줄은 켜져 있어야 한다
$script:DisplayKeys = @("five_hour", "seven_day")
function Get-Shown([string]$k) {
    try {
        $v = (Get-ItemProperty -Path $script:CfgReg -Name "Show_$k" -ErrorAction Stop)."Show_$k"
        return ([int]$v -ne 0)
    } catch {}
    return $true
}
function Set-Shown([string]$k, [bool]$on) {
    Ensure-CfgKey
    Set-ItemProperty -Path $script:CfgReg -Name "Show_$k" -Value ([int]$on) -Type DWord
}
function Get-RefreshSec {
    try {
        $v = (Get-ItemProperty -Path $script:CfgReg -Name RefreshSec -ErrorAction Stop).RefreshSec
        if ($v -ge 60) { return [int]$v }
    } catch {}
    return 180
}
function Set-RefreshSec($s) {
    Ensure-CfgKey
    Set-ItemProperty -Path $script:CfgReg -Name RefreshSec -Value ([int]$s) -Type DWord
}

# ---- 자격증명 ----

function Read-Credentials {
    if (-not (Test-Path $script:CredPath)) {
        throw "Claude Code 로그인 정보 없음 — 터미널에서 claude auth login 실행 필요"
    }
    # Claude Code가 파일을 쓰는 도중일 수 있으니 짧게 재시도
    for ($i = 0; $i -lt 3; $i++) {
        try {
            $raw = [System.IO.File]::ReadAllText($script:CredPath)
            $raw = $raw.TrimStart([char]0xFEFF)  # 혹시 남아 있는 BOM 제거
            return ($raw | ConvertFrom-Json)
        } catch {
            if ($i -eq 2) { throw "로그인 정보 파일을 읽을 수 없음: $($_.Exception.Message)" }
            Start-Sleep -Milliseconds 300
        }
    }
}

function Write-Credentials($cred) {
    # BOM 없는 UTF-8로 써야 한다. Set-Content -Encoding UTF8 은 BOM을 붙여서
    # Claude Code(Node.js)가 JSON 파싱에 실패해 로그인이 깨진다.
    $json = $cred | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($script:CredPath, $json, (New-Object System.Text.UTF8Encoding $false))
}

function Get-FreshToken {
    $cred = Read-Credentials
    $oauth = $cred.claudeAiOauth
    if (-not $oauth -or -not $oauth.accessToken) {
        throw "로그인 정보에 토큰 없음 — claude auth login 다시 실행 필요"
    }
    $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if ($oauth.expiresAt -and ([long]$oauth.expiresAt -lt ($nowMs + 60000))) {
        # 만료 → 갱신. 갱신 토큰이 회전되므로 원본 파일에 되써서 Claude Code와 같은 체인을 유지한다.
        if (-not $oauth.refreshToken) { throw "토큰 만료 (갱신 토큰 없음) — Claude Code를 한 번 실행하거나 claude auth login" }
        $body = @{ grant_type = "refresh_token"; refresh_token = $oauth.refreshToken; client_id = $script:ClientId } | ConvertTo-Json
        try {
            $resp = Invoke-RestMethod -Uri $script:TokenUrl -Method Post -ContentType "application/json" -Body $body -TimeoutSec 15
        } catch {
            Write-Log "토큰 갱신 실패: $($_.Exception.Message)"
            throw "토큰 갱신 실패 — Claude Code를 한 번 실행해 로그인을 갱신해 주세요"
        }
        $oauth.accessToken = $resp.access_token
        if ($resp.refresh_token) { $oauth.refreshToken = $resp.refresh_token }
        if ($resp.expires_in) {
            $newExp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + [long]($resp.expires_in * 1000)
            if ($oauth.PSObject.Properties["expiresAt"]) { $oauth.expiresAt = $newExp }
            else { $oauth | Add-Member -NotePropertyName expiresAt -NotePropertyValue $newExp }
        }
        Write-Credentials $cred
        Write-Log "토큰 갱신 성공 (원본 파일에 되씀)"
    }
    return $oauth.accessToken
}

# ---- 사용량 조회 ----

function Get-Usage {
    $token = Get-FreshToken
    $headers = @{
        "Authorization"  = "Bearer $token"
        "anthropic-beta" = "oauth-2025-04-20"
    }
    try {
        $resp = Invoke-RestMethod -Uri $script:UsageUrl -Headers $headers -TimeoutSec 15
    } catch {
        $code = 0
        try { $code = [int]$_.Exception.Response.StatusCode } catch {}
        if ($code -eq 429) { throw "일시 요청 제한(429) — 다음 갱신 때 자동 재시도" }
        if ($code -eq 401) { throw "인증 만료(401) — 다음 갱신 때 다시 시도" }
        throw "사용량 조회 실패($code): $($_.Exception.Message)"
    }
    $windows = @()
    foreach ($prop in $resp.PSObject.Properties) {
        $v = $prop.Value
        # 5시간·주간 창이 null이면 그 창에 사용 기록이 없다는 뜻 → 0%로 표시
        if ($null -eq $v -and ($prop.Name -eq "five_hour" -or $prop.Name -eq "seven_day")) {
            $windows += [pscustomobject]@{ Key = $prop.Name; Utilization = 0.0; ResetsAt = $null }
            continue
        }
        if ($null -ne $v -and $v.PSObject.Properties["utilization"] -and $null -ne $v.utilization) {
            # utilization 은 이미 0~100 퍼센트다 (2.0 = 2%). ×100 하면 1%가 100%로 보인다.
            $util = [double]$v.utilization
            $resets = $null
            if ($v.PSObject.Properties["resets_at"] -and $v.resets_at) {
                try { $resets = ([DateTimeOffset]::Parse($v.resets_at)).LocalDateTime } catch {}
            }
            $windows += [pscustomobject]@{ Key = $prop.Name; Utilization = $util; ResetsAt = $resets }
        }
    }
    @($windows | Sort-Object { $i = $script:WindowOrder.IndexOf($_.Key); if ($i -lt 0) { 99 } else { $i } })
}

# ---- 표시 ----
#
# 디자인은 맥 버전과 같다: 사용량 카드(창별 진행 바·리셋 시각), 텍스트 왼쪽 / 아이콘·체크·토글 오른쪽,
# 바 색 초록(<50%) / 노랑(<80%) / 빨강, 토글·체크는 Claude 주황.
# 트레이 아이콘은 정사각형이라 맥의 가로 게이지 대신
#   두 줄 표시: 위 5시간 · 아래 주간 막대 두 개
#   한 줄 표시: 사용률 숫자 + 막대 하나
# 로 그린다. 그리기는 아래 C# 코드(Add-Type)가 맡는다. PowerShell 5.1 컴파일러(C# 5) 문법만 쓴다.

$script:UiSource = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Microsoft.Win32;

namespace Cubr {
    public static class Ui {
        [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);

        public static float Scale = 1f;
        public static bool IsWin11 = false;
        public static Font MenuFont, HeaderFont, GlyphFont;

        public static void Init() {
            try { SetProcessDPIAware(); } catch { }
            try { using (Graphics g = Graphics.FromHwnd(IntPtr.Zero)) { Scale = g.DpiX / 96f; } } catch { Scale = 1f; }
            try {
                using (RegistryKey k = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion")) {
                    if (k != null) {
                        int build;
                        if (int.TryParse(Convert.ToString(k.GetValue("CurrentBuildNumber")), out build)) IsWin11 = build >= 22000;
                    }
                }
            } catch { }
            MenuFont = new Font("Segoe UI", F(13), FontStyle.Regular, GraphicsUnit.Pixel);
            HeaderFont = new Font("Segoe UI Semibold", F(11), FontStyle.Regular, GraphicsUnit.Pixel);
            GlyphFont = new Font("Segoe MDL2 Assets", F(12), FontStyle.Regular, GraphicsUnit.Pixel);
        }

        public static int S(float px) { return (int)Math.Round(px * Scale); }
        public static float F(float px) { return px * Scale; }

        // Win11 메뉴처럼 둥근 모서리 (Win10에서는 무시됨)
        public static void RoundCorners(IntPtr hwnd) {
            if (!IsWin11) return;
            try { int v = 3; DwmSetWindowAttribute(hwnd, 33, ref v, 4); } catch { }
        }

        static bool ReadLight(string name, bool def) {
            try {
                using (RegistryKey k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize")) {
                    if (k == null) return def;
                    object v = k.GetValue(name);
                    if (v == null) return def;
                    return Convert.ToInt32(v) != 0;
                }
            } catch { return def; }
        }
        // 앱(메뉴) 테마와 작업 표시줄 테마는 따로 설정될 수 있다
        public static bool AppsLight { get { return ReadLight("AppsUseLightTheme", true); } }
        public static bool TaskbarLight { get { return ReadLight("SystemUsesLightTheme", false); } }

        public static readonly Color Orange = Color.FromArgb(0xE2, 0x85, 0x60);
        public static Color Level(double p) {
            if (p < 50) return Color.FromArgb(0x34, 0xC7, 0x59);
            if (p < 80) return Color.FromArgb(0xFF, 0xCC, 0x00);
            return Color.FromArgb(0xFF, 0x3B, 0x30);
        }
        // 숫자 글자색 — 밝은 배경에서는 노랑 대신 주황
        public static Color LevelText(double p, bool light) {
            if (light && p >= 50 && p < 80) return Color.FromArgb(0xFF, 0x95, 0x00);
            return Level(p);
        }
        public static Color Bg(bool l) { return l ? Color.FromArgb(249, 249, 249) : Color.FromArgb(44, 44, 46); }
        public static Color Fg(bool l) { return l ? Color.FromArgb(28, 28, 30) : Color.FromArgb(242, 242, 247); }
        public static Color Fg2(bool l) { return l ? Color.FromArgb(110, 110, 115) : Color.FromArgb(160, 160, 168); }
        public static Color Fg3(bool l) { return l ? Color.FromArgb(170, 170, 175) : Color.FromArgb(105, 105, 112); }
        public static Color Line(bool l) { return l ? Color.FromArgb(225, 225, 228) : Color.FromArgb(66, 66, 70); }
        public static Color Track(bool l) { return l ? Color.FromArgb(226, 226, 230) : Color.FromArgb(70, 70, 74); }
        public static Color Hover(bool l) { return l ? Color.FromArgb(232, 232, 236) : Color.FromArgb(62, 62, 66); }
        public static Color WBlue(bool l) { return l ? Color.FromArgb(0, 97, 204) : Color.FromArgb(115, 199, 255); }

        public static GraphicsPath Round(RectangleF r, float rad) {
            GraphicsPath p = new GraphicsPath();
            float d = Math.Min(rad * 2, Math.Min(r.Width, r.Height));
            if (d <= 0.5f) { p.AddRectangle(r); return p; }
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }
        public static void FillRound(Graphics g, Color c, RectangleF r, float rad) {
            using (GraphicsPath p = Round(r, rad)) using (SolidBrush b = new SolidBrush(c)) { g.FillPath(b, p); }
        }
        // 둥근 진행 바 (아주 작은 값도 점으로는 보이게)
        public static void Bar(Graphics g, RectangleF r, double pct, Color track, Color fill) {
            SmoothingMode old = g.SmoothingMode;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            FillRound(g, track, r, r.Height / 2);
            float frac = (float)Math.Max(0, Math.Min(1, pct / 100));
            if (frac > 0) {
                float w = Math.Max(r.Height, r.Width * frac);
                FillRound(g, fill, new RectangleF(r.X, r.Y, w, r.Height), r.Height / 2);
            }
            g.SmoothingMode = old;
        }
        public static void Glyph(Graphics g, string glyph, Font f, Color c, Rectangle r) {
            TextRenderer.DrawText(g, glyph, f, r, c,
                TextFormatFlags.Right | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix);
        }
    }

    // ---- 트레이 아이콘 ----
    public static class TrayIcon {
        [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr h);

        static int Size() {
            int n = SystemInformation.SmallIconSize.Width;
            return n < 16 ? 16 : n;
        }
        static Icon ToIcon(Bitmap bmp) {
            IntPtr h = bmp.GetHicon();
            try { using (Icon tmp = Icon.FromHandle(h)) { return (Icon)tmp.Clone(); } }
            finally { DestroyIcon(h); }
        }

        // pcts: 표시할 줄의 사용률, labels: "5h" / "W". stale이면 회색(옛 값)
        public static Icon MakeGauge(double[] pcts, string[] labels, bool stale) {
            int n = Size();
            bool tl = Ui.TaskbarLight;
            Color track = tl ? Color.FromArgb(60, 0, 0, 0) : Color.FromArgb(80, 255, 255, 255);
            using (Bitmap bmp = new Bitmap(n, n)) {
                using (Graphics g = Graphics.FromImage(bmp)) {
                    g.Clear(Color.Transparent);
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                    if (pcts.Length >= 2) {
                        // 위 5시간 · 아래 주간
                        float bh = n * 0.30f, gap = n * 0.14f;
                        float top = (n - (bh * 2 + gap)) / 2f;
                        for (int i = 0; i < 2; i++) {
                            RectangleF r = new RectangleF(0.5f, top + i * (bh + gap), n - 1f, bh);
                            Ui.Bar(g, r, pcts[i], track, stale ? Color.Gray : Ui.Level(pcts[i]));
                        }
                    } else if (pcts.Length == 1) {
                        // 숫자 + 막대. 숫자 색은 맥 라벨과 같다 (5h 흰/검정, W 하늘색/진한 파랑)
                        string t = ((int)Math.Round(pcts[0])).ToString();
                        Color tc = (labels.Length > 0 && labels[0] == "W") ? Ui.WBlue(tl) : (tl ? Color.Black : Color.White);
                        if (stale) tc = Color.Gray;
                        float fs = n * (t.Length >= 3 ? 0.45f : 0.62f);
                        using (Font f = new Font("Segoe UI", fs, FontStyle.Bold, GraphicsUnit.Pixel))
                        using (SolidBrush b = new SolidBrush(tc))
                        using (StringFormat sf = new StringFormat()) {
                            sf.Alignment = StringAlignment.Center;
                            sf.LineAlignment = StringAlignment.Center;
                            g.DrawString(t, f, b, new RectangleF(-2, -n * 0.04f, n + 4, n * 0.72f), sf);
                        }
                        float bh2 = Math.Max(3f, n * 0.22f);
                        Ui.Bar(g, new RectangleF(0.5f, n - bh2 - 0.5f, n - 1f, bh2), pcts[0], track,
                               stale ? Color.Gray : Ui.Level(pcts[0]));
                    }
                }
                return ToIcon(bmp);
            }
        }

        // 로딩(…)·오류(!) 같은 글자 아이콘
        public static Icon MakeText(string t, Color c) {
            int n = Size();
            using (Bitmap bmp = new Bitmap(n, n)) {
                using (Graphics g = Graphics.FromImage(bmp)) {
                    g.Clear(Color.Transparent);
                    g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                    using (Font f = new Font("Segoe UI", n * 0.75f, FontStyle.Bold, GraphicsUnit.Pixel))
                    using (SolidBrush b = new SolidBrush(c))
                    using (StringFormat sf = new StringFormat()) {
                        sf.Alignment = StringAlignment.Center;
                        sf.LineAlignment = StringAlignment.Center;
                        g.DrawString(t, f, b, new RectangleF(-2, 0, n + 4, n), sf);
                    }
                }
                return ToIcon(bmp);
            }
        }
    }

    // ---- 메뉴 상단 사용량 카드 ----
    public class UsageRow {
        public string Label; public double Pct; public string Reset;
        public UsageRow(string label, double pct, string reset) { Label = label; Pct = pct; Reset = reset; }
    }

    public class UsageCard : Control {
        public string Title = "";
        public string UpdateText = "";
        public bool Stale = false;
        public string Error = null;
        public bool Light = true;
        public List<UsageRow> Rows = new List<UsageRow>();

        Font titleF, subF, labelF, pctF, smallF, markF, glyphF;

        public UsageCard() {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                     ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
            titleF = new Font("Segoe UI Semibold", Ui.F(13), FontStyle.Regular, GraphicsUnit.Pixel);
            subF   = new Font("Segoe UI", Ui.F(10.5f), FontStyle.Regular, GraphicsUnit.Pixel);
            labelF = new Font("Segoe UI Semibold", Ui.F(12), FontStyle.Regular, GraphicsUnit.Pixel);
            pctF   = new Font("Segoe UI", Ui.F(13), FontStyle.Bold, GraphicsUnit.Pixel);
            smallF = new Font("Segoe UI", Ui.F(10.5f), FontStyle.Regular, GraphicsUnit.Pixel);
            markF  = new Font("Segoe UI Symbol", Ui.F(15), FontStyle.Regular, GraphicsUnit.Pixel);
            glyphF = new Font("Segoe MDL2 Assets", Ui.F(12), FontStyle.Regular, GraphicsUnit.Pixel);
        }

        public void Relayout(int width) {
            Width = width;
            Height = Pass(null, width);
        }

        protected override void OnPaint(PaintEventArgs e) {
            Pass(e.Graphics, Width);
        }

        // 그리기와 높이 계산을 한 곳에서 (g == null 이면 계산만)
        int Pass(Graphics g, int width) {
            int pad = Ui.S(16), inner = width - pad * 2;
            TextFormatFlags L = TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix |
                                TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding;
            TextFormatFlags R = TextFormatFlags.Right | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix |
                                TextFormatFlags.NoPadding;
            if (g != null) {
                g.Clear(Ui.Bg(Light));
                g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
            }
            int y = Ui.S(10);

            // 헤더: 주황 마크 + 제목 + 마지막 갱신
            int hh = Ui.S(34);
            if (g != null) {
                TextRenderer.DrawText(g, "✳", markF, new Rectangle(pad - Ui.S(1), y, Ui.S(20), hh), Ui.Orange, L);
                int tx = pad + Ui.S(26);
                TextRenderer.DrawText(g, Title, titleF, new Rectangle(tx, y, inner - Ui.S(26), Ui.S(18)), Ui.Fg(Light), L);
                TextRenderer.DrawText(g, UpdateText, subF, new Rectangle(tx, y + Ui.S(18), inner - Ui.S(26), Ui.S(15)),
                                      Stale ? Ui.Orange : Ui.Fg2(Light), L);
            }
            y += hh + Ui.S(10);

            // 오류: 텍스트 왼쪽, 경고 아이콘 오른쪽
            if (!string.IsNullOrEmpty(Error)) {
                int tw = inner - Ui.S(22);
                TextFormatFlags W = TextFormatFlags.Left | TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding;
                Size sz = TextRenderer.MeasureText(Error, smallF, new Size(tw, int.MaxValue), W);
                if (g != null) {
                    TextRenderer.DrawText(g, Error, smallF, new Rectangle(pad, y, tw, sz.Height), Ui.Fg2(Light), W);
                    Ui.Glyph(g, "", glyphF, Ui.Orange, new Rectangle(pad, y, inner, Ui.S(16)));
                }
                y += Math.Max(sz.Height, Ui.S(16)) + Ui.S(12);
            }

            // 창별 사용량: 이름 왼쪽 · % 오른쪽, 진행 바, 리셋 시각
            for (int i = 0; i < Rows.Count; i++) {
                UsageRow row = Rows[i];
                if (g != null) {
                    TextRenderer.DrawText(g, row.Label, labelF, new Rectangle(pad, y, inner - Ui.S(60), Ui.S(18)), Ui.Fg(Light), L);
                    TextRenderer.DrawText(g, ((int)Math.Round(row.Pct)).ToString() + "%", pctF,
                                          new Rectangle(pad, y, inner, Ui.S(18)), Ui.LevelText(row.Pct, Light), R);
                }
                y += Ui.S(23);
                if (g != null) {
                    Ui.Bar(g, new RectangleF(pad, y, inner, Ui.F(6)), row.Pct, Ui.Track(Light), Ui.Level(row.Pct));
                }
                y += Ui.S(6) + Ui.S(5);
                if (!string.IsNullOrEmpty(row.Reset)) {
                    if (g != null) {
                        TextRenderer.DrawText(g, row.Reset, smallF, new Rectangle(pad, y, inner, Ui.S(15)), Ui.Fg2(Light), L);
                    }
                    y += Ui.S(15);
                }
                y += Ui.S(12);
            }
            return y - Ui.S(2);
        }

        protected override void Dispose(bool disposing) {
            if (disposing) {
                titleF.Dispose(); subF.Dispose(); labelF.Dispose(); pctF.Dispose();
                smallF.Dispose(); markF.Dispose(); glyphF.Dispose();
            }
            base.Dispose(disposing);
        }
    }

    // ---- 메뉴 렌더러: 모든 줄의 텍스트는 왼쪽 16px, 아이콘·체크·토글은 오른쪽 16px ----
    // item.Tag 로 줄 종류를 구분한다:
    //   "header"         섹션 제목 (작은 회색 굵은 글씨)
    //   "check"          선택형 (Checked면 오른쪽에 주황 체크)
    //   "toggle"         토글 (Checked = 켜짐)
    //   "toggle-locked"  켜져 있지만 마지막 하나라 끌 수 없음 (흐리게)
    //   "icon:<글리프>"  오른쪽에 Segoe MDL2 아이콘
    public class MenuRenderer : ToolStripRenderer {
        public bool Light = true;

        protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e) {
            e.Graphics.Clear(Ui.Bg(Light));
        }
        protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e) {
            if (Ui.IsWin11) return; // Win11은 DWM이 둥근 테두리를 그린다
            Rectangle r = new Rectangle(0, 0, e.ToolStrip.Width - 1, e.ToolStrip.Height - 1);
            using (Pen p = new Pen(Ui.Line(Light))) { e.Graphics.DrawRectangle(p, r); }
        }
        protected override void OnRenderImageMargin(ToolStripRenderEventArgs e) { }
        protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e) { }

        protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e) {
            int y = e.Item.Height / 2;
            using (Pen p = new Pen(Ui.Line(Light))) {
                e.Graphics.DrawLine(p, Ui.S(12), y, e.Item.Width - Ui.S(12), y);
            }
        }

        static string Kind(ToolStripItem it) { return it.Tag as string ?? ""; }

        protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e) {
            ToolStripItem it = e.Item;
            string k = Kind(it);
            bool hoverable = it.Enabled && k != "header" && !k.StartsWith("toggle");
            if (it.Selected && hoverable) {
                e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
                RectangleF r = new RectangleF(Ui.F(5), Ui.F(1), it.Width - Ui.F(10), it.Height - Ui.F(2));
                Ui.FillRound(e.Graphics, Ui.Hover(Light), r, Ui.F(4));
            }
        }

        protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e) {
            ToolStripItem it = e.Item;
            string k = Kind(it);
            bool header = k == "header";
            Font f = header ? Ui.HeaderFont : Ui.MenuFont;
            Color c = header ? Ui.Fg2(Light) : (it.Enabled ? Ui.Fg(Light) : Ui.Fg3(Light));
            int pad = Ui.S(16);
            Rectangle tr = new Rectangle(pad, 0, it.Width - pad * 2 - Ui.S(40), it.Height);
            TextRenderer.DrawText(e.Graphics, it.Text, f, tr, c,
                TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis |
                TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding);

            Rectangle acc = new Rectangle(pad, 0, it.Width - pad * 2, it.Height);
            ToolStripMenuItem mi = it as ToolStripMenuItem;
            if (k == "check") {
                if (mi != null && mi.Checked) Ui.Glyph(e.Graphics, "", Ui.GlyphFont, Ui.Orange, acc);
            } else if (k.StartsWith("toggle")) {
                DrawToggle(e.Graphics, acc, mi != null && mi.Checked, k == "toggle-locked");
            } else if (k.StartsWith("icon:")) {
                Ui.Glyph(e.Graphics, k.Substring(5), Ui.GlyphFont, it.Enabled ? Ui.Fg2(Light) : Ui.Fg3(Light), acc);
            }
        }

        // 켜짐 = 주황 트랙 + 오른쪽 흰 손잡이, 꺼짐 = 회색 트랙, 잠김 = 흐린 주황
        void DrawToggle(Graphics g, Rectangle area, bool on, bool locked) {
            float w = Ui.F(30), h = Ui.F(17);
            RectangleF r = new RectangleF(area.Right - w, area.Y + (area.Height - h) / 2f, w, h);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            Color trackOn = Color.FromArgb(locked ? 140 : 255, Ui.Orange);
            Color trackOff = Light ? Color.FromArgb(210, 210, 214) : Color.FromArgb(84, 84, 88);
            Ui.FillRound(g, on ? trackOn : trackOff, r, h / 2);
            float d = h - Ui.F(3);
            float x = on ? r.Right - d - Ui.F(1.5f) : r.X + Ui.F(1.5f);
            RectangleF knob = new RectangleF(x, r.Y + Ui.F(1.5f), d, d);
            using (SolidBrush shadow = new SolidBrush(Color.FromArgb(50, 0, 0, 0)))
                g.FillEllipse(shadow, new RectangleF(knob.X, knob.Y + Ui.F(0.7f), d, d));
            using (SolidBrush b = new SolidBrush(Color.FromArgb(locked ? 220 : 255, 255, 255, 255)))
                g.FillEllipse(b, knob);
        }
    }
}
'@

try {
    Add-Type -TypeDefinition $script:UiSource -ReferencedAssemblies System.Windows.Forms, System.Drawing -ErrorAction Stop
} catch {
    Write-Log "UI 코드 컴파일 실패: $($_.Exception.Message)"
    [System.Windows.Forms.MessageBox]::Show("트레이 UI를 불러오지 못했습니다.`n오류 기록: $script:LogPath", "ClaudeUsageBar") | Out-Null
    exit 1
}
[Cubr.Ui]::Init()   # DPI 인식은 창을 만들기 전에 켜야 한다
[System.Windows.Forms.Application]::EnableVisualStyles()

function Format-Reset($d) {
    if ($null -eq $d) { return "" }
    if ($d.Date -eq (Get-Date).Date) { return " · 리셋 {0:HH\:mm}" -f $d }
    return " · 리셋 {0:M\/d HH\:mm}" -f $d
}

# 카드용 리셋 문구 ("리셋 16:30")
function Format-ResetShort($d) {
    $s = Format-Reset $d
    if ($s) { return $s.Substring(3) }
    return ""
}

function Set-TrayIcon($icon) {
    $old = $notify.Icon
    $notify.Icon = $icon
    if ($old) { $old.Dispose() }
}

function Set-Tip([string]$tip) {
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 62) + "…" }  # NotifyIcon 툴팁 63자 제한
    $notify.Text = $tip
}

function Test-Stale {
    if ($null -eq $script:LastUpdate) { return $true }
    return ((Get-Date) - $script:LastUpdate).TotalSeconds -gt ((Get-RefreshSec) * 3 + 60)
}

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = [Cubr.TrayIcon]::MakeText("…", [System.Drawing.Color]::Gray)
$notify.Text = "Claude 사용량: 로딩 중"
$notify.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$script:renderer = New-Object Cubr.MenuRenderer
$menu.Renderer = $script:renderer
$menu.ShowImageMargin = $false
$menu.ShowCheckMargin = $false
$menu.Font = [Cubr.Ui]::MenuFont
$menu.Padding = New-Object System.Windows.Forms.Padding 0, ([Cubr.Ui]::S(4)), 0, ([Cubr.Ui]::S(4))
$notify.ContextMenuStrip = $menu

# 토글 줄을 눌렀을 때는 메뉴를 닫지 않는다 (MouseDown → Closing 순서로 온다)
$script:KeepOpen = $false
$menu.add_Closing({
    param($s, $e)
    if ($script:KeepOpen -and $e.CloseReason -eq [System.Windows.Forms.ToolStripDropDownCloseReason]::ItemClicked) {
        $e.Cancel = $true
    }
    $script:KeepOpen = $false
})
# 메뉴는 열 때마다 최신 상태로 다시 만든다
$menu.add_Opening({
    param($s, $e)
    Build-Menu
    $e.Cancel = $false
})
$menu.add_Opened({ [Cubr.Ui]::RoundCorners($menu.Handle) })

$script:ToggleItems = @{}

function New-Row([string]$text, [string]$tag, [int]$h = 28) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem $text
    $mi.Tag = $tag
    $mi.AutoSize = $false
    $mi.Size = New-Object System.Drawing.Size ([Cubr.Ui]::S(280)), ([Cubr.Ui]::S($h))
    [void]$menu.Items.Add($mi)
    return $mi
}

function Update-ToggleTags {
    $onCount = @($script:DisplayKeys | Where-Object { Get-Shown $_ }).Count
    foreach ($k in @($script:ToggleItems.Keys)) {
        $mi = $script:ToggleItems[$k]
        $on = Get-Shown $k
        $mi.Checked = $on
        $mi.Tag = if ($on -and $onCount -eq 1) { "toggle-locked" } else { "toggle" }
        $mi.Invalidate()
    }
}

function Toggle-Display([string]$key) {
    $on = -not (Get-Shown $key)
    if (-not $on -and @($script:DisplayKeys | Where-Object { Get-Shown $_ }).Count -le 1) { return } # 최소 한 줄
    Set-Shown $key $on
    Update-ToggleTags
    Update-Icon
}

function Update-Icon {
    $stale = Test-Stale
    $hasData = ($null -ne $script:LastWindows -and $script:LastWindows.Count -gt 0)
    if ($hasData) {
        $vals = New-Object System.Collections.Generic.List[double]
        $labs = New-Object System.Collections.Generic.List[string]
        foreach ($k in $script:DisplayKeys) {
            if (-not (Get-Shown $k)) { continue }
            $w = $script:LastWindows | Where-Object Key -eq $k | Select-Object -First 1
            if ($w) {
                $vals.Add([double]$w.Utilization)
                $labs.Add($(if ($k -eq "five_hour") { "5h" } else { "W" }))
            }
        }
        if ($vals.Count -eq 0) { $vals.Add([double]$script:LastWindows[0].Utilization); $labs.Add("") }
        # 갱신이 끊긴 채 옛 수치일 때는 회색으로 — 정상값처럼 보이지 않게
        $grey = [bool]($script:LastError -or $stale)
        Set-TrayIcon ([Cubr.TrayIcon]::MakeGauge($vals.ToArray(), $labs.ToArray(), $grey))
    } elseif ($script:LastError) {
        Set-TrayIcon ([Cubr.TrayIcon]::MakeText("!", [Cubr.Ui]::Orange))
    }
}

function Update-Tip {
    $stale = Test-Stale
    $hasData = ($null -ne $script:LastWindows -and $script:LastWindows.Count -gt 0)
    if ($script:LastError -and -not $hasData) {
        Set-Tip ("Claude 사용량 오류: " + $script:LastError)
    } elseif ($hasData) {
        $lines = foreach ($w in $script:LastWindows) {
            $label = $script:WindowLabels[$w.Key]; if (-not $label) { $label = $w.Key }
            "{0}: {1}%{2}" -f $label, [int][math]::Round($w.Utilization), (Format-Reset $w.ResetsAt)
        }
        $prefix = if ($script:LastError -or $stale) { "⚠ 갱신 끊김 (옛 값)`n" } else { "" }
        Set-Tip ($prefix + ($lines -join "`n"))
    }
}

function Build-Menu {
    $light = [Cubr.Ui]::AppsLight
    $script:renderer.Light = $light
    $menu.BackColor = [Cubr.Ui]::Bg($light)
    # 이전 항목(카드 컨트롤 포함)은 버리기 전에 해제
    $oldItems = @($menu.Items)
    $menu.Items.Clear()
    foreach ($i in $oldItems) { $i.Dispose() }

    # 상단 사용량 카드
    $card = New-Object Cubr.UsageCard
    $card.Light = $light
    $card.BackColor = [Cubr.Ui]::Bg($light)
    $card.Title = "Claude 사용량"
    $card.Error = $script:LastError
    if ($script:LastUpdate) {
        $fmt = if ($script:LastUpdate.Date -eq (Get-Date).Date) { "HH\:mm\:ss" } else { "M\/d HH\:mm" }
        $stale = Test-Stale
        $card.Stale = $stale
        $card.UpdateText = ("마지막 갱신 {0:$fmt}" -f $script:LastUpdate) + $(if ($stale) { " (오래된 값)" } else { "" })
    } else {
        $card.UpdateText = "갱신 대기 중"
    }
    if ($script:LastWindows) {
        foreach ($w in $script:LastWindows) {
            $label = $script:WindowLabels[$w.Key]; if (-not $label) { $label = $w.Key }
            $card.Rows.Add([Cubr.UsageRow]::new($label, [double]$w.Utilization, (Format-ResetShort $w.ResetsAt)))
        }
    }
    $card.Relayout([Cubr.Ui]::S(280))
    $cardHost = New-Object System.Windows.Forms.ToolStripControlHost $card
    $cardHost.AutoSize = $false
    $cardHost.Size = $card.Size
    $cardHost.Margin = [System.Windows.Forms.Padding]::Empty
    $cardHost.Padding = [System.Windows.Forms.Padding]::Empty
    [void]$menu.Items.Add($cardHost)
    [void]$menu.Items.Add("-")

    # 트레이 표시 토글
    $h = New-Row "트레이 표시" "header" 24; $h.Enabled = $false
    $script:ToggleItems = @{}
    foreach ($opt in @(@{k = "five_hour"; l = "5시간 (5h)"}, @{k = "seven_day"; l = "주간 (W)"})) {
        $mi = New-Row $opt.l "toggle" 30
        $mi.Name = $opt.k
        $mi.add_MouseDown({ $script:KeepOpen = $true })
        $mi.add_Click({ Toggle-Display $this.Name })
        $script:ToggleItems[$opt.k] = $mi
    }
    Update-ToggleTags
    [void]$menu.Items.Add("-")

    # 갱신 주기
    $h = New-Row "갱신 주기" "header" 24; $h.Enabled = $false
    foreach ($opt in @(@{s = 60; l = "1분"}, @{s = 120; l = "2분"}, @{s = 180; l = "3분"})) {
        $mi = New-Row $opt.l "check"
        $mi.Name = [string]$opt.s
        $mi.Checked = ((Get-RefreshSec) -eq $opt.s)
        $mi.add_Click({
            $sec = [int]$this.Name
            Set-RefreshSec $sec
            $script:timer.Interval = $sec * 1000
        })
    }
    [void]$menu.Items.Add("-")

    # 동작 — 아이콘은 오른쪽 (Segoe MDL2: 문서 E8A5, 새로 고침 E72C, 전원 E7E8)
    $log = New-Row "오류 기록 열기" ("icon:" + [char]0xE8A5)
    $log.add_Click({ if (Test-Path $script:LogPath) { Start-Process notepad.exe $script:LogPath } else { [System.Windows.Forms.MessageBox]::Show("아직 기록된 오류가 없습니다.", "ClaudeUsageBar") | Out-Null } })
    $refresh = New-Row "지금 갱신" ("icon:" + [char]0xE72C)
    $refresh.add_Click({ Update-Usage })
    $exit = New-Row "종료" ("icon:" + [char]0xE7E8)
    $exit.add_Click({
        $script:timer.Stop()
        $notify.Visible = $false
        [System.Windows.Forms.Application]::Exit()
    })
}

function Render-State {
    Update-Icon
    Update-Tip
    # 열려 있는 메뉴를 갈아엎지 않는다 — 다음에 열 때 Opening에서 다시 만든다
    if (-not $menu.Visible) { Build-Menu }
}

function Update-Usage {
    try {
        $windows = @(Get-Usage)
        if ($windows.Count -eq 0) { throw "사용량 데이터 없음" }
        $script:LastWindows = $windows
        $script:LastUpdate  = Get-Date
        $script:LastError   = $null
    }
    catch {
        $script:LastError = $_.Exception.Message
        Write-Log "오류: $($script:LastError)"
    }
    Render-State
}

$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = (Get-RefreshSec) * 1000
$script:timer.add_Tick({ Update-Usage })
$script:timer.Start()

Write-Log "시작 (갱신 주기 $(Get-RefreshSec)초)"
Update-Usage
[System.Windows.Forms.Application]::Run()
