import { cli, Strategy } from '@jackwener/opencli/registry';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { HOST, ensureBypassed } from './_lib.js';

cli({
  site: 'zimuku',
  name: 'download',
  description: 'zimuku 字幕全自动下载（Yunsuo WAF bypass）',
  access: 'read',
  example: 'opencli zimuku download 203164 --out /tmp/sub.ass',
  domain: 'zimuku.org',
  strategy: Strategy.COOKIE,
  browser: true,
  args: [
    { name: 'detail_id', required: true, positional: true, help: '字幕 detail id（数字）' },
    { name: 'out', help: '输出路径；省略则按 CDN 文件名落 ~/Downloads' },
  ],
  columns: ['detail_id', 'path', 'bytes', 'url'],
  func: async (page, args) => {
    const did = args.detail_id;
    // 1) 访问 detail 页（顺带 bypass）
    const detailUrl = HOST + '/detail/' + did + '.html';
    await ensureBypassed(page, detailUrl);

    // 2) 跳到 dld 高速下载页（同 id）
    const dldUrl = HOST + '/dld/' + did + '.html';
    await ensureBypassed(page, dldUrl);

    // 3) 拿所有可用 mirror（5 个左右）
    const mirrors = await page.evaluate(`
      (() => {
        const links = [...document.querySelectorAll('.down a[href*="/download/"], a[href*="/download/"]')];
        return links.map(a => a.href);
      })()
    `);
    if (!mirrors.length) throw new Error('未找到下载 mirror 链接');

    // 4) 依次试 mirror，取第一个返回二进制的
    let lastErr = '';
    for (const mirror of mirrors) {
      const result = await page.evaluate(`
        (async () => {
          try {
            const r = await fetch(${JSON.stringify(mirror)}, {credentials:'include', redirect:'follow'});
            if (!r.ok) return { err: 'HTTP ' + r.status };
            const ct = r.headers.get('content-type') || '';
            // 文件名：从 Content-Disposition 提取
            const cd = r.headers.get('content-disposition') || '';
            const fnMatch = cd.match(/filename\\*=UTF-8''([^;]+)|filename="?([^";]+)"?/i);
            let filename = '';
            if (fnMatch) filename = decodeURIComponent(fnMatch[1] || fnMatch[2] || '');
            // 文件内容
            const buf = new Uint8Array(await r.arrayBuffer());
            let bin = '';
            for (let i = 0; i < buf.length; i++) bin += String.fromCharCode(buf[i]);
            return {
              b64: btoa(bin),
              bytes: buf.length,
              content_type: ct,
              filename,
              final_url: r.url,
            };
          } catch (e) {
            return { err: String(e) };
          }
        })()
      `);
      if (result.err) { lastErr = result.err; continue; }
      // 校验：不能是 HTML（被 WAF/重定向到登录页）
      const first16 = Buffer.from(result.b64, 'base64').slice(0, 32).toString('utf8');
      if (/<!DOCTYPE|<html|YunsuoAutoJump/i.test(first16)) {
        lastErr = 'mirror 返回 HTML 而非二进制：' + result.final_url;
        continue;
      }
      // 决定输出路径
      const filename = result.filename || `zimuku_${did}.bin`;
      const outPath = args.out ? path.resolve(args.out) : path.join(os.homedir(), 'Downloads', filename);
      fs.mkdirSync(path.dirname(outPath), { recursive: true });
      fs.writeFileSync(outPath, Buffer.from(result.b64, 'base64'));
      return [{ detail_id: did, path: outPath, bytes: result.bytes, url: result.final_url }];
    }
    throw new Error('所有 mirror 失败：' + lastErr);
  },
});
