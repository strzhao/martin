import { cli, Strategy } from '@jackwener/opencli/registry';

cli({
  site: 'cc',
  name: 'register',
  description: '', // TODO: describe what this command does
  access: 'read',  // TODO: 'read' for queries, 'write' for remote/account state changes
  example: 'opencli cc register -f yaml',
  domain: 'cc',
  strategy: Strategy.PUBLIC, // TODO: PUBLIC (no auth), COOKIE (needs login), UI (DOM interaction)
  browser: false,            // TODO: set true if needs browser
  args: [
    { name: 'limit', type: 'int', default: 10, help: 'Number of items' },
  ],
  columns: [], // TODO: field names for table output (e.g. ['title', 'score', 'url'])
  func: async (kwargs) => {
    // TODO: implement data fetching
    // Prefer API calls (fetch) over browser automation
    // If you set browser: true, change this to: async (page, kwargs) => { ... }
    return [];
  },
});
