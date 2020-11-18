#!/usr/bin/swift sh

// MARK: - Imports

import AppKit
import WebKit

import SwiftSoup // @scinfu

// MARK: - AppKit Hook

let app = NSApplication.shared

class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {

    let window: NSWindow = .init(
        contentRect: NSMakeRect(0.0, 0.0, 960.0, 540.0),
        styleMask: [.titled, .resizable],
        backing: .buffered,
        defer: false,
        screen: nil
    )

    private let webView: WKWebView = .init()

    private lazy var script: Script = .init(webView: self.webView)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Uncomment this out and run the script ONCE to show the stupid PlayStation store CAPTCHA
        // thing. Once you complete that once, you can comment this out, it will grab the correct
        // product page HTML from then on.
        self.window.makeKeyAndOrderFront(nil)

        self.webView.frame = self.window.contentView?.bounds ?? .zero
        self.webView.autoresizingMask = [.width, .height]
        self.webView.navigationDelegate = self

        self.window.contentView?.addSubview(self.webView)

        self.script.run()
    }

}

let delegate = AppDelegate()
app.delegate = delegate

// MARK: - Script

class Script: NSObject {

    // MARK: - Nested Types

    fileprivate enum ExitStatus: CustomStringConvertible {

        case success
        case error(Int32)

        static var generalError: Self { .error(1) }

        var exitCode: Int32 {
            switch self {
            case .success: return 0
            case let .error(code): return code
            }
        }

        var description: String {
            switch self {
            case .success:
                return "[SUCCESS] (0)"
            case let .error(code):
                return "[ERROR] (\(code))"
            }
        }

    }

    // MARK: - Properties

    let webView: WKWebView

    private var productPageUrl: URL = . init(fileURLWithPath: "")  // Placeholder for non-optional URL
    private var successiveCAPTCHACount: Int = 0

    // Exclude the bigass 21MB video file the page automatically loads...
    static private let blockRules =
        """
        [{
            "trigger": {
                "url-filter": ".*",
                "resource-type": ["media"]
            },
            "action": {
                "type": "block"
            }
        }]
        """

    // MARK: - Initialization

    init(webView: WKWebView) {
        self.webView = webView

        super.init()

        self.configureWebView()
    }

    private func configureWebView() {
        self.webView.navigationDelegate = self

        WKContentRuleListStore.default()?.compileContentRuleList(
            forIdentifier: "com.cifilter.PSHigh5.ContentRuleList",
            encodedContentRuleList: Self.blockRules,
            completionHandler: { [weak self] contentRuleList, error in
                guard let self = self else { return }
                guard let contentRuleList = contentRuleList else {
                    self.exitWith(.generalError, error?.localizedDescription ?? nil)
                }

                self.webView.configuration.userContentController.add(contentRuleList)
            }
        )
    }

    // MARK: - Script Execution

    func run() {
        guard let url = URL.PS5.next() else {
            self.exitWith(.generalError, "Invalid product page URL.")
        }

        self.productPageUrl = url

        let urlRequest = URLRequest(url: url)
        self.webView.load(urlRequest)
    }

    // Taken from https://stackoverflow.com/a/59957764/89170
    @discardableResult private func shell(_ command: String) -> (String?, Int32) {
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", command]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.launch()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)
        task.waitUntilExit()
        return (output, task.terminationStatus)
    }

    fileprivate func evaluateLoadedHTML() {
        self.webView.evaluateJavaScript(
            "document.documentElement.outerHTML.toString()",
            completionHandler: { [weak self] (html: Any?, error: Error?) in
                guard let self = self else { return }
                guard let html = html as? String else {
                    self.exitWith(.generalError, error?.localizedDescription ?? nil)
                }

                guard html.count > 1000 else {
                    if self.successiveCAPTCHACount == 0 {
                        self.log("Product page CAPTCHA detected! Attempting to subvert it...")
                    } else {
                        self.log("\u{7}Couldn't subvert CAPTCHA...")
                        self.log("Product page CAPTCHA detected! Solve it, then press Enter:")
                        DispatchQueue.global(qos: .background).async {
                            _ = readLine(strippingNewline: false)
                            DispatchQueue.main.async { self.run() }
                        }
                    }

                    self.successiveCAPTCHACount += 1
                    return
                }

                self.successiveCAPTCHACount = 0

                do {
                    let document = try SwiftSoup.parse(html)
                    if self.heroProductIsInStock(in: document) {
                        self.log("\u{7}PS5 is in stock! 🥳")
                        self.log("Product page URL: \(self.productPageUrl.absoluteString)")

                        DispatchQueue.global().async {
                            self.shell("`which afplay` -v 2 `pwd`/success.m4a")
                            self.exitWith(.success)
                        }
                    } else {
                        self.log("PS5 is sold out... 😡")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.run() }
                    }
                } catch {
                    self.exitWith(.generalError, error.localizedDescription)
                }
            }
        )
    }

    private func heroProductIsInStock(in document: Document) -> Bool {
        let addToCartButtonIsVisible =
            try? document
            .select("div.productHero-info div.button-placeholder button.add-to-cart")
            .first()
            .map { !$0.hasClass("hide") }

        return addToCartButtonIsVisible ?? false
    }

    fileprivate func log(_ message: String) {
        print("[LOG]:", message)
    }

    fileprivate func exitWith(_ status: ExitStatus, _ message: String? = nil) -> Never {
        let output: String = ["\(status)", message].compactJoined(separator: ": ")

        print(output)
        exit(status.exitCode)
    }

}

app.run()

// MARK: - Web View Navigation Delegate

extension Script: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        self.log("Began loading product page.")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.log("Finished loading product page.")
        self.evaluateLoadedHTML()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        self.exitWith(.generalError, "Web view content process was terminated!")
    }

}

// MARK: - Utilities

private extension Array where Element == String? {

    func compactJoined(separator: String) -> String {
        return self.compactMap { $0 }.joined(separator: separator)
    }

}

private extension URL {

    // For testing product page DOM scraping
    struct PS4 {

        static let pro: URL? = URL(
            string: "https://direct.playstation.com/en-us/consoles/console/" +
            "playstation-4-pro-1tb-console.3003346"
        )

    }

    struct PS5 {

        private static let all: [URL?] = [PS5.disc, PS5.digital]
        private static var nextIndex: Int = 0

        static let disc: URL? = URL(
            string: "https://direct.playstation.com/en-us/consoles/console/" +
            "playstation5-console.3005816"
        )

        static let digital: URL? = URL(
            string: "https://direct.playstation.com/en-us/consoles/console/" +
            "playstation5-digital-edition-console.3005817"
        )

        static func next() -> URL? {
            Self.nextIndex = (Self.nextIndex + 1) % Self.all.count
            return Self.all[Self.nextIndex]
        }

    }

}
