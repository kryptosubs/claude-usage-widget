// ai-usage dashboard. Plain DOM, no libraries, no inline styles (the server's CSP forbids them).
(function () {
  "use strict";

  var lang = "zh";
  try { var saved = localStorage.getItem("aiu-lang"); if (saved === "en" || saved === "zh") lang = saved; } catch (e) {}
  var data = null, lastError = null;

  function T(en, zh) { return lang === "zh" ? zh : en; }

  // ---------- DOM helpers
  function h(tag, props) {
    var el = document.createElement(tag);
    props = props || {};
    if (props.cls) el.className = props.cls;
    if (props.text != null) el.textContent = props.text;
    if (props.style) for (var k in props.style) el.style[k] = props.style[k];
    if (props.attrs) for (var a in props.attrs) el.setAttribute(a, props.attrs[a]);
    for (var i = 2; i < arguments.length; i++) add(el, arguments[i]);
    return el;
  }
  function add(el, c) {
    if (c == null || c === false) return;
    if (Array.isArray(c)) { c.forEach(function (x) { add(el, x); }); return; }
    el.appendChild(typeof c === "string" || typeof c === "number" ? document.createTextNode(String(c)) : c);
  }
  var SVGNS = "http://www.w3.org/2000/svg";
  function s(tag, attrs) {
    var el = document.createElementNS(SVGNS, tag);
    for (var k in attrs || {}) el.setAttribute(k, attrs[k]);
    for (var i = 2; i < arguments.length; i++) add(el, arguments[i]);
    return el;
  }
  function clear(id) { var el = document.getElementById(id); while (el.firstChild) el.removeChild(el.firstChild); return el; }

  // ---------- formatting
  function d(x) { return x ? new Date(x) : null; }
  function pct(v) { return v == null ? "–" : (Math.round(v * 10) / 10).toString().replace(/\.0$/, "") + "%"; }
  function tokens(n) {
    if (n == null) return "–";
    if (lang === "zh") {
      if (n >= 1e8) return (n / 1e8).toFixed(2) + " 億";
      if (n >= 1e4) return (n / 1e4).toFixed(n >= 1e6 ? 0 : 1) + " 萬";
      return String(n);
    }
    if (n >= 1e6) return (n / 1e6).toFixed(n >= 1e8 ? 0 : 1) + "M";
    if (n >= 1e3) return (n / 1e3).toFixed(n >= 1e5 ? 0 : 1) + "K";
    return String(n);
  }
  function gb(b) { return b == null ? "–" : (b / 1073741824).toFixed(b >= 1e10 ? 0 : 1) + " GB"; }
  function dur(ms) {
    if (ms <= 0) return T("now", "現在");
    var m = Math.ceil(ms / 60000), dd = Math.floor(m / 1440), hh = Math.floor((m % 1440) / 60), mm = m % 60;
    if (dd) return T(dd + "d " + hh + "h", dd + " 天 " + hh + " 小時");
    if (hh) return T(hh + "h " + mm + "m", hh + " 小時 " + mm + " 分");
    return T(mm + "m", mm + " 分");
  }
  function inT(x) { var t = d(x); if (!t) return ""; return T("in " + dur(t - Date.now()), dur(t - Date.now()) + "後"); }
  function agoT(sec) {
    if (sec == null) return "";
    if (sec < 90) return T("just now", "剛剛");
    return T(dur(sec * 1000) + " ago", dur(sec * 1000) + "前");
  }
  function clock(x, withDay) {
    var t = d(x); if (!t) return "";
    var o = { hour: "numeric", minute: "2-digit" };
    if (withDay) o.weekday = "short";
    return new Intl.DateTimeFormat(lang === "zh" ? "zh-TW" : "en-US", o).format(t);
  }
  function dayLabel(iso, short) {
    var t = new Date(iso + "T12:00:00");
    return new Intl.DateTimeFormat(lang === "zh" ? "zh-TW" : "en-US", short ? { weekday: "narrow" } : { weekday: "short", month: "numeric", day: "numeric" }).format(t);
  }
  function sevColor(p, severity) {
    var r = p >= 90 ? 2 : p >= 75 ? 1 : 0;
    var sv = (severity || "").toLowerCase();
    if (/warn|elevated|medium/.test(sv)) r = Math.max(r, 1);
    if (/critical|severe|high|exceeded|blocked|locked/.test(sv)) r = 2;
    return r === 2 ? "var(--near)" : r === 1 ? "var(--watch)" : "var(--claude)";
  }
  function limitLabel(key) {
    if (key === "session") return T("5-hour session", "5 小時工作階段");
    if (key === "weekly_all") return T("Weekly, all models", "每週（全部模型）");
    if (key === "spend") return T("Extra usage", "額外用量");
    if (key.indexOf("weekly_scoped:") === 0) return T("Weekly · ", "每週 · ") + key.slice(14);
    return key.replace(/_/g, " ");
  }

  function meter(fillPct, color, projPct, tickPct) {
    var m = h("div", { cls: "meter", attrs: { role: "img", "aria-label": pct(fillPct) } });
    if (projPct != null && projPct > fillPct) add(m, h("div", { cls: "proj", style: { width: Math.min(100, projPct) + "%" } }));
    add(m, h("div", { cls: "fill", style: { width: Math.max(0.8, Math.min(100, fillPct)) + "%", background: color } }));
    if (tickPct != null) add(m, h("div", { cls: "tick", style: { left: "calc(" + Math.min(100, tickPct) + "% - 1px)" } }));
    return m;
  }

  // ---------- sections
  function renderHeader() {
    document.documentElement.lang = lang === "zh" ? "zh-Hant" : "en";
    document.getElementById("title").textContent = T("Personal AI usage", "個人 AI 用量");
    var gen = data && data.generated_at ? clock(data.generated_at, true) : "";
    document.getElementById("sub").textContent = T("Mac Studio · updated ", "Mac Studio · 更新於 ") + gen;
    var f = document.getElementById("fresh"), c = data && data.claude;
    var st = lastError ? "offline" : c && c.available ? c.status : "missing";
    var map = {
      live: ["ok", T("Claude: live", "Claude：即時")], stale: ["warn", T("Claude: stale", "Claude：資料過期")],
      throttled: ["warn", T("Claude: throttled", "Claude：限流中")], offline: ["warn", T("Claude: offline", "Claude：離線")],
      auth: ["bad", T("Claude: sign in again", "Claude：需重新登入")], no_login: ["bad", T("Claude: no login", "Claude：未登入")],
      missing: ["bad", T("Claude: no feed", "Claude：沒有資料")], loading: ["warn", T("Claude: loading", "Claude：載入中")]
    };
    var m = map[st] || ["warn", st];
    f.className = "pill " + m[0];
    f.textContent = m[1] + (c && c.age_seconds != null && st !== "missing" ? " · " + agoT(c.age_seconds) : "");
    document.getElementById("l-zh").setAttribute("aria-pressed", lang === "zh");
    document.getElementById("l-en").setAttribute("aria-pressed", lang === "en");
  }

  function renderTop() {
    var top = clear("top"), c = data.claude || {}, w = c.weekly, o = data.ollama || {};
    var hero = h("div", { cls: "hero" });
    add(hero, h("span", { cls: "eyebrow", text: T("Claude Pro · weekly limit", "Claude Pro · 每週額度") }));
    if (!c.available || !w) {
      add(hero, h("h2", { text: T("Claude limits aren't flowing in yet", "Claude 額度資料還沒進來") }));
      add(hero, h("p", { text: T("The Claude Usage menu-bar app (v1.3 or later) writes them every 3 minutes. Update it with ./build.sh --install, and make sure Claude Code is signed in on this Mac.",
        "Claude Usage 選單列 App（v1.3 以上）每 3 分鐘寫入一次。用 ./build.sh --install 更新，並確認這台 Mac 上的 Claude Code 已登入。") }));
    } else {
      var head, body;
      if (w.verdict === "capped") {
        head = T("Weekly cap used up. Resets " + clock(w.reset, true), "每週額度已用完，" + clock(w.reset, true) + " 重置");
      } else if (w.verdict === "over") {
        head = T("At this pace the weekly cap runs out " + clock(w.projected_hit, true), "照這速度，每週額度會在" + clock(w.projected_hit, true) + "用完");
      } else {
        head = T("On pace: the week ends near " + pct(w.projected_at_reset), "速度正常：本週預計收在 " + pct(w.projected_at_reset));
      }
      add(hero, h("h2", { text: head }));
      add(hero, h("div", { cls: "meterlabel" },
        h("span", { text: T("resets ", "重置：") + clock(w.reset, true) }),
        h("span", { text: pct(w.percent) + T(" used", " 已用") })));
      add(hero, meter(w.percent, w.percent >= 90 ? "#F0727B" : w.percent >= 75 ? "#F0A52B" : "#7FA6FF", w.projected_at_reset, w.pace_percent));
      add(hero, h("div", { cls: "legend" },
        h("span", { text: T("Solid: used · hatched: projected to the reset", "實心：已用 · 斜紋：推估到重置") }),
        h("span", { text: T("White tick: even pace (" + pct(w.pace_percent) + ")", "白線：平均速度（" + pct(w.pace_percent) + "）") })));
      body = w.rate_per_day != null
        ? T("Running at " + pct(w.rate_per_day) + " a day; " + pct(w.sustainable_per_day) + " a day lasts the week.",
            "目前每天 " + pct(w.rate_per_day) + "，撐滿一週的速度是每天 " + pct(w.sustainable_per_day) + "。")
        : T("Not enough history yet to measure the pace.", "歷史資料還不夠，暫時算不出速度。");
      add(hero, h("p", { text: body }));
      var act;
      if (w.verdict === "over" || w.verdict === "capped") {
        act = T("Move batch work (summaries, Small Biz workers, scans) to " + (o.backup || "Ollama") + " on the Mac Studio until the reset.",
          "重置前把批次工作（摘要、Small Biz 工作代理、掃描）改跑 Mac Studio 上的 " + (o.backup || "Ollama") + "。");
      } else if (c.session && c.session.percent >= 80) {
        act = T("The 5-hour window is at " + pct(c.session.percent) + ". It resets " + inT(c.session.reset) + ".",
          "5 小時窗口已到 " + pct(c.session.percent) + "，" + inT(c.session.reset) + "重置。");
      } else {
        act = T("Nothing to change. You have room this week.", "不用調整，本週還有餘裕。");
      }
      add(hero, h("div", { cls: "action" }, h("span", { text: "→" }), h("span", { text: act })));
    }
    add(top, hero);

    var side = h("div", { cls: "side" });
    var se = c.session;
    var sc = h("div", { cls: "card" }, h("span", { cls: "eyebrow", text: T("5-hour session", "5 小時工作階段") }));
    if (se) {
      add(sc, h("div", { cls: "meterlabel" }, h("span", { cls: "big", text: pct(se.percent), style: { color: sevColor(se.percent) } }),
        h("span", { cls: "muted", text: T("resets ", "") + inT(se.reset) + T("", "重置") })));
      add(sc, meter(se.percent, sevColor(se.percent), null, se.pace_percent));
    } else add(sc, h("span", { cls: "muted", text: T("No data yet", "尚無資料") }));
    add(side, sc);

    var cc = data.claude_code || {}, ccTotal = (cc.projects || []).reduce(function (a, p) { return a + p.tokens; }, 0);
    var top1 = (cc.projects || [])[0];
    add(side, h("div", { cls: "card" },
      h("span", { cls: "eyebrow", text: T("Claude Code this week", "本週 Claude Code") }),
      h("div", { cls: "meterlabel" }, h("span", { cls: "big", text: tokens(ccTotal) }),
        h("span", { cls: "muted", text: T("tokens", "token") })),
      h("span", { cls: "muted", text: top1 ? T("Most: " + top1.name + " (" + Math.round(top1.tokens / Math.max(1, ccTotal) * 100) + "%)", "最多：" + top1.name + "（" + Math.round(top1.tokens / Math.max(1, ccTotal) * 100) + "%）") : T("No sessions yet this week", "本週還沒有工作階段") })));

    var req = o.requests || [], today = req.length ? req[req.length - 1].requests : 0, week = req.reduce(function (a, r) { return a + r.requests; }, 0);
    add(side, h("div", { cls: "card" },
      h("span", { cls: "eyebrow", text: T("Ollama on the Mac Studio", "Mac Studio 上的 Ollama") }),
      h("div", { cls: "meterlabel" }, h("span", { cls: "big", text: String(today), style: { color: "var(--local)" } }),
        h("span", { cls: "muted", text: T("requests today · " + week + " this week", "今天請求數 · 本週 " + week) })),
      h("span", { cls: "muted", text: !o.reachable ? T("Ollama isn't answering on " + o.url, "Ollama 在 " + o.url + " 沒有回應")
        : (o.loaded || []).length ? T("In memory: ", "常駐：") + o.loaded.map(function (m) { return m.name; }).join(", ")
        : T("No model in memory right now", "目前沒有模型常駐") })));
    add(top, side);
  }

  function weekChart(w) {
    var W = 640, H = 250, L = 38, R = 14, Tp = 14, B = 28;
    var t0 = d(w.window_start).getTime(), t1 = d(w.reset).getTime(), now = d(data.generated_at).getTime();
    function x(t) { return L + (t - t0) / (t1 - t0) * (W - L - R); }
    function y(p) { return Tp + (1 - Math.min(110, p) / 100) * (H - Tp - B); }
    var svg = s("svg", { viewBox: "0 0 " + W + " " + H, role: "img", "aria-label": T("Weekly usage against even pace", "每週用量與平均速度") });
    [0, 25, 50, 75, 100].forEach(function (p) {
      add(svg, s("line", { x1: L, x2: W - R, y1: y(p), y2: y(p), "class": p === 100 ? "capline" : "axis" }));
      add(svg, s("text", { x: L - 6, y: y(p) + 4, "text-anchor": "end" }, p + "%"));
    });
    for (var i = 0; i <= 7; i++) {
      var t = t0 + i * 86400000;
      add(svg, s("line", { x1: x(t), x2: x(t), y1: H - B, y2: H - B + 4, "class": "axis" }));
      if (i < 7) add(svg, s("text", { x: x(t + 43200000), y: H - 8, "text-anchor": "middle" },
        new Intl.DateTimeFormat(lang === "zh" ? "zh-TW" : "en-US", { weekday: "short" }).format(new Date(t + 43200000))));
    }
    add(svg, s("line", { x1: x(t0), y1: y(0), x2: x(t1), y2: y(100), "class": "paceline" }));
    var pts = (w.series || []).map(function (p) { return [x(d(p.t).getTime()), y(p.p)]; });
    if (pts.length) {
      var dline = "M" + pts.map(function (p) { return p[0].toFixed(1) + " " + p[1].toFixed(1); }).join(" L");
      add(svg, s("path", { d: dline + " L" + pts[pts.length - 1][0].toFixed(1) + " " + y(0) + " L" + pts[0][0].toFixed(1) + " " + y(0) + " Z", "class": "usedarea" }));
      add(svg, s("path", { d: dline, "class": "used" }));
      var last = pts[pts.length - 1];
      if (w.rate_per_hour != null && w.percent < 100) {
        var endT = w.projected_hit ? d(w.projected_hit).getTime() : t1;
        var endP = w.projected_hit ? 100 : w.projected_at_reset;
        add(svg, s("line", { x1: last[0], y1: last[1], x2: x(endT), y2: y(endP), "class": "projline" }));
        if (w.projected_hit) {
          add(svg, s("circle", { cx: x(endT), cy: y(100), r: 4, fill: "var(--near)" }));
          add(svg, s("text", { x: Math.min(x(endT), W - R - 4), y: y(100) - 8, "text-anchor": "end", fill: "var(--near)" }, T("out ", "用完 ") + clock(w.projected_hit, true)));
        }
      }
      add(svg, s("circle", { cx: last[0], cy: last[1], r: 5, "class": "dot" }));
    }
    add(svg, s("text", { x: x(t1) - 4, y: y(0) - 6, "text-anchor": "end" }, T("even pace", "平均速度") + " ↗"));
    return h("div", { cls: "chart" }, svg);
  }

  function renderMid() {
    var mid = clear("mid"), c = data.claude || {};
    var chart = h("div", { cls: "card" }, h("div", { cls: "cardhead" },
      h("h2", { text: T("This week against even pace", "本週用量 vs 平均速度") }),
      h("span", { cls: "muted", text: T("dashed line: where an even pace would be", "虛線：平均速度應在的位置") })));
    if (c.weekly && c.weekly.window_start) add(chart, weekChart(c.weekly));
    else add(chart, h("div", { cls: "empty", text: T("The chart fills in once the menu-bar app has written a few readings.", "選單列 App 寫入幾筆資料後，圖表就會出現。") }));
    if (c.history_points != null && c.history_points < 20) add(chart, h("span", { cls: "muted", text: T("Pace estimates firm up after a day of readings.", "累積一天的資料後，速度估算會更準。") }));
    add(mid, chart);

    var lim = h("div", { cls: "card" }, h("div", { cls: "cardhead" },
      h("h2", { text: T("Every Claude limit", "Claude 所有額度") }),
      h("span", { cls: "muted", text: c.account || "" })));
    var rows = c.rows || [];
    if (!rows.length) add(lim, h("div", { cls: "empty", text: T("No limits reported yet.", "尚未取得額度資料。") }));
    rows.forEach(function (r) {
      var right = r.key === "spend" && r.used != null
        ? "$" + r.used.toFixed(2) + (r.limit != null ? " / $" + r.limit.toFixed(2) : "")
        : (r.resets_at ? T("resets ", "") + inT(r.resets_at) + T("", "重置") + " · " + clock(r.resets_at, true) : "");
      add(lim, h("div", { cls: "limit" },
        h("div", { cls: "meterlabel" }, h("span", { text: limitLabel(r.key) }), h("b", { text: pct(r.percent), style: { color: sevColor(r.percent, r.severity) } })),
        meter(r.percent, sevColor(r.percent, r.severity)),
        h("span", { cls: "muted", text: right })));
    });
    add(lim, h("span", { cls: "muted", text: T("Amber at 75%, red at 90%, same as the menu-bar ring.", "75% 轉琥珀、90% 轉紅，與選單列圓環一致。") }));
    add(mid, lim);
  }

  function bars(items, color, valFn, labelFn) {
    var max = items.reduce(function (a, it) { return Math.max(a, it.v); }, 0) || 1;
    return h("div", { cls: "bars" }, items.map(function (it) {
      return h("div", { cls: "bar" },
        h("span", { cls: "name", text: labelFn(it), attrs: { title: labelFn(it) } }),
        h("div", { cls: "track" }, h("div", { style: { width: Math.max(1, it.v / max * 100) + "%", background: color } })),
        h("span", { cls: "val", text: valFn(it) }));
    }));
  }
  function columns(items, color, labelFn) {
    var max = items.reduce(function (a, it) { return Math.max(a, it.v); }, 0) || 1;
    return h("div", { cls: "cols" }, items.map(function (it) {
      return h("div", { cls: "c", attrs: { title: labelFn(it) + ": " + it.v } },
        h("span", { text: it.v ? (it.vText || String(it.v)) : "" }),
        h("div", { cls: "b", style: { height: Math.max(2, it.v / max * 86) + "px", background: color } }),
        h("span", { text: it.label }));
    }));
  }

  function renderLow() {
    var low = clear("low"), cc = data.claude_code || {}, o = data.ollama || {};
    var ccCard = h("div", { cls: "card" }, h("div", { cls: "cardhead" },
      h("h2", { text: T("Claude Code by project", "Claude Code 依專案") }),
      h("span", { cls: "muted", text: T("since the weekly reset", "自本週重置起") })));
    var projects = (cc.projects || []).slice(0, 8);
    if (!projects.length) add(ccCard, h("div", { cls: "empty", text: cc.dirs_found && cc.dirs_found.length ? T("No Claude Code sessions this week.", "本週沒有 Claude Code 工作階段。") : T("No Claude Code transcripts on this Mac yet (~/.claude/projects).", "這台 Mac 上還沒有 Claude Code 紀錄（~/.claude/projects）。") }));
    else {
      add(ccCard, bars(projects.map(function (p) { return { v: p.tokens, p: p }; }), "var(--claude)",
        function (it) { return tokens(it.v); }, function (it) { return it.p.name; }));
      var days = (cc.days || []).slice(-7);
      if (days.length) add(ccCard, columns(days.map(function (dd) { return { v: dd.tokens, vText: tokens(dd.tokens), label: dayLabel(dd.date, true), date: dd.date }; }), "var(--claude-lt)", function (it) { return it.date; }));
    }
    add(ccCard, h("span", { cls: "muted", text: T("Input + output + cache writes. Chat, Cowork and browser agents share the same limit but aren't logged on this Mac.",
      "輸入 + 輸出 + 快取寫入。聊天、Cowork、瀏覽器代理共用同一額度，但不會記在這台 Mac 上。") }));
    add(low, ccCard);

    var oc = h("div", { cls: "card" }, h("div", { cls: "cardhead" },
      h("h2", { text: T("Local models", "本機模型") }),
      h("span", { cls: "muted", text: o.version ? "Ollama " + o.version : "" })));
    if (!o.reachable) add(oc, h("div", { cls: "empty", text: T("Ollama isn't answering at " + o.url + ". Open the Ollama app.", "Ollama 在 " + o.url + " 沒有回應，請開啟 Ollama App。") }));
    var memTotal = o.memory_bytes, loadedBytes = (o.loaded || []).reduce(function (a, m) { return a + (m.size_vram || m.size || 0); }, 0);
    if (o.reachable && memTotal) {
      add(oc, h("div", { cls: "limit" },
        h("div", { cls: "meterlabel" }, h("span", { text: T("Memory held by models", "模型占用記憶體") }), h("b", { text: gb(loadedBytes) + " / " + gb(memTotal) })),
        meter(loadedBytes / memTotal * 100, "var(--local)", null, 75),
        h("span", { cls: "muted", text: T("Tick: macOS's default GPU limit (~75%)", "標線：macOS 預設 GPU 上限（約 75%）") })));
    }
    (o.installed || []).slice(0, 6).forEach(function (m) {
      var role = m.name && o.primary && m.name.indexOf(o.primary.split(":")[0]) === 0 ? T("primary", "主力")
        : m.name && o.backup && m.name.indexOf(o.backup.split(":")[0]) === 0 ? T("backup", "備援") : "";
      var loaded = (o.loaded || []).some(function (l) { return l.name === m.name; });
      add(oc, h("div", { cls: "model" },
        h("span", { cls: "n", text: m.name + (role ? " · " + role : "") }),
        h("span", { cls: "muted", text: [m.params, m.quant, gb(m.size), loaded ? T("in memory", "常駐中") : ""].filter(Boolean).join(" · ") })));
    });
    var req = o.requests || [];
    if (req.length) {
      add(oc, h("h3", { text: T("Requests per day", "每日請求數") }));
      add(oc, columns(req.map(function (r) { return { v: r.requests, label: dayLabel(r.date, true), date: r.date }; }), "var(--local)", function (it) { return it.date; }));
      if (!o.log_found) add(oc, h("span", { cls: "muted", text: T("No Ollama log found in ~/.ollama/logs, so requests can't be counted.", "~/.ollama/logs 找不到 Ollama 日誌，無法計算請求數。") }));
      else if (o.median_seconds) add(oc, h("span", { cls: "muted", text: T("Median response time ", "回應時間中位數 ") + o.median_seconds + " s" }));
    }
    add(low, oc);

    var pc = h("div", { cls: "card" }, h("div", { cls: "cardhead" },
      h("h2", { text: T("Plans", "方案") }),
      h("span", { cls: "mono", text: "$" + (data.plans || []).reduce(function (a, p) { return a + (p.monthly || 0); }, 0).toFixed(2) + T(" / mo", " / 月") })));
    (data.plans || []).forEach(function (p) {
      add(pc, h("div", { cls: "plan" },
        h("span", { cls: "n" }, p.name, h("span", { cls: "chip " + (p.meter === "live" ? "live" : "none"), text: p.meter === "live" ? T("tracked", "有追蹤") : T("no meter", "無用量資料") })),
        h("span", { cls: "p", text: p.monthly ? "$" + Number(p.monthly).toFixed(2) : T("free", "免費") }),
        h("span", { cls: "d", text: lang === "zh" ? (p.zh || "") : (p.en || "") })));
    });
    add(low, pc);
  }

  function renderFoot() {
    var f = clear("foot"), c = data.claude || {}, cc = data.claude_code || {}, o = data.ollama || {};
    function line(k, v) { return h("span", null, h("b", { text: k + " " }), v); }
    add(f, line(T("Claude limits:", "Claude 額度："), c.available ? T("menu-bar app snapshot, ", "選單列 App 快照，") + agoT(c.age_seconds) : T("no snapshot (update the menu-bar app to v1.3)", "沒有快照（請把選單列 App 更新到 v1.3）")));
    add(f, line(T("Claude Code:", "Claude Code："), T(cc.files + " transcript files this week", "本週 " + cc.files + " 個紀錄檔")));
    add(f, line("Ollama:", o.reachable ? T("answering at ", "回應中：") + o.url : T("not answering", "沒有回應")));
    add(f, line(T("Not tracked:", "未追蹤："), T("Gemini, Grok and Muse have no usage API", "Gemini、Grok、Muse 沒有用量 API")));
    add(f, line("ai-usage", "v" + (data.version || "?")));
  }

  function render() {
    renderHeader();
    if (!data) return;
    if (data.error) { clear("top"); add(document.getElementById("top"), h("div", { cls: "empty", text: data.error })); return; }
    renderTop(); renderMid(); renderLow(); renderFoot();
  }

  function load() {
    fetch("/api/data", { cache: "no-store", credentials: "same-origin" })
      .then(function (r) { if (!r.ok) throw new Error("HTTP " + r.status); return r.json(); })
      .then(function (j) { data = j; lastError = null; render(); })
      .catch(function (e) { lastError = e; render(); });
  }

  function setLang(l) { lang = l; try { localStorage.setItem("aiu-lang", l); } catch (e) {} render(); }
  document.getElementById("l-zh").addEventListener("click", function () { setLang("zh"); });
  document.getElementById("l-en").addEventListener("click", function () { setLang("en"); });

  render();
  load();
  setInterval(load, 60000);
  setInterval(function () { if (data) render(); }, 30000);  // keep countdowns current between fetches
})();
