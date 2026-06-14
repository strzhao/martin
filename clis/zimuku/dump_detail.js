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
  throw new Error('WAF bypass 重试 3 次未通过');
}

cli({
  site: 'zimuku',
  name: 'dump-detail',
  description: '抓 detail 页结构，找下载链接',
  access: 'read',
  example: 'opencli zimuku dump-detail 203164',
  domain: 'zimuku.org',
  strategy: Strategy.COOKIE,
  browser: true,
  args: [
    { name: 'detail_id', required: true, positional: true, help: 'detail id（数字部分）' },
  ],
  columns: ['kind', 'text'],
  func: async (page, args) => {
    const targetUrl = HOST + '/detail/' + args.detail_id + '.html';
    await ensureBypassed(page, targetUrl);

    const result = await page.evaluate(`
      (() => {
        const out = [];
        // 所有 a 链接（绝对路径）
        const allA = [...document.querySelectorAll('a')];
        out.push({ kind: 'count', text: 'all <a> count: ' + allA.length });
        // 含 down/load/dld 的链接
        const dlLinks = allA.filter(a => /down|load|dld|\\.zip|\\.rar|\\.7z|\\.srt|\\.ass/i.test(a.href + a.textContent));
        out.push({ kind: 'dl-count', text: 'download-ish links: ' + dlLinks.length });
        for (const a of dlLinks.slice(0, 20)) {
          out.push({ kind: 'dl-link', text: a.href + ' :: ' + a.textContent.trim().slice(0, 80) });
        }
        // 标题 + meta
        out.push({ kind: 'title', text: document.title });
        out.push({ kind: 'h1', text: document.querySelector('h1, h2, .title, .file_name')?.textContent.trim().slice(0, 100) || '' });
        // button-style 下载
        const buttons = [...document.querySelectorAll('button, .btn, [class*="download"], [id*="download"]')];
        out.push({ kind: 'btn-count', text: 'buttons: ' + buttons.length });
        for (const b of buttons.slice(0, 10)) {
          out.push({ kind: 'btn', text: b.outerHTML.slice(0, 200) });
        }
        return out;
      })()
    `);
    return result;
  },
});
