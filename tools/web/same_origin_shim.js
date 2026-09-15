// 把游戏里写死的明文 HTTP 地址改写成同源相对路径。部署时由 tools/deploy_web.sh 注入
// 到 index.html 的 <head> 里，**在 Godot 引擎脚本之前**跑。
//
// ## 为什么需要它
//
// 游戏里有两处地址写死成 http://124.221.78.13/cellwar/：
//   · boot.gd 的热更 manifest（SELF_HOST）
//   · feedback.gd 的反馈口
//
// 网页版必须跑在 https:// 下，而浏览器会把 HTTPS 页面发出的 http:// 请求当**混合内容**
// 直接拦掉，并给整个页面标上「不安全」。上线当天 Kevin 第一句话就是这个。
//
// ## 为什么不直接改那两个地址
//
// 改 SELF_HOST 要动 boot.gd。**boot.gd 在挂载补丁之前就被读了，所以它热更不了** ——
// 动它就必须走一次全量发版，而且从那一刻起到发版为止，桌面端的补丁打包器会整个拒绝出包
// （build_patch.gd 的闸）。Kevin：能不能不动客户端、只动网页端的发版。能——就是这个文件。
//
// ## 改写到哪
//
// 改成同源相对路径 /cellwar/...，由 nginx 的 cellwar.jiling.chat 块接住：
//   · /cellwar/latest.json(.sig) → **故意 404**。网页版不需要热更（重新部署静态文件就是更新），
//     而且让它装桌面补丁反而危险：补丁按桌面基线打，可能把网页包里更新的脚本盖回旧的。
//     取不到 manifest，boot.gd 就当「没有更新」**立刻**进游戏 —— 连那 10 秒查更新预算都省了。
//   · /cellwar/feedback → 代理到本机 8612。这条不只是消警告：网页版的反馈**本来发不出去**
//     （被混合内容拦着），现在能用了。
//
// ## 脆在哪（写给下一个人）
//
// 这是个**运行时猴补丁**，赌的是 Godot 的 web 版 HTTPRequest 走 fetch/XHR。
// 4.5 是这样；哪天引擎换了实现，这里会**静默失效**（页面又变回「不安全」）。
// 正经的修法仍然是改 boot.gd 的 SELF_HOST，随下一次全量发版做掉，然后删掉这个文件。
(function () {
	var OLD = 'http://124.221.78.13/cellwar/';
	var NEW = '/cellwar/';

	function fix(u) {
		return (typeof u === 'string' && u.indexOf(OLD) === 0) ? NEW + u.slice(OLD.length) : u;
	}

	var origFetch = window.fetch;
	if (origFetch) {
		window.fetch = function (input, init) {
			if (typeof input === 'string') {
				input = fix(input);
			} else if (input && typeof input.url === 'string' && input.url.indexOf(OLD) === 0) {
				input = new Request(fix(input.url), input);
			}
			return origFetch.call(this, input, init);
		};
	}

	// Godot 某些路径走 XHR 而不是 fetch，一并接住（多这十行，省掉一次「怎么又不灵了」）
	var origOpen = XMLHttpRequest.prototype.open;
	XMLHttpRequest.prototype.open = function (method, url) {
		var args = Array.prototype.slice.call(arguments);
		args[1] = fix(url);
		return origOpen.apply(this, args);
	};
})();
