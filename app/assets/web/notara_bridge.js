// 原生外壳与 Notara 网页之间那座桥。由 dsh-app 的 WebView 在每次 onPageFinished
// 后注入(幂等),只做三件事,不碰网页的样式与数据:
//
//   window.__dshGoShow(view)      -> 让网页切到 白板 / 教室 / 对话
//   window.__dshGoSection(key)    -> 让网页切到 首页 / 计划 / Vault / 技能 / 设置
//   window.__dshAppPause(on)      -> 原生对话页在前台时,停掉网页的动画循环
//
// 为什么是"找入口再点",而不是直接调函数:Notara 的 openLesson(ctx,...) 是
// Cordis 插件在 __ModuleLoader__ 作用域里的闭包,外部拿不到 ctx。而它渲染出来
// 的入口是真实按钮——点它,和用户手指点的是同一条路径,网页自己的状态机
// (section / layoutRequest) 会照常走完,不产生"半切"状态。
//
// 别名表:中文优先(Notara 的界面语言),英文兜底(自定义主题或将来 i18n)。
(function () {
  if (window.__dshGoShow) return;

  // 下行的**会话通道**:Notara 源码里 `window.DshAppOpen?.postMessage(...)` 指
  // 的就是这里。网页每开一节课(首页选目录、题库点题、计划开课)都把真实
  // sessionId 发回来,原生侧据此把对话切到同一节课——"对话里聊哪道题,白板就
  // 画哪道题"靠的是同一个 id,不是猜。
  //
  // 定义必须放在最前面:开课可能发生在首屏,不能等某个函数被调用之后才存在。
  // 也不写死 channel 名:NotaraBridge 是本壳注入的,换个壳就变。
  window.DshAppOpen = {
    postMessage: function (payload) {
      try {
        var text = typeof payload === 'string' ? payload : JSON.stringify(payload);
        if (window.NotaraBridge && typeof window.NotaraBridge.postMessage === 'function') {
          window.NotaraBridge.postMessage(text);
          return true;
        }
      } catch (error) {
        /* 通道不可用就当没这回事:网页自身功能不受影响。 */
      }
      return false;
    },
  };

  var VIEWS = {
    board: ['白板', '画布', '板书', 'Board', 'Whiteboard'],
    lesson: ['教室', '课堂', '上课', 'Lesson', 'Classroom', 'Class'],
    chat: ['对话', '聊天', '会话', 'Chat', 'Conversation']
  };

  var SECTIONS = {
    home: ['首页', 'Home'],
    plan: ['计划', '日程', 'Plan', 'Schedule'],
    vault: ['Vault', '题库', '资料库', '知识库'],
    skills: ['技能', 'Skills', 'Skill'],
    settings: ['设置', '设定', 'Settings', 'Preferences']
  };

  // 顶栏右侧四键。它们不是通用 LLM 参数:⏱ 是课堂历史/计时,🎚 是教学设置
  // (讲法基调),📄 是当前课堂文档/题目小结,⋯ 是本课堂的更多操作。
  var TAPS = {
    history: ['课堂历史', '历史记录', '上课记录', '计时', 'History', 'Timeline', 'Recap'],
    teaching: ['教学设置', '课程选项', '讲法', '授课方式', 'Teaching', 'Options'],
    document: ['课堂文档', '题目小结', '讲义', '本次小结', 'Document', 'Notes', 'Summary'],
    more: ['更多操作', '课堂更多', '更多', 'More']
  };

  function visible(el) {
    if (!el || el.disabled) return false;
    var r = el.getBoundingClientRect();
    if (r.width < 2 || r.height < 2) return false;
    var cs = getComputedStyle(el);
    return cs.visibility !== 'hidden' && cs.display !== 'none' && cs.opacity !== '0';
  }

  function candidates() {
    return Array.prototype.slice.call(
      document.querySelectorAll(
        'button,[role="button"],a[href],[role="tab"],[role="menuitem"],[role="option"],summary,label'
      )
    );
  }

  function label(el) {
    var aria = el.getAttribute('aria-label') || el.getAttribute('title') || '';
    var text = (el.textContent || '').replace(/\s+/g, ' ').trim();
    return (aria + ' ' + text).trim();
  }

  // 精确等于 > 以它开头 > 包含它但整体很短。反过来的话,"对话设置"
  // 会被"对话"抢走,把切换视图变成打开设置。
  function score(text, name) {
    if (!text) return 0;
    if (text === name) return 3;
    if (text.indexOf(name) === 0) return 2;
    if (text.length <= name.length + 4 && text.indexOf(name) >= 0) return 1;
    return 0;
  }

  function pick(names) {
    var all = candidates().filter(visible);
    var best = null;
    var bestScore = 0;
    for (var n = 0; n < names.length; n++) {
      for (var i = 0; i < all.length; i++) {
        var s = score(label(all[i]), names[n]);
        if (s > bestScore) {
          bestScore = s;
          best = all[i];
        }
      }
      // 高置信命中就不再往下比:先命中的别名优先级更高。
      if (bestScore === 3) break;
    }
    return bestScore >= 1 ? best : null;
  }

  function tap(el) {
    try {
      el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
    } catch (e) {}
    try {
      el.click();
      return true;
    } catch (e) {
      // 有些入口是 div + pointerdown 监听,补一次真实事件序列。
      try {
        var r = el.getBoundingClientRect();
        var x = r.left + r.width / 2;
        var y = r.top + r.height / 2;
        ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click'].forEach(function (type) {
          el.dispatchEvent(
            new MouseEvent(type, { bubbles: true, cancelable: true, clientX: x, clientY: y, view: window })
          );
        });
        return true;
      } catch (e2) {
        return false;
      }
    }
  }

  function report(payload) {
    try {
      NotaraBridge.postMessage(JSON.stringify(payload));
    } catch (e) {}
  }

  window.__dshGoShow = function (view) {
    var names = VIEWS[view];
    if (!names) return false;
    var el = pick(names);
    if (!el) return false;
    var ok = tap(el);
    if (ok) report({ view: view });
    return ok;
  };

  window.__dshGoSection = function (key) {
    var names = SECTIONS[key];
    if (!names) return false;
    var el = pick(names);
    if (!el) return false;
    var ok = tap(el);
    if (ok) report({ section: key });
    return ok;
  };

  window.__dshGoTap = function (key) {
    var names = TAPS[key];
    if (!names) return false;
    var el = pick(names);
    if (!el) return false;
    return tap(el);
  };

  // 原生对话页在前台时,网页只是待命,不该继续跑 CSS 动画把帧喂给合成器。
  window.__dshAppPause = function (on) {
    var id = '__dshGoPause';
    var el = document.getElementById(id);
    if (on) {
      if (el) return;
      el = document.createElement('style');
      el.id = id;
      el.textContent =
        '*,*::before,*::after{animation-play-state:paused !important;' +
        'transition-duration:0s !important;}';
      document.head.appendChild(el);
    } else if (el) {
      el.parentNode.removeChild(el);
    }
  };

  report({ ready: true });
})();
