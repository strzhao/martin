import { cli, Strategy } from '@jackwener/opencli/registry';

const HOST = 'https://zimuku.org';

cli({
  site: 'zimuku',
  name: 'probe',
  description: '诊断 2：抓 Yunsuo captcha 页里所有 img/script/form 元素，定位验证码图片',
  access: 'read',
  example: 'opencli zimuku probe',
  domain: 'zimuku.org',
  strategy: Strategy.COOKIE,
  browser: true,
  args: [],
  columns: ['kind', 'src_or_text'],
  func: async (page, args) => {
    await page.goto(HOST + '/', { waitUntil: 'load', settleMs: 1500 });
    const items = await page.evaluate(`
      (() => {
        const out = [];
        document.querySelectorAll('img').forEach(img => {
          out.push({ kind: 'img', src_or_text: img.src + ' | alt=' + img.alt + ' | w=' + img.naturalWidth + 'x' + img.naturalHeight });
        });
        document.querySelectorAll('input').forEach(inp => {
          out.push({ kind: 'input', src_or_text: 'id=' + inp.id + ' name=' + inp.name + ' type=' + inp.type });
        });
        document.querySelectorAll('form').forEach(f => {
          out.push({ kind: 'form', src_or_text: 'action=' + f.action + ' method=' + f.method });
        });
        document.querySelectorAll('script').forEach(s => {
          const t = s.textContent.slice(0, 200);
          if (t.includes('verify') || t.includes('captcha') || t.includes('yunsuo') || t.includes('Hex') || t.includes('img')) {
            out.push({ kind: 'script', src_or_text: t.replace(/\\s+/g,' ') });
          }
        });
        // 当前 URL
        out.unshift({ kind: 'url', src_or_text: location.href });
        out.unshift({ kind: 'cookie', src_or_text: document.cookie });
        return out;
      })()
    `);
    return items;
  },
});
