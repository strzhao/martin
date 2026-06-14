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
      { role: 'system', content: '你是 OCR 助手。识别图中的验证码字符（4-6 位数字字母）。只输出字符本身。' },
      { role: 'user', content: [
        { type: 'text', text: '/no_think 这是验证码图片，只输出图中字符。' },
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
  for (let i = 0; i < 3; i++) {
    const info = await page.evaluate(`
      (() => ({
        is_waf: /YunsuoAutoJump|网站防火墙/.test(document.documentElement.outerHTML),
        captcha_src: document.querySelector('img[alt="verify_img"]')?.src || '',
      }))()
    `);
    if (!info.is_waf) return true;
    if (!info.captcha_src) throw new Error('WAF 无 captcha');
    const cap = await ocrCaptcha(info.captcha_src);
    await page.evaluate(`document.cookie = 'srcurl=${stringToHex(targetUrl)};path=/;'`);
    const sep = targetUrl.includes('?') ? '&' : '?';
    await page.goto(targetUrl + sep + 'security_verify_img=' + stringToHex(cap), { waitUntil: 'load', settleMs: 2500 });
  }
  throw new Error('bypass 失败');
}

cli({
  site: 'zimuku',
  name: 'dump-dld',
  description: '抓 /dld/ 下载页结构，找真实下载 URL',
  access: 'read',
  example: 'opencli zimuku dump-dld 203164',
  domain: 'zimuku.org',
  strategy: Strategy.COOKIE,
  browser: true,
  args: [
    { name: 'dld_id', required: true, positional: true, help: 'dld id' },
  ],
  columns: ['kind', 'text'],
  func: async (page, args) => {
    const targetUrl = HOST + '/dld/' + args.dld_id + '.html';
    await ensureBypassed(page, targetUrl);

    const result = await page.evaluate(`
      (() => {
        const out = [];
        out.push({ kind: 'url', text: location.href });
        out.push({ kind: 'title', text: document.title });
        // 所有 a 含 down/load/dld/.zip/.rar/.7z/.srt/.ass 的
        const dlLinks = [...document.querySelectorAll('a')].filter(a =>
          /\\.zip|\\.rar|\\.7z|\\.srt|\\.ass|down|dld|backDown/i.test(a.href + a.textContent + (a.getAttribute('onclick') || ''))
        );
        out.push({ kind: 'dl-count', text: 'dl-ish links: ' + dlLinks.length });
        for (const a of dlLinks.slice(0, 15)) {
          out.push({ kind: 'dl', text: a.href + ' | onclick=' + (a.getAttribute('onclick') || '').slice(0,60) + ' | text=' + a.textContent.trim().slice(0,80) });
        }
        // .down 元素
        const downEls = [...document.querySelectorAll('.down, .downbtn, [class*="down"], button')];
        out.push({ kind: 'down-els', text: 'down-class count: ' + downEls.length });
        for (const e of downEls.slice(0, 8)) {
          out.push({ kind: 'down-el', text: e.outerHTML.slice(0, 250) });
        }
        // script 里的下载 URL
        const scripts = [...document.querySelectorAll('script')].map(s => s.textContent).join('\\n');
        const urlMatches = [...scripts.matchAll(/['\"]([^'\"]*(zip|rar|7z|srt|ass)[^'\"]*)['\"]/gi)];
        out.push({ kind: 'script-urls', text: 'count: ' + urlMatches.length });
        for (const m of urlMatches.slice(0, 10)) {
          out.push({ kind: 'script-url', text: m[1] });
        }
        // 抓所有 iframe（备用）
        const iframes = [...document.querySelectorAll('iframe')];
        for (const f of iframes) out.push({ kind: 'iframe', text: f.src });
        return out;
      })()
    `);
    return result;
  },
});
