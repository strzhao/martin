import { cli, Strategy } from '@jackwener/opencli/registry';

const URL_BASE = 'https://ktt.pinduoduo.com/groups/detail/';
const RE_DETAIL_URL = /ktt\.pinduoduo\.com\/groups\/detail\/([A-Za-z0-9_-]+)/;
const RE_GROUP_ID = /^[A-Za-z0-9_-]+$/;

cli({
  site: 'ktt',
  name: 'detail',
  description: '获取快团团 groups/detail 页面的标题与正文内容（markdown）',
  access: 'read',
  example: 'opencli ktt detail https://ktt.pinduoduo.com/groups/detail/177nbjcrf-4fRCrJot7_wKdlX6Tbfhuw -f plain  # 或 -f json | jq -r \'.[0] | "# "+.title+"\\n\\n"+.content\' 输出完整 markdown 文档',
  domain: 'ktt.pinduoduo.com',
  strategy: Strategy.COOKIE,
  browser: true,
  args: [
    { name: 'target', required: true, positional: true, help: '完整链接，或末尾的 group_no（如 177nbjcrf-4fRCrJot7_wKdlX6Tbfhuw）' },
  ],
  columns: ['title', 'content'],
  func: async (page, args) => {
    const raw = String(args.target || '').trim();
    let groupNo = '';
    const m = raw.match(RE_DETAIL_URL);
    if (m) groupNo = m[1];
    else if (RE_GROUP_ID.test(raw)) groupNo = raw;
    else throw new Error(`无法解析 group_no: ${raw}`);

    const url = URL_BASE + groupNo;
    await page.goto(url, { waitUntil: 'load', settleMs: 1500 });
    await page.wait({ selector: '[class*=Header_name]', timeout: 15 }).catch(() => {});
    await page.wait({ selector: '[class*=ImageText_imageText]', timeout: 10 }).catch(() => {});

    const data = await page.evaluate(`
      (() => {
        const titleEl = document.querySelector('[class*=Header_name]');
        const bodyEl = document.querySelector('[class*=ImageText_imageText]');
        if (!titleEl) return { error: 'title_not_found' };
        if (!bodyEl) return { error: 'body_not_found' };

        const title = titleEl.innerText.replace(/\\s+$/g, '').trim();

        const parts = [];
        const BLOCK = /^(DIV|P|SECTION|LI|UL|OL|H1|H2|H3|H4|H5|H6|BLOCKQUOTE|TABLE|TR|HR|ARTICLE)$/;
        const SKIP = /^(STYLE|SCRIPT|NOSCRIPT|TEMPLATE|SVG|BUTTON|INPUT|FORM)$/;

        const walk = (node) => {
          if (node.nodeType === 3) {
            const t = node.textContent;
            if (t && t.replace(/\\s+/g, ' ').trim()) parts.push(t);
            return;
          }
          if (node.nodeType !== 1) return;
          const el = node;
          const tag = el.tagName;
          if (SKIP.test(tag)) return;
          if (tag === 'IMG') {
            const src = el.getAttribute('src') || el.currentSrc || '';
            if (src) parts.push('\\n\\n![](' + src + ')\\n\\n');
            return;
          }
          if (tag === 'BR') { parts.push('\\n'); return; }
          if (tag === 'A') {
            const href = el.getAttribute('href') || '';
            const text = (el.innerText || '').trim();
            if (href && text) { parts.push('[' + text + '](' + href + ')'); return; }
          }
          const isBlock = BLOCK.test(tag);
          if (isBlock) parts.push('\\n');
          for (const child of el.childNodes) walk(child);
          if (isBlock) parts.push('\\n');
        };
        walk(bodyEl);

        let md = parts.join('')
          .replace(/[ \\t\\u00A0]+/g, ' ')
          .replace(/ *\\n */g, '\\n')
          .replace(/\\n{3,}/g, '\\n\\n')
          .trim();

        return { title, content: md };
      })()
    `);

    if (data.error) throw new Error('页面元素未找到: ' + data.error);
    return [{ title: data.title, content: data.content }];
  },
});
