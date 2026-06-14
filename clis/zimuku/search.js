import { cli, Strategy } from '@jackwener/opencli/registry';
import { HOST, ensureBypassed } from './_lib.js';

cli({
  site: 'zimuku',
  name: 'search',
  description: '在 zimuku 搜索字幕（自动 Yunsuo WAF bypass + Qwen captcha）',
  access: 'read',
  example: 'opencli zimuku search "暴裂无声" -f json',
  domain: 'zimuku.org',
  strategy: Strategy.COOKIE,
  browser: true,
  args: [
    { name: 'keyword', required: true, positional: true, help: '搜索关键词' },
    { name: 'limit', type: 'int', default: 20, help: '返回数量' },
  ],
  columns: ['detail_id', 'title', 'format', 'downloads', 'detail_url'],
  func: async (page, args) => {
    const targetUrl = HOST + '/search?q=' + encodeURIComponent(args.keyword);
    await ensureBypassed(page, targetUrl);

    const items = await page.evaluate(`
      (() => {
        const out = [];
        const seen = new Set();
        // 搜索页里 /detail/<id>.html 是单条字幕
        const links = [...document.querySelectorAll('a[href*="/detail/"]')];
        for (const a of links) {
          const m = (a.getAttribute('href') || '').match(/\\/detail\\/(\\d+)\\.html/);
          if (!m) continue;
          const did = m[1];
          if (seen.has(did)) continue;
          seen.add(did);
          // 取 tr 行作为元信息容器
          const row = a.closest('tr') || a.closest('li') || a.parentElement?.parentElement;
          const rowText = (row?.textContent || '').replace(/\\s+/g, ' ').trim();
          const title = a.textContent.trim() || a.getAttribute('title') || rowText.slice(0, 80);
          // 格式（ASS/SSA/SRT/VTT/SUB）
          const fmt = (rowText.match(/(ASS\\/SSA|ASS|SSA|SRT|VTT|SUB|ZIP|RAR|7Z)/i) || [])[1] || '';
          // 下载数（最后一个数字字段，通常 1-5 位）
          const dlNums = [...rowText.matchAll(/(\\d{1,6})/g)].map(x => parseInt(x[1], 10));
          const downloads = dlNums.length ? dlNums[dlNums.length - 1] : 0;
          out.push({
            detail_id: did,
            title: title,
            format: fmt,
            downloads,
            detail_url: 'https://zimuku.org/detail/' + did + '.html',
          });
        }
        return out;
      })()
    `);

    // 简体中文优先（标题里含「简」、「中文」、「CHS」等）
    items.sort((a, b) => {
      const score = s => {
        let v = 0;
        if (/简体|简中|CHS/i.test(s)) v += 10;
        else if (/繁体|繁中|CHT/i.test(s)) v += 5;
        else if (/中文|国语|中字/i.test(s)) v += 3;
        return v;
      };
      const sa = score(a.title), sb = score(b.title);
      if (sa !== sb) return sb - sa;
      return (b.downloads || 0) - (a.downloads || 0);
    });

    return items.slice(0, Number(args.limit) || 20);
  },
});
