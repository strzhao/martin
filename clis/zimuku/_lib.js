// 共享工具：Yunsuo WAF bypass + Qwen captcha OCR

export const HOST = 'https://zimuku.org';
export const QWEN_URL = 'http://127.0.0.1:8001/v1/chat/completions';
export const QWEN_KEY = 'qwen-local-key';
export const QWEN_MODEL = 'qwen3.6-35b';

export function stringToHex(str) {
  let val = '';
  for (let i = 0; i < str.length; i++) val += str.charCodeAt(i).toString(16);
  return val;
}

export async function ocrCaptcha(dataUri) {
  const body = {
    model: QWEN_MODEL,
    messages: [
      { role: 'system', content: '你是 OCR 助手。识别图中的验证码字符（通常 4-6 位数字字母）。只输出字符本身，不要任何解释、空格、标点。' },
      { role: 'user', content: [
        { type: 'text', text: '/no_think 这是网站验证码图片，只输出图中字符内容，保持原大小写。' },
        { type: 'image_url', image_url: { url: dataUri } },
      ]},
    ],
    temperature: 0, max_tokens: 800,
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
  const m1 = [...content.matchAll(/[A-Za-z0-9]{3,8}/g)].map(x => x[0]);
  if (m1.length) return m1[m1.length - 1];
  const m2 = [...reasoning.matchAll(/[A-Za-z0-9]{3,8}/g)].map(x => x[0]);
  if (m2.length) return m2[m2.length - 1];
  throw new Error('Qwen OCR 空：content=' + JSON.stringify(content).slice(0, 200));
}

/**
 * 确保 page 已通过 Yunsuo WAF：访问 targetUrl，如遇 captcha → Qwen OCR → 模拟提交 → 重试。
 * 成功后 page 已停在目标页（DOM 含真实内容）。
 */
export async function ensureBypassed(page, targetUrl, maxTries = 3) {
  await page.goto(targetUrl, { waitUntil: 'load', settleMs: 1500 });
  for (let attempt = 0; attempt < maxTries; attempt++) {
    const info = await page.evaluate(`
      (() => ({
        is_waf: /YunsuoAutoJump|网站防火墙/.test(document.documentElement.outerHTML),
        captcha_src: document.querySelector('img[alt="verify_img"]')?.src || '',
      }))()
    `);
    if (!info.is_waf) return;
    if (!info.captcha_src) throw new Error('Yunsuo WAF 页但找不到 captcha img');
    const cap = await ocrCaptcha(info.captcha_src);
    const srcurlHex = stringToHex(targetUrl);
    const capHex = stringToHex(cap);
    await page.evaluate(`document.cookie = 'srcurl=${srcurlHex};path=/;'`);
    const sep = targetUrl.includes('?') ? '&' : '?';
    const verifyUrl = targetUrl + sep + 'security_verify_img=' + capHex;
    await page.goto(verifyUrl, { waitUntil: 'load', settleMs: 2500 });
  }
  throw new Error('Yunsuo WAF bypass 重试 ' + maxTries + ' 次仍未通过');
}
