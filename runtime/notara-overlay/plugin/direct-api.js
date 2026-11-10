/**
 * 宿主直连入口:`window.__NOTARA_DIRECT__`。
 *
 * 为什么需要它:宿主(Flutter)的顶栏、抽屉、纯净模式要"切到某节课的白板"
 * "打开教学设置""列出真实教法"。这些都是网页内部状态,从外面看不见。旧
 * 办法是找出可见节点、读它的文字、按文字相似度打分再合成点击——图标没有
 * 文字,这个办法对四键必然失效;就算蒙对一次,换一版界面就全废。
 *
 * 这里改成:把网页自己的导航对象、以及它已经在用的 Remote 调用,原样交给
 * 宿主。宿主调的是同一批函数、同一批请求,所以"对话里聊哪道题,白板就画哪
 * 道题"靠的是同一个 sessionId,而不是猜。
 *
 * 一条原则贯穿全文:**做不到就如实说做不到**。每个入口都返回
 * `{ ok, reason }`,不认识的分区、没有会话、面板不存在,都照实回,不假装
 * 成功,也不退回文字点击。
 */

import { invokeHeaderAction, registeredHeaderActions } from './header-actions.js';

/** 分区白名单。`skills` 是 workspace 自己认识的第五个分区。 */
const SECTIONS = new Set(['home', 'plan', 'vault', 'skills', 'lesson']);
/** 计划与题库各自的页签;传错就退回该分区的第一页,而不是静默留在原地。 */
const TABS = {
  plan: new Set(['calendar', 'routes', 'review', 'scheduled']),
  vault: new Set(['files', 'cards', 'graph']),
};
/**
 * 宿主三视图 -> 网页课堂内的视图键。
 *
 * 教室不是字面量 `classroom`:网页里它是自己的视图 id(`notara-vault-classroom`,
 * classroom-client.js 的 CLASSROOM_VIEW)。照字面传过去会切不进去,所以这里
 * 显式写死映射,而不是把宿主的名字直接透传。
 */
const VIEWS = { chat: 'chat', board: 'board', classroom: 'notara-vault-classroom' };

const text = value => (typeof value === 'string' ? value : '');

/**
 * @param {object} deps
 * @param {object} deps.ctx        插件 apply 的 scope(提供 sessions / uiWorkspace)
 * @param {object} deps.navigation createVaultNavigation() 的返回值
 * @param {(snapshot:unknown)=>string} deps.currentSessionId 原生会话选择
 * @param {(ctx:object, sessionId:string)=>object} deps.createVaultClient Remote 客户端
 * @param {(ctx:object)=>Promise<string>} [deps.ensureSession] 建一节新课堂(带教学预设)
 * @param {()=>void} [deps.onChange] 状态变化时通知宿主重读(可选)
 */
export function createDirectApi({ ctx, navigation, currentSessionId, createVaultClient, ensureSession, onChange }) {
  const settled = fn => {
    try {
      return fn();
    } catch (error) {
      return { ok: false, reason: 'failed', detail: String(error && error.message ? error.message : error) };
    }
  };

  /** 当前原生选中的会话。没有就是空串——绝不伪造一个。 */
  const liveSession = () => {
    try {
      return text(currentSessionId(ctx.sessions.list.getSnapshot()));
    } catch {
      return '';
    }
  };

  /**
   * 宿主传了 sessionId 就用它(切视图前先把网页切到同一节课),
   * 没传就退回当前原生选中,再没有就如实失败。
   */
  const resolveSession = wanted => {
    const id = text(wanted) || liveSession();
    return id || '';
  };

  /**
   * 白板自适应:按视口宽度收一档,让平板竖屏也能一眼看到整张图。
   *
   * 用真实的 `scrollWidth / clientWidth` 算比例,只在内容确实溢出时缩,
   * 而且只缩不放(放大交给双指)。`zoom` 比 transform 更合适:它会参与
   * 布局,滚动条和内层 JSXGraph 的坐标换算仍然是同一套。
   */
  function fitBoard() {
    try {
      const panes = document.querySelector('.nv-panes[data-nv-board="true"]');
      if (!panes) return { ok: false, reason: 'no_board' };
      const hosts = panes.querySelectorAll('.nv-pane-content');
      let applied = 0;
      for (const host of hosts) {
        const inner = host.firstElementChild;
        if (!inner) continue;
        inner.style.zoom = '';
        const available = host.clientWidth || panes.clientWidth;
        const content = inner.scrollWidth || inner.clientWidth;
        if (!available || !content) continue;
        const ratio = available / content;
        if (ratio >= 0.999) continue;
        inner.style.zoom = String(Math.max(0.45, Math.floor(ratio * 100) / 100));
        applied += 1;
      }
      return { ok: true, applied };
    } catch (error) {
      return { ok: false, reason: 'failed', detail: String(error && error.message ? error.message : error) };
    }
  }

  /** 切到白板、转屏、内容更新之后都排一次:布局要下一帧才算得准。 */
  function fitBoardSoon() {
    try {
      requestAnimationFrame(() => requestAnimationFrame(fitBoard));
    } catch {
      /* 没有 rAF(测试环境)就算了,下一次手动 fit 会补上。 */
    }
  }

  const api = {
    /** 版本号,宿主据此判断网页有没有加载到这一版直连接口。 */
    version: 3,

    /** 网页当前真实落在哪:分区、页签、会话。宿主用它做启动自检。 */
    snapshot() {
      const value = navigation.getSnapshot();
      return {
        ok: true,
        section: value.section,
        plan: value.plan,
        vault: value.vault,
        sessionId: liveSession(),
      };
    },

    /**
     * 切到某节课的某个视图。**先开课,再切视图**:顺序反了,白板会先渲染
     * 上一节课的板书,再被新数据覆盖,中间那一下就是错题的板书。
     *
     * 没有课号时不去猜一节课:把网页带回首页(选目录开课),并如实回
     * `no_session`。宿主据此把原生对话留在原地,而不是显示一张别人的白板。
     */
    openLessonView(sessionId, view) {
      const target = VIEWS[view] ?? 'chat';
      const id = resolveSession(sessionId);
      if (!id) {
        navigation.show('home');
        return { ok: false, reason: 'no_session', section: 'home' };
      }
      return settled(() => {
        navigation.openLesson(ctx, id, target);
        // 白板是重排版的:切过去之后按视口宽度铺满,不然平板上只看得到左边三列。
        if (target === 'board') fitBoardSoon();
        return { ok: true, sessionId: id, view: target };
      });
    },

    /**
     * 确认有一节课可上。没有就现开一节(带教学预设)。
     *
     * 异步:结果通过 `notaraSession` 回传给宿主,宿主收到就把原生对话切过去。
     * 这里同步回 `{ok:true, pending:true}`,表示"已经在开了"——不假装已经有课号。
     */
    ensureSession() {
      const current = liveSession();
      if (current) return { ok: true, sessionId: current, pending: false };
      if (typeof ensureSession !== 'function') return { ok: false, reason: 'unavailable' };
      Promise.resolve()
        .then(() => ensureSession(ctx))
        .then(id => {
          if (typeof id === 'string' && id) {
            announceSession(id, '', false);
            return;
          }
          // 没有目录可开课时,把学生带回首页自己选一个,而不是干等。
          navigation.show('home');
        })
        .catch(() => {
          navigation.show('home');
        });
      return { ok: true, pending: true };
    },

    /** 抽屉五大入口:首页 / 计划 / 题库 / 技能 / 设置。 */
    openSection(section, tab) {
      if (!SECTIONS.has(section)) return { ok: false, reason: 'unknown_section', section };
      const allowed = TABS[section];
      const next = allowed && allowed.has(tab) ? tab : undefined;
      return settled(() => {
        navigation.show(section, next);
        return { ok: true, section, tab: next ?? null };
      });
    },

    /** 课堂历史 / 计时。 */
    openHistory() {
      return settled(() => invoke('history'));
    },
    /** 教学设置(教法、目标、人格)。 */
    openTeaching() {
      return settled(() => invoke('teaching'));
    },
    /** 总结本课。 */
    openSummary() {
      return settled(() => invoke('summary'));
    },
    /** 当前真的有哪些面板可开,宿主据此决定按钮显示还是收起。 */
    headerActions() {
      return { ok: true, keys: registeredHeaderActions() };
    },

    /**
     * 真实教法列表。来自 `teachingSettings` 的 `choices`:标题、说明、id
     * 都是这节课当前的设置回执里带的,不是写死的常量。
     */
    async listSkills(sessionId) {
      const id = resolveSession(sessionId);
      if (!id) return { ok: false, reason: 'no_session' };
      try {
        const result = await createVaultClient(ctx, id).teachingSettings({ sessionId: id });
        if (!result || result.ok !== true) return { ok: false, reason: 'read_failed' };
        const value = result.value ?? {};
        const choices = Array.isArray(value.choices) ? value.choices : [];
        return {
          ok: true,
          sessionId: id,
          teachingRef: text(value.teachingRef),
          revision: value.revision ?? null,
          skills: choices.map(choice => ({
            id: text(choice.id),
            title: text(choice.title),
            description: text(choice.description),
          })),
        };
      } catch (error) {
        return { ok: false, reason: 'read_failed', detail: String(error && error.message ? error.message : error) };
      }
    },

    /**
     * 选定一个教法。走和面板保存同一条写路径(带 expectedRevision),
     * 所以冲突能如实报出来,而不是本地改个变量当作生效。
     */
    async selectSkill(sessionId, skillId) {
      const id = resolveSession(sessionId);
      if (!id) return { ok: false, reason: 'no_session' };
      const ref = text(skillId);
      if (!ref) return { ok: false, reason: 'unknown_skill' };
      try {
        const client = createVaultClient(ctx, id);
        const current = await client.teachingSettings({ sessionId: id });
        if (!current || current.ok !== true) return { ok: false, reason: 'read_failed' };
        const result = await client.updateTeachingSettings({
          sessionId: id,
          expectedRevision: current.value?.revision,
          patch: { teachingRef: ref },
        });
        if (!result || result.ok !== true) return { ok: false, reason: 'write_conflict' };
        return { ok: true, sessionId: id, teachingRef: text(result.value?.teachingRef) || ref };
      } catch (error) {
        return { ok: false, reason: 'write_failed', detail: String(error && error.message ? error.message : error) };
      }
    },

    /** 请老师在本课收尾并总结:没有弹窗,直接把请求交给后端。 */
    async summarize(sessionId) {
      const id = resolveSession(sessionId);
      if (!id) return { ok: false, reason: 'no_session' };
      try {
        const result = await createVaultClient(ctx, id).requestLessonSummary({ sessionId: id });
        if (!result || result.ok !== true) return { ok: false, reason: 'refused' };
        return { ok: true, sessionId: id };
      } catch (error) {
        return { ok: false, reason: 'failed', detail: String(error && error.message ? error.message : error) };
      }
    },

    /**
     * 内嵌无壳模式开关。CSS 只认 `body[data-dsh-go-embedded="true"]`,
     * 浏览器里直接打开时保持原样,方便对照。
     */
    setEmbedded(on) {
      try {
        document.body.dataset.dshGoEmbedded = on === false ? 'false' : 'true';
        if (on !== false) fitBoardSoon();
        return { ok: true, embedded: document.body.dataset.dshGoEmbedded === 'true' };
      } catch {
        return { ok: false, reason: 'failed' };
      }
    },

    /** 宿主转屏、切到白板、白板刚更新时都调一次。 */
    fitBoard() {
      return fitBoard();
    },
  };

  /** 转发到注册表;键不存在时 `invokeHeaderAction` 会如实回 no_handler。 */
  function invoke(key) {
    const result = invokeHeaderAction(key);
    return result && result.ok ? { ok: true, key } : { ok: false, reason: (result && result.reason) || 'no_handler', key };
  }

  return api;
}

/**
 * 会话回传:网页开了课,宿主必须立刻知道是哪一节。
 *
 * 走的是宿主自己注入的 `window.DshAppOpen`;没有它(浏览器里调试)就静默
 * 跳过,不影响网页自身。带 `silent` 时不发——那是宿主自己调进来的,回传
 * 会让两边互相触发。
 */
export function announceSession(sessionId, view, silent) {
  const id = typeof sessionId === 'string' ? sessionId : '';
  if (!id || silent) return false;
  try {
    const bridge = window.DshAppOpen;
    if (!bridge || typeof bridge.postMessage !== 'function') return false;
    bridge.postMessage(JSON.stringify({ type: 'notaraSession', sessionId: id, view: typeof view === 'string' ? view : '' }));
    return true;
  } catch {
    return false;
  }
}
