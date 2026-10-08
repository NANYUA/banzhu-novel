import Foundation
import WebKit

/// 自动验证器：用离屏 WKWebView 执行挑战脚本并写入 Cookie。
/// 支持并发调用（复用同一个 Task）。超时或需要手动操作时返回 false。
@MainActor
final class GuardResolver: NSObject {
    static let shared = GuardResolver()

    private var webView: WKWebView?
    private var inFlight: Task<Bool, Never>?

    /// 尝试自动验证。返回是否成功。并发调用会复用同一个任务。
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
        html.contains("guard") || html.contains("slider_html")
            || html.contains("向右滑动") || html.contains("slide.js")
    }

    /// 模拟人手拖动滑块：19 步 smoothstep 轨迹 + 随机间隔，
    /// 让盾脚本 slide.js 收集到接近真人的 move_arr 后自动 reload。
    private static let autoSlideJS = """
    (function(){
      try{
        if(!document.cookie.match(/guard=/)){ return 'no-guard'; }
        var btn=document.getElementById('btn');
        var slider=document.getElementById('slider');
        if(!btn||!slider){ return 'no-slider'; }
        var br=btn.getBoundingClientRect();
        var sx=Math.round(br.x+br.width/2);
        var sy=Math.round(br.y+br.height/2);
        var max=slider.clientWidth-btn.offsetWidth;
        var total=max+5;
        function wait(ms){
          var start=performance.now();
          while(performance.now()-start<ms){}
        }
        btn.dispatchEvent(new MouseEvent('mousedown',{
          clientX:sx,clientY:sy,bubbles:true,cancelable:true
        }));
        wait(50);
        var previous=sx;
        var steps=19;
        for(var i=1;i<=steps;i++){
          var progress=i/steps;
          var smooth=progress*progress*(3-2*progress);
          var x=Math.round(sx+total*smooth+(Math.random()*4-2));
          if(i<steps&&x>sx+max-3){ x=sx+max-3; }
          if(x<=previous){ x=previous+1; }
          var y=Math.round(Math.random()*5-2.5);
          document.documentElement.dispatchEvent(new MouseEvent('mousemove',{
            clientX:x,clientY:sy+y,bubbles:true,cancelable:true
          }));
          previous=x;
          wait(13+Math.round(Math.random()*6));
        }
        document.documentElement.dispatchEvent(new MouseEvent('mouseup',{
          clientX:sx+max+3,clientY:sy+1,bubbles:true,cancelable:true
        }));
        return 'drag-started';
      }catch(err){
        return 'err:'+err;
      }
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
