import { cli, Strategy } from '@jackwener/opencli/registry';

const HOST = 'https://subhd.tv';

cli({
  site: 'subhd',
  name: 'debug',
  description: '诊断：返回 SubHD search 的原始 HTML（前 5000 字符）',
  access: 'read',
  example: 'opencli subhd debug "暴裂无声"',
  domain: 'subhd.tv',
  strategy: Strategy.PUBLIC,
  browser: true,
  args: [
    { name: 'keyword', required: true, positional: true, help: '搜索关键词' },
  ],
  columns: ['len', 'preview', 'has_a_links', 'title_in_html', 'login_required'],
  func: async (page, args) => {
    if (!(await page.evaluate(`location.host`)).includes('subhd')) {
      await page.goto(HOST + '/', { waitUntil: 'load', settleMs: 800 });
    }

    const result = await page.evaluate(`
      (async () => {
        const r = await fetch('${HOST}/search/' + encodeURIComponent(${JSON.stringify(args.keyword)}), {credentials:'include'});
        const html = await r.text();
        const len = html.length;
        const preview = html.slice(0, 1500);
        const hasALinks = (html.match(/href="\\/a\\//g) || []).length;
        const titleMatch = html.match(/<title>([\\s\\S]*?)<\\/title>/);
        const titleInHtml = titleMatch ? titleMatch[1].trim() : '';
        const loginRequired = /\\bsign[- ]?in|\\b登录\\b|\\b请先登录|\\bcaptcha\\b/i.test(html);
        return { len, preview, has_a_links: hasALinks, title_in_html: titleInHtml, login_required: loginRequired };
      })()
    `);
    return [result];
  },
});
