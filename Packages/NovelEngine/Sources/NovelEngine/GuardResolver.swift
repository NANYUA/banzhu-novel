import Foundation
import WebKit

// ⚠️ `GuardState` 已从本文件移出（2026-10-05，T5 架构约束校验时发现）。
//
// 原因：它带 `ObservableObject` / `@Published`，是**状态管理**，而 D2 已定状态管理
// 归 Core 层（TCA）。而且它承载的 `showManual`（要不要弹手动验证页）、
// `reloadToken`（通知界面重载）都是**纯 UI 语义**，泄漏进了引擎层。
//
// 现拆分结果：
//   Engine：GuardResolver 只回答「过盾成功与否」
//   Core  ：过盾状态 → `NovelCore.GuardState`（后续改为 TCA 状态）
//
// `import Combine` 也随之移除——引擎层不应引入任何状态管理框架。

/// 自动过盾器：用一个离屏 WKWebView 加载站点，让 `_guard` 挑战脚本在真实浏览器环境里
/// 自动计算并写入 Cookie（加速乐/JSL 类盾通常执行 JS 即可通过，无需真正拖滑块）。
/// 过盾后把 Cookie 同步进 HTTPCookieStorage.shared 供 URLSession 复用。
/// 若超时仍停在盾页（需要真正手动拖滑块），返回 false。
@MainActor
final class GuardResolver: NSObject {
    static let shared = GuardResolver()

    private var webView: WKWebView?
    private var inFlight: Task<Bool, Never>?

    /// 尝试自动过盾。返回是否成功。并发调用会复用同一个任务。
    func autoPass(urlString: String) async -> Bool {
        if let task = inFlight { return await task.value }
        let task = Task { await run(urlString: urlString) }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }

    private func run(urlString: String) async -> Bool {
        guard let url = URL(string: urlString) else { return false }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        web.customUserAgent = SiteConfig.userAgent
        self.webView = web

        var req = URLRequest(url: url)
        req.setValue(SiteConfig.userAgent, forHTTPHeaderField: "User-Agent")
        web.load(req)

        var dragInjected = false
        // 轮询最多 ~15s：等挑战脚本执行/模拟拖动完成、页面不再是盾页
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let html = await currentHTML(web)
            if isGuardPage(html) {
                // 盾页：注入一次模拟滑动，自动拖到底触发校验
                if !dragInjected {
                    dragInjected = true
                    _ = await evaluate(web, js: Self.autoSlideJS)
                }
                continue
            }
            if html.count > 300 {
                await syncCookies(from: web)
                cleanup()
                return true
            }
        }
        await syncCookies(from: web)
        cleanup()
        return false
    }

    private func currentHTML(_ web: WKWebView) async -> String {
        await evaluate(web, js: "document.documentElement.outerHTML") ?? ""
    }

    private func evaluate(_ web: WKWebView, js: String) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            web.evaluateJavaScript(js) { result, _ in
                cont.resume(returning: result as? String)
            }
        }
    }

    private func isGuardPage(_ html: String) -> Bool {
        html.contains("_guard") || html.contains("slider_html")
            || html.contains("向右滑动") || html.contains("slide.js")
    }

    /// 模拟人手拖动滑块：从左到底分多步派发 mousedown→mousemove…→mouseup，
    /// 让盾脚本 slide.js 收集到 move_arr 轨迹并计算 guardret cookie 后自动 reload。
    private static let autoSlideJS = """
    (function(){
      try{
        var btn=document.getElementById('btn');
        var slider=document.getElementById('slider');
        if(!btn||!slider){ return 'no-slider'; }
        var max=slider.offsetWidth-btn.offsetWidth;
        var startX=100, y=30;
        function fire(type,x){
          var e=new MouseEvent(type,{bubbles:true,cancelable:true,clientX:x,clientY:y,view:window});
          (type==='mousedown'?btn:document).dispatchEvent(e);
        }
        fire('mousedown',startX);
        var steps=18, i=0;
        var timer=setInterval(function(){
          i++;
          var x=startX+Math.round(max*i/steps);
          if(i>=steps){ x=startX+max; }
          fire('mousemove',x);
          if(i>=steps){
            clearInterval(timer);
            fire('mouseup',startX+max);
          }
        },30);
        return 'drag-started';
      }catch(err){ return 'err:'+err; }
    })();
    """

    private func syncCookies(from web: WKWebView) async {
        let cookies = await web.configuration.websiteDataStore.httpCookieStore.allCookiesAsync()
        for c in cookies { HTTPCookieStorage.shared.setCookie(c) }
    }

    private func cleanup() {
        webView?.stopLoading()
        webView = nil
    }
}

extension WKHTTPCookieStore {
    func allCookiesAsync() async -> [HTTPCookie] {
        await withCheckedContinuation { cont in
            getAllCookies { cont.resume(returning: $0) }
        }
    }
}
