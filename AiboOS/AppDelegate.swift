import UIKit
import WebKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate, WKNavigationDelegate, WKUIDelegate {
    var window: UIWindow?
    private var webView: WKWebView!

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.allowsInlineMediaPlayback = true
        let web = WKWebView(frame: UIScreen.main.bounds, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.allowsBackForwardNavigationGestures = false
        let vc = UIViewController()
        vc.view.backgroundColor = .black
        vc.view.addSubview(web)
        web.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
          web.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
          web.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
          web.topAnchor.constraint(equalTo: vc.view.topAnchor),
          web.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor)
        ])
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = vc
        w.makeKeyAndVisible()
        window = w
        webView = web
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            let label = UILabel(frame: vc.view.bounds)
            label.text = "AiboOS assets missing"
            label.textColor = .white
            label.textAlignment = .center
            vc.view.addSubview(label)
        }
        return true
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        switch (url.scheme ?? "").lowercased() {
        case "file", "about", "blob", "data":
            decisionHandler(.allow)
        case "sileo":
            decisionHandler(.cancel)
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        case "http", "https":
            if action.targetFrame?.isMainFrame == true {
                decisionHandler(.cancel)
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            } else {
                decisionHandler(.allow)
            }
        default:
            decisionHandler(.cancel)
        }
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
      initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let vc = window?.rootViewController else { completionHandler(); return }
        let alert = UIAlertController(title: "AiboOS", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        vc.present(alert, animated: true)
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
      initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let vc = window?.rootViewController else { completionHandler(false); return }
        let alert = UIAlertController(title: "AiboOS", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        vc.present(alert, animated: true)
    }
}