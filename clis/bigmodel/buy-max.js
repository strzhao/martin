import { cli, Strategy } from '@jackwener/opencli/registry';

const PAGE_URL = 'https://bigmodel.cn/glm-coding?plantype=personal';

const sleep = (ms) => new Promise(r => setTimeout(r, ms));

cli({
  site: 'bigmodel',
  name: 'buy-max',
  description: '购买 GLM Coding Max 套餐（自动等待补货 + 一键下单）',
  access: 'write',
  example: `opencli --profile <name> bigmodel buy-max
  opencli --profile <name> bigmodel buy-max --period 季
  opencli --profile <name> bigmodel buy-max --dry-run`,
  domain: 'bigmodel.cn',
  strategy: Strategy.PUBLIC,
  browser: true,
  args: [
    {
      name: 'period',
      type: 'string',
      default: '季',
      help: '订阅周期：月 / 季 / 年（默认：季，9 折）',
    },
    {
      name: 'poll-interval',
      type: 'int',
      default: 2000,
      help: '按钮状态轮询间隔（毫秒，默认 2000ms）',
    },
    {
      name: 'max-wait',
      type: 'int',
      default: 600,
      help: '最长等待时间（秒，默认 600s = 10 分钟）',
    },
    {
      name: 'dry-run',
      type: 'boolean',
      default: false,
      help: '仅检查状态，不实际购买',
    },
  ],
  columns: ['status', 'detail'],
  func: async (page, args) => {
    // ──────────────────────────────────────────────
    // 1. 导航 + 等待 SPA 渲染
    // ──────────────────────────────────────────────
    console.log('[buy-max] 🚀 正在打开 GLM Coding 套餐页面...');
    await page.goto(PAGE_URL);

    // 轮询等待套餐卡片出现（使用 evaluate 因为 page.$ 在 adapter 中行为不同）
    const cardsReady = await pollUntil(page, () => {
      return document.querySelectorAll('.package-card').length >= 3;
    }, 30000, 500);

    if (!cardsReady) {
      // 检查是否跳转登录页
      const url = await page.evaluate(() => window.location.href);
      if (url.includes('login') || url.includes('signin')) {
        return [{
          status: 'NEED_LOGIN',
          detail: '页面跳转到登录页。请使用 opencli --profile <name> bigmodel buy-max 指定已登录的 Chrome 配置文件。',
        }];
      }
      return [{ status: 'ERROR', detail: '页面加载超时，套餐卡片未出现。检查网络或使用 --profile 指定已登录的配置文件。' }];
    }

    console.log('[buy-max] ✅ 页面渲染完成，套餐卡片已加载');
    await sleep(3000); // 等待 Vue 数据和 API 响应完成

    // ──────────────────────────────────────────────
    // 2. 关闭初始弹窗
    // ──────────────────────────────────────────────
    const dialogsClosed = await page.evaluate(() => {
      const closed = [];
      document.querySelectorAll('[role="dialog"]').forEach(d => {
        if (d.offsetParent === null) return;
        d.querySelectorAll('button').forEach(b => {
          if (b.textContent.trim() === '我知道了' || b.getAttribute('aria-label') === 'Close') {
            b.click();
            closed.push(b.textContent.trim() || 'close');
          }
        });
      });
      return closed;
    });
    if (dialogsClosed.length > 0) {
      console.log(`[buy-max] 🧹 关闭了 ${dialogsClosed.length} 个弹窗: ${dialogsClosed.join(', ')}`);
      await sleep(800);
    }

    // ──────────────────────────────────────────────
    // 3. 确保"个人套餐" tab 选中
    // ──────────────────────────────────────────────
    const tabOk = await page.evaluate(() => {
      const tab = document.querySelector('#tab-personal');
      if (tab && tab.getAttribute('aria-selected') !== 'true') {
        tab.click();
        return 'clicked';
      }
      return 'ok';
    });
    if (tabOk === 'clicked') {
      console.log('[buy-max] 🔘 切换到个人套餐 tab');
      await sleep(1000);
    }

    // ──────────────────────────────────────────────
    // 4. 选择订阅周期
    // ──────────────────────────────────────────────
    const periodIndex = { '月': 0, '季': 1, '年': 2 };
    const periodIdx = periodIndex[args.period];
    if (periodIdx === undefined) {
      return [{ status: 'ERROR', detail: `无效的订阅周期: ${args.period}，可选：月/季/年` }];
    }
    console.log(`[buy-max] 📅 选择订阅周期: 连续包${args.period}...`);

    const periodClicked = await page.evaluate((idx) => {
      const container = document.querySelector('#switchTabBox');
      if (!container) return false;
      const options = container.querySelectorAll('[tabindex="0"]');
      if (options.length > idx) {
        options[idx].click();
        return true;
      }
      return false;
    }, periodIdx);

    console.log(`[buy-max] ${periodClicked ? '✅' : '⚠️'} 订阅周期选择完成 (index: ${periodIdx})`);
    await sleep(1000);

    // ──────────────────────────────────────────────
    // 5. 获取 Max 套餐状态
    // ──────────────────────────────────────────────
    const cardInfo = await page.evaluate(() => {
      const cards = document.querySelectorAll('.package-card');
      if (cards.length < 3) return { error: `只找到 ${cards.length} 个卡片，需要 3 个` };
      const maxCard = cards[2]; // Lite=0, Pro=1, Max=2
      const titleEl = maxCard.querySelector('span');
      const title = titleEl ? titleEl.textContent.trim() : 'unknown';
      const btn = maxCard.querySelector('button.buy-btn');
      return {
        title,
        btnText: btn ? btn.textContent.trim() : 'no-button',
        btnDisabled: btn ? (btn.disabled || btn.className.includes('is-disabled')) : true,
      };
    });

    if (cardInfo.error) {
      return [{ status: 'ERROR', detail: cardInfo.error }];
    }
    if (!cardInfo.title.includes('Max')) {
      return [{ status: 'ERROR', detail: `第 3 个卡片不是 Max（识别为: ${cardInfo.title}）` }];
    }

    console.log(`[buy-max] 🎯 目标套餐: ${cardInfo.title}`);
    console.log(`[buy-max] 📊 当前状态: "${cardInfo.btnText}" | disabled=${cardInfo.btnDisabled}`);

    // ──────────────────────────────────────────────
    // 6. dry-run 模式
    // ──────────────────────────────────────────────
    if (args['dry-run']) {
      return [{
        status: cardInfo.btnDisabled ? 'SOLD_OUT' : 'AVAILABLE',
        detail: `按钮状态: "${cardInfo.btnText}" | 可购买: ${!cardInfo.btnDisabled}`,
      }];
    }

    // ──────────────────────────────────────────────
    // 7. 轮询等待按钮启用
    // ──────────────────────────────────────────────
    if (cardInfo.btnDisabled) {
      console.log('[buy-max] ⏳ Max 套餐暂未开售，开始轮询等待...');
      console.log(`[buy-max] ⏱️  轮询间隔: ${args['poll-interval']}ms | 最长等待: ${args['max-wait']}s`);
      console.log('[buy-max] 💡 按 Ctrl+C 可随时中断\n');

      const startTime = Date.now();
      const maxWaitMs = args['max-wait'] * 1000;
      let lastText = cardInfo.btnText;
      let lastLogTime = 0;

      while (Date.now() - startTime < maxWaitMs) {
        await sleep(args['poll-interval']);

        const state = await page.evaluate(() => {
          const cards = document.querySelectorAll('.package-card');
          if (cards.length < 3) return { disabled: true, text: 'cards-not-found' };
          const btn = cards[2].querySelector('button.buy-btn');
          if (!btn) return { disabled: true, text: 'btn-not-found' };
          return {
            disabled: btn.disabled || btn.className.includes('is-disabled'),
            text: btn.textContent.trim(),
          };
        });

        if (state.text !== lastText) {
          const elapsed = Math.round((Date.now() - startTime) / 1000);
          console.log(`[buy-max] 🔄 [${elapsed}s] 文本变化: "${lastText}" → "${state.text}"`);
          lastText = state.text;
        }

        if (!state.disabled) {
          const elapsed = Math.round((Date.now() - startTime) / 1000);
          console.log(`[buy-max] 🎉 [${elapsed}s] 按钮已启用！文本: "${state.text}"`);
          break;
        }

        const elapsed = Math.round((Date.now() - startTime) / 1000);
        if (elapsed - lastLogTime >= 30) {
          console.log(`[buy-max] 💓 [${elapsed}s] 仍在等待... 状态: "${state.text}"`);
          lastLogTime = elapsed;
        }
      }

      // 最终检查
      const finalState = await page.evaluate(() => {
        const cards = document.querySelectorAll('.package-card');
        const btn = cards.length >= 3 ? cards[2].querySelector('button.buy-btn') : null;
        return {
          disabled: btn ? (btn.disabled || btn.className.includes('is-disabled')) : true,
          text: btn ? btn.textContent.trim() : 'btn-gone',
        };
      });

      if (finalState.disabled) {
        const elapsed = Math.round((Date.now() - startTime) / 1000);
        return [{
          status: 'TIMEOUT',
          detail: `等待 ${elapsed}s 后按钮仍禁用: "${finalState.text}"`,
        }];
      }
    }

    // ──────────────────────────────────────────────
    // 8. 点击购买按钮
    // ──────────────────────────────────────────────
    console.log('[buy-max] 🖱️  点击 Max 购买按钮...');

    const clickResult = await page.evaluate(() => {
      const cards = document.querySelectorAll('.package-card');
      if (cards.length < 3) return { ok: false, error: 'cards not found' };
      const btn = cards[2].querySelector('button.buy-btn');
      if (!btn) return { ok: false, error: 'button not found' };
      if (btn.disabled || btn.className.includes('is-disabled')) {
        return { ok: false, error: `button still disabled: "${btn.textContent.trim()}"` };
      }
      // 滚动到可见
      btn.scrollIntoView({ behavior: 'instant', block: 'center' });
      btn.click();
      return { ok: true };
    });

    if (!clickResult.ok) {
      return [{ status: 'ERROR', detail: `点击失败: ${clickResult.error}` }];
    }

    console.log('[buy-max] ✅ 已点击购买按钮');

    // ──────────────────────────────────────────────
    // 9. 处理购买后弹窗
    // ──────────────────────────────────────────────
    await sleep(2000);

    // 最多处理 3 轮级联弹窗（仅处理购买确认，用户已实名认证无需认证弹窗）
    let dialogsHandled = [];
    for (let round = 0; round < 3; round++) {
      const actions = await page.evaluate(() => {
        const acts = [];
        document.querySelectorAll('[role="dialog"]').forEach(d => {
          if (d.offsetParent === null) return;
          d.querySelectorAll('button').forEach(b => {
            const t = b.textContent.trim();
            if (t === '已知悉，继续订阅') {
              b.click();
              acts.push('已确认套餐权益变更说明');
            } else if (t === '我知道了') {
              b.click();
              acts.push('关闭提示');
            }
          });
        });
        return acts;
      });

      if (actions.length === 0) break;
      for (const a of actions) {
        console.log(`[buy-max] 📋 [第${round + 1}轮] ${a}`);
        dialogsHandled.push(a);
      }
      await sleep(1500);
    }

    // 检查当前 URL
    const currentUrl = await page.evaluate(() => window.location.href);
    if (currentUrl.includes('pay') || currentUrl.includes('order') || currentUrl.includes('checkout')) {
      console.log(`[buy-max] 💳 已跳转到支付页面: ${currentUrl}`);
      dialogsHandled.push(`已跳转支付: ${currentUrl}`);
    } else {
      console.log(`[buy-max] 📍 当前 URL: ${currentUrl}`);
    }

    return [{
      status: 'SUCCESS',
      detail: `已触发 Max 套餐购买流程。${dialogsHandled.join(' | ') || '无后续弹窗'}`,
    }];
  },
});

// ──────────────────────────────────────────────────
// 工具函数：轮询直到条件满足
// ──────────────────────────────────────────────────
async function pollUntil(page, conditionFn, timeoutMs, intervalMs = 500) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const result = await page.evaluate(conditionFn);
      if (result) return true;
    } catch { /* 忽略 evaluate 错误，继续轮询 */ }
    await sleep(intervalMs);
  }
  return false;
}
