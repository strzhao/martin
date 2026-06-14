import { cli, Strategy } from '@jackwener/opencli/registry';

const HOST = 'https://zimuku.org';
const QWEN_URL = 'http://127.0.0.1:8001/v1/chat/completions';
const QWEN_KEY = 'qwen-local-key';
const QWEN_MODEL = 'qwen3.6-35b';

function stringToHex(str) {
  let val = '';
  for (let i = 0; i < str.length; i++) val += str.charCodeAt(i).toString(16);
  return val;
}

async function ocrCaptcha(dataUri) {
  const body = {
    model: QWEN_MODEL,
    messages: [
      { role: 'system', content: '你是 OCR 助手。识别图中的验证码字符（通常 4-6 位数字字母）。只输出字符本身，不要任何标点空格解释。' },
      { role: 'user', content: [
        { type: 'text', text: '/no_think 这是一张验证码图片，只输出图中字符内容，保持原大小写。' },
        { type: 'image_url', image_url: { url: dataUri } },
      ]},
    ],
    temperature: 0, max_tokens: 800,
  };
  const r = await fetch(QWEN_URL, { method:'POST', headers:{'Authorization':'Bearer '+QWEN_KEY,'Content-Type':'application/json'}, body: JSON.stringify(body) });
  const j = await r.json();
  const content = j.choices?.[0]?.message?.content || '';
  const reasoning = j.choices?.[0]?.message?.reasoning_content || '';
  const m1 = [...content.matchAll(/[A-Za-z0-9]{3,8}/g)].map(x => x[0]);
  if (m1.length) return m1[m1.length-1];
  const m2 = [...reasoning.matchAll(/[A-Za-z0-9]{3,8}/g)].map(x => x[0]);
  if (m2.length) return m2[m2.length-1];
  throw new Error('OCR 空');
}

async function ensureBypassed(page, targetUrl) {
  await page.goto(targetUrl, { waitUntil: 'load', settleMs: 1500 });
  for (let attempt = 0; attempt < 3; attempt++) {
    const info = await page.evaluate(`
      (() => ({
        is_waf: /YunsuoAutoJump|网站防火墙/.test(document.documentElement.outerHTML),
        captcha_src: document.querySelector('img[alt="verify_img"]')?.src || '',
      }))()
    `);
    if (!info.is_waf) return true;
    if (!info.captcha_src) throw new Error('WAF 页但无 captcha img');
    const cap = await ocrCaptcha(info.captcha_src);
    const srcurlHex = stringToHex(targetUrl);
    const capHex = stringToHex(cap);
    await page.evaluate(`document.cookie = 'srcurl=${srcurlHex};path=/;'`);
    const sep = targetUrl.includes('?') ? '&' : '?';
    await page.goto(targetUrl + sep + 'security_verify_img=' + capHex, { waitUntil: 'load', settleMs: 2500 });
  }
  throw new Error('WAF bypass 重试 3 次仍未通过');
}

cli({
  site: 'zimuku',
  name: 'dump',
  description: '抓 zimuku 搜索页前 5 个结果项 HTML，定位 selector',
  access: 'read',
  example: 'opencli zimuku dump "暴裂无声"',
  domain: 'zimuku.org',
  strategy: Strategy.COOKIE,
  browser: true,
  args: [
    { name: 'keyword', required: true, positional: true, help: '搜索关键词' },
  ],
  columns: ['kind', 'text'],
  func: async (page, args) => {
    const targetUrl = HOST + '/search?q=' + encodeURIComponent(args.keyword);
    await ensureBypassed(page, targetUrl);

    const result = await page.evaluate(`
      (() => {
        const out = [];
        // 找所有候选容器：detail/subs/sub 路径的 <a>
        const links = [...document.querySelectorAll('a[href*="/detail/"], a[href*="/subs/"], a[href*="/down/"]')];
        out.push({ kind: 'count', text: 'a[detail|subs|down] count: ' + links.length });
        // 取前 5 个
        for (let i = 0; i < Math.min(5, links.length); i++) {
          const a = links[i];
          const row = a.closest('tr, li, .item, .clearfix, .table-responsive tbody tr, .sublist') || a.parentElement?.parentElement || a.parentElement;
          out.push({ kind: 'link', text: a.href + ' :: ' + a.textContent.trim().slice(0, 80) });
          out.push({ kind: 'row-tag', text: row?.tagName + '.' + (row?.className || '').slice(0, 60) });
          out.push({ kind: 'row-text', text: (row?.textContent || '').replace(/\\s+/g, ' ').trim().slice(0, 250) });
          out.push({ kind: '---', text: '' });
        }
        // 给个 body snapshot for selector exploration
        const main = document.querySelector('.container, .main, body');
        out.push({ kind: 'body-len', text: '' + document.documentElement.outerHTML.length });
        return out;
      })()
    `);
    return result;
  },
});
