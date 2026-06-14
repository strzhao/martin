import { cli, Strategy } from '@jackwener/opencli/registry';

const HOST = 'https://subhd.tv';

cli({
  site: 'subhd',
  name: 'search',
  description: '在 SubHD 搜索字幕（按下载量排序）',
  access: 'read',
  example: 'opencli subhd search "暴裂无声" -f json',
  domain: 'subhd.tv',
  strategy: Strategy.PUBLIC,
  browser: true,
  args: [
    { name: 'keyword', required: true, positional: true, help: '搜索关键词（电影名）' },
    { name: 'limit', type: 'int', default: 20, help: '返回字幕数量上限' },
  ],
  columns: ['title', 'movie', 'language', 'format', 'downloads', 'sid'],
  func: async (page, args) => {
    // 必须先在 subhd 域名下，才能用 fetch（避免跨域 + cookies 上下文）
    if (!(await page.evaluate(`location.host`)).includes('subhd')) {
      await page.goto(HOST + '/', { waitUntil: 'load', settleMs: 500 });
    }

    const html = await page.evaluate(`
      (async () => {
        const r = await fetch('${HOST}/search/' + encodeURIComponent(${JSON.stringify(args.keyword)}), {credentials:'include'});
        return await r.text();
      })()
    `);

    const rows = await page.evaluate(`
      (() => {
        const doc = new DOMParser().parseFromString(${JSON.stringify(html)}, 'text/html');
        const out = [];
        // 字幕列表项：通常是 .sublist-row 或带 /a/<id> 的 a 标签
        // 通过 a[href^="/a/"] 反推容器
        const seenSid = new Set();
        doc.querySelectorAll('a[href^="/a/"]').forEach(a => {
          const m = (a.getAttribute('href') || '').match(/^\\/a\\/([A-Za-z0-9_-]+)/);
          if (!m) return;
          const sid = m[1];
          if (seenSid.has(sid)) return;
          seenSid.add(sid);
          // 容器（卡片）
          const row = a.closest('.row, .sublist-row, .panel-body, li, tr, div.box') || a.parentElement?.parentElement || a.parentElement;
          const text = (row?.textContent || a.textContent || '').replace(/\\s+/g,' ').trim();
          // 标题：最长候选（通常是带 release group 的字幕名）
          const candidates = [...(row?.querySelectorAll('a, h2, h3, span') || [])]
            .map(e => (e.textContent || '').trim())
            .filter(t => t.length > 2);
          const title = candidates.sort((a,b)=>b.length-a.length)[0] || a.textContent.trim();
          // 语言
          const lang = (text.match(/简体[繁體|繁体|英文]?|繁体|繁體|双语|英语|英文|EN|CHS|CHT/i) || [])[0] || '';
          // 格式
          const fmt = (text.match(/SRT|ASS|SSA|VTT|SUB/i) || [])[0] || '';
          // 下载量（找数字 + "下载" 字样）
          const dlMatch = text.match(/下载\\s*(\\d+)|(\\d{2,})\\s*下载|(\\d+)\\s*次/);
          const downloads = parseInt(dlMatch?.[1] || dlMatch?.[2] || dlMatch?.[3] || '0', 10);
          // 电影名（detail page url alt）
          const imgAlt = row?.querySelector('img[alt]')?.getAttribute('alt') || '';
          out.push({ sid, title, movie: imgAlt, language: lang, format: fmt, downloads,
                     detail_url: 'https://subhd.tv/a/' + sid });
        });
        return out;
      })()
    `);

    // SubHD 搜索结果是按相关度，不一定按下载量；保留原序，但下载量靠前优先
    rows.sort((a, b) => b.downloads - a.downloads);
    return rows.slice(0, Number(args.limit) || 20);
  },
});
