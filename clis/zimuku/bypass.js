import { cli, Strategy } from '@jackwener/opencli/registry';

const HOST = 'https://zimuku.org';
const QWEN_URL = 'http://127.0.0.1:8001/v1/chat/completions';
const QWEN_KEY = 'qwen-local-key';
const QWEN_MODEL = 'qwen3.6-35b';

function stringToHex(str) {
  let val = '';
  for (let i = 0; i < str.length; i++) {
    val += str.charCodeAt(i).toString(16);
  }
  return val;
}

async function ocrCaptcha(dataUri) {
  const body = {
    model: QWEN_MODEL,
    messages: [
      { role: 'system', content: '你是一个 OCR 助手。识别图中的验证码字符（通常是 4-6 位数字和字母混合）。只输出字符本身，不要任何解释、空格、标点。' },
      { role: 'user', content: [
        { type: 'text', text: '/no_think 这是一张网站验证码图片（黑底白字或白底黑字），含字母数字字符。只输出字符内容，保持原大小写。' },
        { type: 'image_url', image_url: { url: dataUri } },
      ]},
    ],
    temperature: 0,
    max_tokens: 800,
  };
  const r = await fetch(QWEN_URL, {
    method: 'POST',
    headers: { 'Authorization': 'Bearer ' + QWEN_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error('Qwen HTTP ' + r.status + ': ' + (await r.text()).slice(0, 200));
  const j = await r.json();
  const content = j.choices?.[0]?.message?.content || '';
  const reasoning = j.choices?.[0]?.message?.reasoning_content || '';
  // 抓最长一段连续的字母数字
  const candidates = [...content.matchAll(/[A-Za-z0-9]{3,8}/g)].map(m => m[0]);
  if (candidates.length) return { cap: candidates[candidates.length - 1], raw: content, source: 'content' };
  const candidates2 = [...reasoning.matchAll(/[A-Za-z0-9]{3,8}/g)].map(m => m[0]);
  if (candidates2.length) return { cap: candidates2[candidates2.length - 1], raw: reasoning.slice(0, 300), source: 'reasoning' };
  throw new Error('Qwen 未返回字母数字字符：content=' + JSON.stringify(content).slice(0, 200));
}

cli({
  site: 'zimuku',
  name: 'bypass',
  description: '一次性 WAF bypass：访问首页 → 解 captcha → 拿到 session → 再请求一次验证',
  access: 'read',
  example: 'opencli zimuku bypass',
  domain: 'zimuku.org',
  strategy: Strategy.COOKIE,
  browser: true,
  args: [
    { name: 'target', positional: true, default: '/', help: '目标路径（默认 /）' },
  ],
  columns: ['stage', 'note'],
  func: async (page, args) => {
    const out = [];
    // Yunsuo 期望 srcurl 是 percent-encoded URL 的 hex（即对每个 ASCII 字节 hex）
    // 所以中文先 encodeURI 一下
    const rawPath = args.target.startsWith('/') ? args.target : '/' + args.target;
    const targetUrl = HOST + encodeURI(rawPath).replace(/%5B/g, '[').replace(/%5D/g, ']');

    // 1) 访问目标
    await page.goto(targetUrl, { waitUntil: 'load', settleMs: 1500 });
    let info = await page.evaluate(`
      (() => ({
        is_waf: /网站防火墙|YunsuoAutoJump|security_verify_img/.test(document.documentElement.outerHTML),
        captcha_src: document.querySelector('img[alt="verify_img"]')?.src || '',
        url: location.href,
        title: document.title,
      }))()
    `);
    out.push({ stage: '1-visit', note: JSON.stringify(info).slice(0, 200) });

    if (!info.is_waf) {
      out.push({ stage: 'done', note: '未触发 WAF，直接放行' });
      return out;
    }

    // 2) OCR
    if (!info.captcha_src) {
      out.push({ stage: 'fail', note: '没找到 verify_img 图' });
      return out;
    }
    const ocr = await ocrCaptcha(info.captcha_src);
    out.push({ stage: '2-ocr', note: `cap="${ocr.cap}" source=${ocr.source} raw=${JSON.stringify(ocr.raw).slice(0, 100)}` });

    // 3) 模拟提交：设置 cookie srcurl=hex(percent-encoded targetUrl)，访问 /<targetUrl>?security_verify_img=hex(cap)
    const srcurlHex = stringToHex(targetUrl);
    const capHex = stringToHex(ocr.cap);
    await page.evaluate(`document.cookie = 'srcurl=${srcurlHex};path=/;'`);

    const sep = targetUrl.includes('?') ? '&' : '?';
    const verifyUrl = targetUrl + sep + 'security_verify_img=' + capHex;
    out.push({ stage: '3a-verify-url', note: verifyUrl });
    await page.goto(verifyUrl, { waitUntil: 'load', settleMs: 2500 });

    const after = await page.evaluate(`
      (() => ({
        is_waf: /网站防火墙|YunsuoAutoJump|security_verify_img/.test(document.documentElement.outerHTML),
        url: location.href,
        title: document.title,
        body_len: document.documentElement.outerHTML.length,
        has_search_results: !!document.querySelector('a[href*="/detail/"], a[href*="/subs/"]'),
        cookies: document.cookie,
      }))()
    `);
    out.push({ stage: '3b-after-verify', note: JSON.stringify(after).slice(0, 400) });

    // 4) 再 fetch 一次原 URL 看是否还要 captcha
    const retry = await page.evaluate(`
      (async () => {
        const r = await fetch(${JSON.stringify(targetUrl)}, {credentials:'include'});
        const html = await r.text();
        return {
          status: r.status,
          len: html.length,
          is_waf: /网站防火墙|YunsuoAutoJump/.test(html),
          has_results: /\\/(detail|subs)\\//.test(html),
          title: (html.match(/<title>([\\s\\S]*?)<\\/title>/) || [,''])[1],
          cookies: document.cookie,
        };
      })()
    `);
    out.push({ stage: '4-retry-fetch', note: JSON.stringify(retry).slice(0, 400) });

    return out;
  },
});
