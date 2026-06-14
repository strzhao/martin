import { cli, Strategy } from '@jackwener/opencli/registry';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const HOST = 'https://subhd.tv';
const QWEN_URL = 'http://127.0.0.1:8001/v1/chat/completions';
const QWEN_KEY = 'qwen-local-key';
const QWEN_MODEL = 'qwen3.6-35b';

async function renderCaptchaPng(page, svg, sid) {
  await page.evaluate(`
    (() => {
      let host = document.getElementById('__captcha_host');
      if (!host) {
        host = document.createElement('div');
        host.id = '__captcha_host';
        host.style.cssText = 'position:fixed;top:0;left:0;background:#fff;padding:20px;z-index:2147483647;';
        document.body.appendChild(host);
      }
      host.innerHTML = ${JSON.stringify(svg)}.replace(/<svg[^>]*>/, '<svg xmlns="http://www.w3.org/2000/svg" width="600" height="200" viewBox="0 0 150 50">');
    })()
  `);
  const pngPath = `/tmp/subhd_captcha_${sid}.png`;
  await page.screenshot({ path: pngPath, clip: { x: 0, y: 0, width: 640, height: 240 } });
  return pngPath;
}

async function ocrWithQwen(pngPath) {
  const b64 = fs.readFileSync(pngPath).toString('base64');
  const body = {
    model: QWEN_MODEL,
    messages: [
      { role: 'system', content: '你是 OCR 助手。用户上传验证码图片，你识别后只输出 4 个字符（保持原始大小写），不要任何解释或标点。' },
      { role: 'user', content: [
        { type: 'text', text: '/no_think 这张图左上角白色框里有 4 个手写体字符（A-Z 大小写或 0-9）。只输出这 4 个字符，保持原大小写。' },
        { type: 'image_url', image_url: { url: 'data:image/png;base64,' + b64 } },
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
  if (!r.ok) throw new Error(`Qwen HTTP ${r.status}: ${(await r.text()).slice(0,200)}`);
  const j = await r.json();
  const content = j.choices?.[0]?.message?.content || '';
  const m = content.match(/[A-Za-z0-9]{4}/);
  if (m) return m[0];
  const reasoning = j.choices?.[0]?.message?.reasoning_content || '';
  const m2 = reasoning.match(/[A-Za-z0-9]{4}/g);
  if (m2 && m2.length) return m2[m2.length - 1];
  throw new Error(`Qwen 未返回 4 字符：content=${JSON.stringify(content).slice(0,200)}`);
}

cli({
  site: 'subhd',
  name: 'download',
  description: 'SubHD 字幕全自动下载（本地 Qwen 多模态自动解 SVG captcha）',
  access: 'read',
  example: 'opencli subhd download rvX6QC --out /tmp/sub.ass',
  domain: 'subhd.tv',
  strategy: Strategy.PUBLIC,
  browser: true,
  args: [
    { name: 'sid', required: true, positional: true, help: '字幕 ID' },
    { name: 'out', help: '本地输出路径；省略则按 CDN 文件名落 ~/Downloads' },
    { name: 'cap', default: '', help: '手动覆盖验证码（一般留空）' },
    { name: 'max-cap-tries', type: 'int', default: 3, help: 'captcha 自动解最大重试次数' },
  ],
  columns: ['sid', 'path', 'bytes', 'url'],
  func: async (page, args) => {
    if (!(await page.evaluate(`location.host`)).includes('subhd')) {
      await page.goto(HOST + '/', { waitUntil: 'load', settleMs: 500 });
    }

    const maxTries = Number(args['max-cap-tries']) || 3;

    const apiCall = async (cap) => {
      return await page.evaluate(`
        (async () => {
          const sid = ${JSON.stringify(args.sid)};
          const cap = ${JSON.stringify(cap)};
          if (!cap) {
            const pageRes = await fetch('${HOST}/down/' + sid, {credentials:'include'});
            if (!pageRes.ok) return {err: 'visit /down failed: ' + pageRes.status};
            await pageRes.text();
          }
          const r = await fetch('${HOST}/api/sub/down', {
            method:'POST', credentials:'include',
            headers:{'Content-Type':'application/json','Referer':'${HOST}/down/'+sid},
            body: JSON.stringify({sid, cap})
          });
          return await r.json();
        })()
      `);
    };

    let body = await apiCall(args.cap || '');
    let triesLeft = maxTries;

    while (body && body.success && body.pass === false) {
      if (triesLeft-- <= 0) throw new Error('captcha 重试超过 max-cap-tries 次');
      const pngPath = await renderCaptchaPng(page, body.msg, args.sid);
      const cap = await ocrWithQwen(pngPath);
      console.error(`[captcha] Qwen 识别 → ${cap}`);
      body = await apiCall(cap);
    }

    if (!body || !body.success) {
      throw new Error('api fail: ' + (body?.msg?.slice(0,100) || 'unknown'));
    }
    if (!body.url) {
      throw new Error('no url in response: ' + JSON.stringify(body).slice(0,200));
    }

    const cdnUrl = body.url;
    const fileBody = await page.evaluate(`
      (async () => {
        const r = await fetch(${JSON.stringify(cdnUrl)}, {credentials:'omit'});
        if (!r.ok) return {err: 'cdn fetch ' + r.status};
        const buf = new Uint8Array(await r.arrayBuffer());
        let bin = '';
        for (let i=0;i<buf.length;i++) bin += String.fromCharCode(buf[i]);
        return {b64: btoa(bin), bytes: buf.length};
      })()
    `);
    if (fileBody.err) throw new Error(fileBody.err);

    const filename = path.basename(new URL(cdnUrl).pathname);
    const outPath = args.out
      ? path.resolve(args.out)
      : path.join(os.homedir(), 'Downloads', filename);
    fs.mkdirSync(path.dirname(outPath), { recursive: true });
    fs.writeFileSync(outPath, Buffer.from(fileBody.b64, 'base64'));

    return [{ sid: args.sid, path: outPath, bytes: fileBody.bytes, url: cdnUrl }];
  },
});
