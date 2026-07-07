import { cli, Strategy } from '@jackwener/opencli/registry';

const HOST = 'https://www.xn--wcv59z.com';

cli({
  site: 'jiaofu',
  name: 'detail',
  description: '获取教父站影片详情页：豆瓣/IMDb评分、首播日期、导演主演、简介、磁力资源',
  access: 'read',
  example: 'opencli jiaofu detail /tv/lDVn -f json',
  domain: 'www.xn--wcv59z.com',
  strategy: Strategy.COOKIE,
  browser: true,
  args: [
    { name: 'path', required: true, positional: true, help: '详情页路径（/tv/xxx 或 /mv/xxx）或完整 URL' },
  ],
  columns: ['title', 'douban', 'imdb', 'rating_count', 'first_air_date', 'director', 'cast', 'series_meta', 'synopsis', 'magnets'],
  func: async (page, args) => {
    const detailUrl = args.path.startsWith('http') ? args.path : `${HOST}${args.path}`;
    await page.goto(detailUrl, { waitUntil: 'load', settleMs: 1500 });
    await page.wait({ selector: '.ratings-section, a[href^="magnet:"]', timeout: 10 }).catch(() => {});

    const data = await page.evaluate(`
      (() => {
        const out = { title:'', douban:'', imdb:'', rating_count:'', first_air_date:'',
                      director:'', cast:'', series_meta:'', updated:'', synopsis:'', magnets:[] };
        out.title = (document.querySelector('h1')?.innerText || '').trim();

        // 评分区：.ratings-section 下多个 .rating-item（豆瓣 / IMDb）
        document.querySelectorAll('.rating-item').forEach(ri => {
          const src = (ri.querySelector('.rating-source')?.innerText || '').trim();
          const autoText = (ri.querySelector('.rating-auto')?.innerText || '').trim();
          const score = (autoText.match(/^\\d+(?:\\.\\d+)?/) || [])[0] || '';
          const count = (ri.querySelector('.rating-count')?.innerText || '').trim();
          if (/豆瓣/.test(src)) { out.douban = score; out.rating_count = count; }
          else if (/IMDb|IM/.test(src)) { out.imdb = score; }
        });

        // 元数据从 body 文本提取（首播/导演/主演/更新时间）
        const info = document.body.innerText || '';
        let m;
        if (m = info.match(/(?:首播|上映|首映)[：:]\\s*(\\d{4}-\\d{2}-\\d{2})/)) out.first_air_date = m[1];
        if (m = info.match(/导演[：:]\\s*([^\\n]+)/)) out.director = m[1].trim();
        if (m = info.match(/主演[：:]\\s*([^\\n]+)/)) out.cast = m[1].trim();
        if (m = info.match(/最后更新于([^，,\\n]+)/)) out.updated = m[1].trim();
        if (m = info.match(/(\\d+集\\s*\\/[^\\n]{0,30})/)) out.series_meta = m[1].replace(/\\s+/g,' ').trim();

        // 简介：「剧集简介」/「电影简介」之后；页面常在简介前插 VPN 广告（以 × 收尾），跳过
        const synRaw = info.split(/(?:剧集|电影)简介/)[1] || '';
        const synClean = synRaw.includes('×') ? synRaw.split('×').slice(1).join('×') : synRaw;
        out.synopsis = synClean.replace(/\\s+/g, ' ').trim().slice(0, 280);

        // 磁力资源（沿用 search.js 的行解析逻辑，按 URL 去重）
        const seenMagnet = new Set();
        document.querySelectorAll('a[href^="magnet:"]').forEach(a => {
          if (seenMagnet.has(a.href)) return;
          const tr = a.closest('tr');
          if (!tr) return;
          seenMagnet.add(a.href);
          const cells = tr.querySelectorAll('td');
          const t = (cells[0]?.innerText || '').replace(/详情[\\s\\S]*$/, '').replace(/\\s+/g, ' ').trim();
          const size = (cells[2]?.innerText || '').trim();
          const seeds = parseInt((cells[3]?.innerText || '0').trim(), 10) || 0;
          out.magnets.push({ title: t, size, seeds, magnet: a.href });
        });
        return out;
      })()
    `);
    return data;
  },
});
