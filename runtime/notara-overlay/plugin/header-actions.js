/**
 * 课堂右上角动作的确定性注册表。
 *
 * 宿主顶栏上的 ⏱ 🎚 📄 要打开的是网页里真实的面板:番茄钟、教学设置、
 * 总结本课。这些面板的开关状态住在各自的 React 组件里,组件外面没有任何
 * 可以点中的"按钮"——只有图标,没有文字。
 *
 * 所以旧办法(找出可见节点 → 读它的文字 → 按文字打分 → 合成点击)必然
 * 落空:图标按钮的文字是空的,打分永远选不中。这里换一条路:组件挂载时把
 * 自己的开关函数交出来,宿主调用同一个函数。不猜 DOM、不依赖文字,组件把
 * 按钮挪到别处、改了文案,调用照样命中;组件卸载了,注册表里也就没有了,
 * 宿主能如实知道"现在没有这个面板",而不是假装点过。
 *
 * 键名由宿主与这里约定:
 *   history  番茄钟 / 课堂计时
 *   teaching 教学设置(教法、学习目标、人格)
 *   summary  总结本课
 */

/** key -> () => void | Promise<unknown> */
const handlers = new Map();

/**
 * 组件挂载时登记,返回注销函数。
 *
 * 同一个键可能被重新登记(React 严格模式下 effect 会跑两遍),所以注销时
 * 只撤销"自己那一版":登记时记住自己的身份,注销时身份不符就什么都不做,
 * 避免把后来者的登记一起删掉。
 */
export function registerHeaderAction(key, run) {
  if (typeof key !== 'string' || !key || typeof run !== 'function') return () => {};
  const previous = handlers.get(key);
  handlers.set(key, run);
  return () => {
    if (handlers.get(key) !== run) return;
    if (previous) handlers.set(key, previous);
    else handlers.delete(key);
  };
}

/**
 * 宿主调用入口。
 *
 * 同步返回 `{ ok, key }` 或 `{ ok: false, reason }`:面板要不要异步读数据是
 * 组件自己的事,宿主只需要知道"这一下有没有交到一个真的开关上"。找不到就
 * 如实返回 `no_handler`,**绝不退回文字点击**——那正是要废掉的东西。
 */
export function invokeHeaderAction(key, argument) {
  const run = handlers.get(key);
  if (typeof run !== 'function') return { ok: false, reason: 'no_handler', key };
  try {
    const value = run(argument);
    // 面板可能边打开边加载:失败不能让异常冒到宿主,但也不能吞成"成功打开"。
    if (value && typeof value.then === 'function') value.then(() => {}, () => {});
    return { ok: true, key };
  } catch {
    return { ok: false, reason: 'failed', key };
  }
}

/** 当前真的登记了哪些键。宿主用它决定某个键是显示、置灰还是收起。 */
export function registeredHeaderActions() {
  return Array.from(handlers.keys());
}
