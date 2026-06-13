'use strict';
// PSPipeline in-browser PREVIEW executor.
// Runs loaded sample rows through the DAG so the designer can show resulting
// rows at every node (transforms and outputs), not just columns. This is a
// third implementation of the transform semantics alongside the PowerShell
// engine and the awk runtime, used ONLY for preview -- it is verified against
// the PowerShell oracle. A table is { columns: [str], rows: [[str]] }.
(function (root) {

  function isNum(x) { return /^[ \t]*[-+]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][-+]?[0-9]+)?[ \t]*$/.test(String(x)); }
  // Case-insensitive, numeric-when-both-numeric -- matches the engines.
  function cmp(a, b) {
    if (isNum(a) && isNum(b)) { a = +a; b = +b; return a < b ? -1 : (a > b ? 1 : 0); }
    a = String(a).toLowerCase(); b = String(b).toLowerCase();
    return a < b ? -1 : (a > b ? 1 : 0);
  }
  function opEq(a, b) { return (isNum(a) && isNum(b)) ? (+a === +b) : (String(a).toLowerCase() === String(b).toLowerCase()); }
  function idx(table, name) { return table.columns.indexOf(name); }
  function val(table, row, name) { const i = table.columns.indexOf(name); return i < 0 ? '' : (row[i] == null ? '' : row[i]); }
  function num(x) { return isNum(x) ? +x : 0; }

  function testCond(table, row, cond) {
    const a = val(table, row, cond.column), b = cond.value == null ? '' : String(cond.value);
    switch (String(cond.operator)) {
      case 'eq': return opEq(a, b);
      case 'ne': return !opEq(a, b);
      case 'gt': return cmp(a, b) > 0;
      case 'ge': return cmp(a, b) >= 0;
      case 'lt': return cmp(a, b) < 0;
      case 'le': return cmp(a, b) <= 0;
      case 'contains': return String(a).toLowerCase().indexOf(b.toLowerCase()) >= 0;
      case 'startswith': return String(a).toLowerCase().lastIndexOf(b.toLowerCase(), 0) === 0;
      case 'endswith': { const s = String(a).toLowerCase(), t = b.toLowerCase(); return s.length >= t.length && s.slice(s.length - t.length) === t; }
      case 'isempty': return a === '' || a == null;
      case 'isnotempty': return !(a === '' || a == null);
      default: return false;
    }
  }

  function deriveValue(template, table, row) {
    return String(template).replace(/\{([^}]+)\}/g, (m, name) => (table.columns.indexOf(name) >= 0 ? val(table, row, name) : m));
  }

  // stable sort by sortBy: [{column, descending}]
  function sortRows(table, sortBy) {
    const decorated = table.rows.map((r, i) => ({ r, i }));
    decorated.sort((x, y) => {
      for (const k of sortBy) {
        let c = cmp(val(table, x.r, k.column), val(table, y.r, k.column));
        if (k.descending) c = -c;
        if (c !== 0) return c;
      }
      return x.i - y.i; // stable
    });
    return { columns: table.columns.slice(), rows: decorated.map(d => d.r) };
  }

  function compute(def, id, out, sampleData) {
    const node = def.nodes.find(n => n.id === id);
    if (!node) return { columns: [], rows: [] };
    const cfg = node.config || {};
    const src = port => { const e = (def.edges || []).find(e => e.to === id && (e.toPort || 'in') === port); return e ? (out[e.from] || { columns: [], rows: [] }) : { columns: [], rows: [] }; };
    const t = node.type;

    if (t === 'input.csv' || t === 'input.json') return sampleData[id] || { columns: [], rows: [] };
    if (t === 'input.fixedwidth') return sampleData[id] || { columns: (cfg.columns || []).map(c => c.name), rows: [] };

    if (t === 'transform.select') {
      const cols = cfg.columns || [];
      const inT = src('in');
      return { columns: cols.slice(), rows: inT.rows.map(r => cols.map(c => val(inT, r, c))) };
    }
    if (t === 'transform.drop') {
      const drop = cfg.columns || [], inT = src('in');
      const cols = inT.columns.filter(c => drop.indexOf(c) < 0);
      return { columns: cols, rows: inT.rows.map(r => cols.map(c => val(inT, r, c))) };
    }
    if (t === 'transform.rename') {
      const m = {}; (cfg.renames || []).forEach(x => { m[x.from] = x.to; });
      const inT = src('in');
      return { columns: inT.columns.map(c => m[c] || c), rows: inT.rows.map(r => r.slice()) };
    }
    if (t === 'transform.derive') {
      const inT = src('in');
      return { columns: inT.columns.concat(cfg.name ? [cfg.name] : []), rows: inT.rows.map(r => r.concat(cfg.name ? [deriveValue(cfg.template || '', inT, r)] : [])) };
    }
    if (t === 'transform.filter') {
      const inT = src('in'), conds = cfg.conditions || [], any = String(cfg.match) === 'Any';
      const keep = r => conds.length === 0 ? true : (any ? conds.some(c => testCond(inT, r, c)) : conds.every(c => testCond(inT, r, c)));
      return { columns: inT.columns.slice(), rows: inT.rows.filter(keep) };
    }
    if (t === 'transform.sort') return sortRows(src('in'), cfg.sortBy || []);
    if (t === 'transform.distinct') {
      const inT = src('in'), cols = cfg.columns || [];
      const keyOf = r => (cols.length ? cols.map(c => val(inT, r, c)).join('') : r.join(''));
      const sorted = sortRows(inT, (cols.length ? cols : inT.columns).map(c => ({ column: c, descending: false })));
      const seen = {}, rows = [];
      sorted.rows.forEach(r => { const k = keyOf(r); if (!seen[k]) { seen[k] = 1; rows.push(r); } });
      return { columns: inT.columns.slice(), rows };
    }
    if (t === 'transform.limit') {
      const inT = src('in'), rows = inT.rows;
      const mode = String(cfg.mode || 'Top');
      const count = cfg.count != null ? parseInt(cfg.count, 10) : 10;
      const start = cfg.start != null ? parseInt(cfg.start, 10) : 1;
      let out;
      if (count <= 0) out = [];
      else if (mode === 'Bottom') out = rows.slice(Math.max(0, rows.length - count));
      else if (mode === 'Range') { const s = Math.max(0, start - 1); out = rows.slice(s, s + count); }
      else out = rows.slice(0, count);
      return { columns: inT.columns.slice(), rows: out };
    }
    if (t === 'transform.index') {
      const inT = src('in'), name = String(cfg.name || 'Index');
      let i = cfg.start != null ? parseInt(cfg.start, 10) : 1;
      return { columns: inT.columns.concat([name]), rows: inT.rows.map(r => r.concat([String(i++)])) };
    }
    if (t === 'transform.replace') {
      const inT = src('in'), ci = inT.columns.indexOf(cfg.column);
      if (ci < 0) return { columns: inT.columns.slice(), rows: inT.rows.map(r => r.slice()) };
      const find = cfg.find != null ? String(cfg.find) : '';
      const repl = cfg.replaceWith != null ? String(cfg.replaceWith) : '';
      const whole = !!cfg.wholeCell;
      const rows = inT.rows.map(r => {
        const nr = r.slice(); let v = String(nr[ci] == null ? '' : nr[ci]);
        if (whole) { if (v.toLowerCase() === find.toLowerCase()) v = repl; }
        else if (find !== '') { v = v.split(find).join(repl); }
        nr[ci] = v; return nr;
      });
      return { columns: inT.columns.slice(), rows };
    }
    if (t === 'transform.fill') {
      const inT = src('in'), up = String(cfg.direction) === 'Up';
      const rows = inT.rows.map(r => r.slice());
      (cfg.columns || []).forEach(cn => {
        const ci = inT.columns.indexOf(cn); if (ci < 0) return;
        let last = null;
        const step = (i) => { const v = String(rows[i][ci] == null ? '' : rows[i][ci]); if (v !== '') last = rows[i][ci]; else if (last != null) rows[i][ci] = last; };
        if (up) { for (let i = rows.length - 1; i >= 0; i--) step(i); }
        else { for (let i = 0; i < rows.length; i++) step(i); }
      });
      return { columns: inT.columns.slice(), rows };
    }
    if (t === 'transform.conditional') {
      const inT = src('in'), name = String(cfg.name), rules = cfg.rules || [];
      const els = cfg['else'] != null ? String(cfg['else']) : '';
      const rows = inT.rows.map(r => {
        let picked = els;
        for (const rule of rules) { if (testCond(inT, r, rule)) { picked = String(rule.result == null ? '' : rule.result); break; } }
        return r.concat([deriveValue(picked, inT, r)]);
      });
      return { columns: inT.columns.concat([name]), rows };
    }
    if (t === 'transform.join') {
      const L = src('left'), R = src('right'), jt = String(cfg.joinType || 'Inner');
      const lset = {}; L.columns.forEach(c => { lset[c] = 1; });
      const columns = L.columns.concat(R.columns.map(c => lset[c] ? 'Right_' + c : c));
      const index = {}; R.rows.forEach(r => { const k = val(R, r, cfg.rightKey); (index[k] = index[k] || []).push(r); });
      const blankL = L.columns.map(() => ''), blankR = R.columns.map(() => '');
      const rows = [], matched = {};
      L.rows.forEach(lr => {
        const k = val(L, lr, cfg.leftKey);
        if (index[k]) { matched[k] = 1; index[k].forEach(rr => rows.push(lr.concat(rr))); }
        else if (jt === 'Left' || jt === 'Full') rows.push(lr.concat(blankR));
      });
      if (jt === 'Right' || jt === 'Full') {
        Object.keys(index).forEach(k => { if (!matched[k]) index[k].forEach(rr => rows.push(blankL.concat(rr))); });
      }
      return { columns, rows };
    }
    if (t === 'transform.aggregate') {
      const inT = src('in'), gb = cfg.groupBy || [], aggs = cfg.aggregations || [];
      const columns = gb.concat(aggs.map(a => a.as || (a.function + '_' + a.column)));
      const order = [], groups = {};
      inT.rows.forEach(r => {
        const key = gb.map(c => val(inT, r, c)).join('');
        if (!groups[key]) { groups[key] = { keyvals: gb.map(c => val(inT, r, c)), rows: [] }; order.push(key); }
        groups[key].rows.push(r);
      });
      const rows = order.map(key => {
        const g = groups[key];
        const cells = g.keyvals.slice();
        aggs.forEach(a => {
          const nums = g.rows.map(r => val(inT, r, a.column)).filter(isNum).map(Number);
          let v = '';
          switch (String(a.function)) {
            case 'Count': v = g.rows.length; break;
            case 'First': v = val(inT, g.rows[0], a.column); break;
            case 'Sum': v = nums.reduce((s, n) => s + n, 0); break;
            case 'Average': v = nums.length ? (nums.reduce((s, n) => s + n, 0) / nums.length) : ''; break;
            case 'Min': v = nums.length ? Math.min.apply(null, nums) : ''; break;
            case 'Max': v = nums.length ? Math.max.apply(null, nums) : ''; break;
          }
          cells.push(String(v));
        });
        return cells;
      });
      return { columns, rows };
    }
    if (t === 'output.csv' || t === 'output.json') return src('in');
    return { columns: [], rows: [] };
  }

  function runSampleEngine(def, sampleData) {
    sampleData = sampleData || {};
    // topological order (Kahn)
    const indeg = {}, adj = {};
    def.nodes.forEach(n => { indeg[n.id] = 0; adj[n.id] = []; });
    (def.edges || []).forEach(e => { if (e.to in indeg && e.from in adj) { indeg[e.to]++; adj[e.from].push(e.to); } });
    const q = def.nodes.filter(n => indeg[n.id] === 0).map(n => n.id), order = [];
    while (q.length) { const id = q.shift(); order.push(id); adj[id].forEach(nx => { if (--indeg[nx] === 0) q.push(nx); }); }
    const out = {};
    order.forEach(id => { try { out[id] = compute(def, id, out, sampleData); } catch (e) { out[id] = { columns: [], rows: [] }; } });
    return out;
  }

  if (typeof module !== 'undefined' && module.exports) module.exports = { runSampleEngine };
  else root.runSampleEngine = runSampleEngine;

})(typeof globalThis !== 'undefined' ? globalThis : this);
