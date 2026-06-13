'use strict';
// PSPipeline Power Query (M) export backend.
// Compiles a pipeline definition to a Power Query M `let ... in` query that the
// user pastes into Excel or Power BI. This is the on-ramp INTO the Microsoft BI
// stack, not a byte-identical replica of the PowerShell/awk engines: columns
// import as text, so numeric typing and locale are the user's to refine in
// Power Query. Authored/tested in Node, then embedded in the designer.
(function (root) {

  // --- M emit helpers -------------------------------------------------------
  function mStr(s) { return '"' + String(s == null ? '' : s).replace(/"/g, '""') + '"'; }
  function ref(id) { return '#"' + String(id).replace(/"/g, '""') + '"'; }       // step name
  function fld(name) { return '[#"' + String(name).replace(/"/g, '""') + '"]'; }  // field access
  function mList(arr) { return '{' + arr.map(mStr).join(', ') + '}'; }

  function mTemplate(tpl) {
    const parts = []; let last = 0, m; const re = /\{([^}]+)\}/g;
    while ((m = re.exec(tpl)) !== null) {
      if (m.index > last) parts.push(mStr(tpl.slice(last, m.index)));
      parts.push('Text.From(' + fld(m[1]) + ')');
      last = re.lastIndex;
    }
    if (last < tpl.length) parts.push(mStr(tpl.slice(last)));
    return parts.length ? parts.join(' & ') : '""';
  }

  function mCond(c) {
    const f = fld(c.column), v = mStr(c.value == null ? '' : String(c.value));
    switch (String(c.operator)) {
      case 'eq': return f + ' = ' + v;
      case 'ne': return f + ' <> ' + v;
      case 'gt': return f + ' > ' + v;
      case 'ge': return f + ' >= ' + v;
      case 'lt': return f + ' < ' + v;
      case 'le': return f + ' <= ' + v;
      case 'contains': return 'Text.Contains(' + f + ', ' + v + ')';
      case 'startswith': return 'Text.StartsWith(' + f + ', ' + v + ')';
      case 'endswith': return 'Text.EndsWith(' + f + ', ' + v + ')';
      case 'isempty': return '(' + f + ' = "" or ' + f + ' = null)';
      case 'isnotempty': return '(' + f + ' <> "" and ' + f + ' <> null)';
      default: return 'true';
    }
  }

  function mTextOp(op, acc, find, find2) {
    switch (op) {
      case 'lower': return 'Text.Lower(' + acc + ')';
      case 'upper': return 'Text.Upper(' + acc + ')';
      case 'title': return 'Text.Proper(' + acc + ')';
      case 'before': return 'Text.BeforeDelimiter(' + acc + ', ' + mStr(find) + ')';
      case 'after': return 'Text.AfterDelimiter(' + acc + ', ' + mStr(find) + ')';
      case 'between': return 'Text.BetweenDelimiters(' + acc + ', ' + mStr(find) + ', ' + mStr(find2) + ')';
      default: return 'Text.Trim(' + acc + ')';
    }
  }

  // numeric-coerced column values inside a Table.Group `each` (subtable is _)
  function mNumCol(col) {
    return 'List.RemoveNulls(List.Transform(Table.Column(_, ' + mStr(col) + '), each try Number.From(_) otherwise null))';
  }

  // --- graph helpers --------------------------------------------------------
  function topoOrder(def) {
    const indeg = {}, adj = {};
    def.nodes.forEach(n => { indeg[n.id] = 0; adj[n.id] = []; });
    (def.edges || []).forEach(e => { if (e.to in indeg && e.from in adj) { indeg[e.to]++; adj[e.from].push(e.to); } });
    const q = def.nodes.filter(n => indeg[n.id] === 0).map(n => n.id), order = [];
    while (q.length) { const id = q.shift(); order.push(id); adj[id].forEach(nx => { if (--indeg[nx] === 0) q.push(nx); }); }
    if (order.length !== def.nodes.length) throw new Error('Pipeline contains a cycle.');
    return order;
  }
  function inputsOf(def, id) { const ins = {}; (def.edges || []).forEach(e => { if (e.to === id) ins[e.toPort || 'in'] = e.from; }); return ins; }

  // --- per-node M expression ------------------------------------------------
  function nodeExpr(def, node, resolve) {
    const cfg = node.config || {}, t = String(node.type);
    const ins = inputsOf(def, node.id);
    const inn = () => ref(ins['in']);

    switch (t) {
      case 'input.csv': {
        const d = cfg.delimiter ? String(cfg.delimiter) : ',';
        return 'Table.PromoteHeaders(Csv.Document(File.Contents(' + mStr(resolve(cfg.path)) + '), [Delimiter = ' + mStr(d) + ', Encoding = 65001, QuoteStyle = QuoteStyle.Csv]), [PromoteAllScalars = true])';
      }
      case 'input.json':
        return 'Table.FromRecords(Json.Document(File.Contents(' + mStr(resolve(cfg.path)) + ')))';
      case 'input.fixedwidth':
        throw new Error("Fixed-width input is not supported in the Power Query (M) export yet; use the PowerShell or shell target for node '" + node.id + "'.");

      case 'transform.select': return 'Table.SelectColumns(' + inn() + ', ' + mList(cfg.columns || []) + ')';
      case 'transform.drop': return 'Table.RemoveColumns(' + inn() + ', ' + mList(cfg.columns || []) + ')';
      case 'transform.rename': return 'Table.RenameColumns(' + inn() + ', {' + (cfg.renames || []).map(r => '{' + mStr(r.from) + ', ' + mStr(r.to) + '}').join(', ') + '})';
      case 'transform.derive': return 'Table.AddColumn(' + inn() + ', ' + mStr(cfg.name) + ', each ' + mTemplate(String(cfg.template || '')) + ')';
      case 'transform.filter': {
        const conds = (cfg.conditions || []).map(mCond);
        const body = conds.length ? conds.map(c => '(' + c + ')').join(String(cfg.match) === 'Any' ? ' or ' : ' and ') : 'true';
        return 'Table.SelectRows(' + inn() + ', each ' + body + ')';
      }
      case 'transform.sort':
        return 'Table.Sort(' + inn() + ', {' + (cfg.sortBy || []).map(s => '{' + mStr(s.column) + ', ' + (s.descending ? 'Order.Descending' : 'Order.Ascending') + '}').join(', ') + '})';
      case 'transform.distinct':
        return (cfg.columns && cfg.columns.length) ? 'Table.Distinct(' + inn() + ', ' + mList(cfg.columns) + ')' : 'Table.Distinct(' + inn() + ')';
      case 'transform.limit': {
        const count = cfg.count != null ? parseInt(cfg.count, 10) : 10;
        if (String(cfg.mode) === 'Bottom') return 'Table.LastN(' + inn() + ', ' + count + ')';
        if (String(cfg.mode) === 'Range') return 'Table.Range(' + inn() + ', ' + ((cfg.start != null ? parseInt(cfg.start, 10) : 1) - 1) + ', ' + count + ')';
        return 'Table.FirstN(' + inn() + ', ' + count + ')';
      }
      case 'transform.index':
        return 'Table.AddIndexColumn(' + inn() + ', ' + mStr(cfg.name || 'Index') + ', ' + (cfg.start != null ? parseInt(cfg.start, 10) : 1) + ', 1, Int64.Type)';
      case 'transform.replace':
        return 'Table.ReplaceValue(' + inn() + ', ' + mStr(cfg.find == null ? '' : cfg.find) + ', ' + mStr(cfg.replaceWith == null ? '' : cfg.replaceWith) + ', ' + (cfg.wholeCell ? 'Replacer.ReplaceValue' : 'Replacer.ReplaceText') + ', ' + mList([cfg.column]) + ')';
      case 'transform.fill':
        return 'Table.' + (String(cfg.direction) === 'Up' ? 'FillUp' : 'FillDown') + '(' + inn() + ', ' + mList(cfg.columns || []) + ')';
      case 'transform.conditional': {
        let chain = '';
        (cfg.rules || []).forEach(r => { chain += 'if ' + mCond(r) + ' then ' + mTemplate(String(r.result == null ? '' : r.result)) + ' else '; });
        chain += mTemplate(String(cfg['else'] == null ? '' : cfg['else']));
        return 'Table.AddColumn(' + inn() + ', ' + mStr(cfg.name) + ', each ' + chain + ')';
      }
      case 'transform.text': {
        const op = String(cfg.op || 'trim'), find = cfg.find == null ? '' : String(cfg.find), find2 = cfg.find2 == null ? '' : String(cfg.find2);
        if (cfg.as) return 'Table.AddColumn(' + inn() + ', ' + mStr(cfg.as) + ', each ' + mTextOp(op, fld(cfg.column), find, find2) + ')';
        return 'Table.TransformColumns(' + inn() + ', {{' + mStr(cfg.column) + ', each ' + mTextOp(op, '_', find, find2) + ', type text}})';
      }
      case 'transform.join': {
        const jt = String(cfg.joinType || 'Inner');
        const kind = { Inner: 'JoinKind.Inner', Left: 'JoinKind.LeftOuter', Right: 'JoinKind.RightOuter', Full: 'JoinKind.FullOuter' }[jt] || 'JoinKind.Inner';
        const nj = 'Table.NestedJoin(' + ref(ins['left']) + ', ' + mList([cfg.leftKey]) + ', ' + ref(ins['right']) + ', ' + mList([cfg.rightKey]) + ', "PSPL_NJ", ' + kind + ')';
        return 'Table.ExpandTableColumn(' + nj + ', "PSPL_NJ", Table.ColumnNames(' + ref(ins['right']) + '))';
      }
      case 'transform.aggregate': {
        const gb = (cfg.groupBy || []).map(String);
        const aggs = (cfg.aggregations || []).map(a => {
          const as = a.as || (a.function + '_' + a.column);
          let fn;
          switch (String(a.function)) {
            case 'Count': fn = 'each Table.RowCount(_)'; break;
            case 'First': fn = 'each Table.Column(_, ' + mStr(a.column) + '){0}'; break;
            case 'Sum': fn = 'each List.Sum(' + mNumCol(a.column) + ')'; break;
            case 'Average': fn = 'each List.Average(' + mNumCol(a.column) + ')'; break;
            case 'Min': fn = 'each List.Min(' + mNumCol(a.column) + ')'; break;
            case 'Max': fn = 'each List.Max(' + mNumCol(a.column) + ')'; break;
            case 'Median': fn = 'each List.Median(' + mNumCol(a.column) + ')'; break;
            case 'CountDistinct': fn = 'each List.Count(List.Distinct(List.Transform(Table.Column(_, ' + mStr(a.column) + '), Text.Lower)))'; break;
            case 'StringJoin': fn = 'each Text.Combine(List.Transform(Table.Column(_, ' + mStr(a.column) + '), Text.From), ", ")'; break;
            default: fn = 'each null';
          }
          return '{' + mStr(as) + ', ' + fn + ', type any}';
        });
        return 'Table.Group(' + inn() + ', ' + mList(gb) + ', {' + aggs.join(', ') + '})';
      }
      case 'transform.union': {
        const sources = (def.edges || []).filter(e => e.to === node.id).map(e => e.from);
        return 'Table.Combine({' + sources.map(ref).join(', ') + '})';
      }
      case 'transform.date': {
        const op = String(cfg.op || 'year');
        const dx = r0 => 'Date.From(' + r0 + ')';
        const body = (rA, rB) => {
          switch (op) {
            case 'year': return 'Date.Year(' + dx(rA) + ')';
            case 'month': return 'Date.Month(' + dx(rA) + ')';
            case 'day': return 'Date.Day(' + dx(rA) + ')';
            case 'weekday': return 'Date.DayOfWeek(' + dx(rA) + ', Day.Monday) + 1';
            case 'format': return 'Date.ToText(' + dx(rA) + ', [Format = ' + mStr(String(cfg.format || 'yyyy-MM-dd')) + '])';
            case 'diffdays': return 'Duration.Days(' + dx(rA) + ' - ' + dx(rB) + ')';
            default: return 'null';
          }
        };
        if ((cfg.as && cfg.as !== cfg.column) || op === 'diffdays') {
          return 'Table.AddColumn(' + inn() + ', ' + mStr(cfg.as || cfg.column) + ', each ' + body(fld(cfg.column), fld(cfg.column2)) + ')';
        }
        return 'Table.TransformColumns(' + inn() + ', {{' + mStr(cfg.column) + ', each ' + body('_', '_') + ', type any}})';
      }
      case 'transform.cast': {
        const ty = { number: 'type number', integer: 'Int64.Type', text: 'type text' }[String(cfg.to || 'text')] || 'type text';
        return 'Table.TransformColumnTypes(' + inn() + ', {{' + mStr(cfg.column) + ', ' + ty + '}})';
      }
      case 'transform.unpivot':
        return 'Table.UnpivotOtherColumns(' + inn() + ', ' + mList(cfg.keep || []) + ', ' + mStr(cfg.attributeName || 'Attribute') + ', ' + mStr(cfg.valueName || 'Value') + ')';
      case 'transform.pivot': {
        // Table.Pivot groups by every column that is not the attribute/value column,
        // so the input should carry only the groupBy + pivot + value columns.
        const aggm = { Sum: ', each List.Sum(List.Transform(_, each try Number.From(_) otherwise null))', Count: ', each List.Count(_)', First: ', each List.First(_)' }[String(cfg.aggregate || 'First')] || ', each List.First(_)';
        const pv = 'List.Distinct(List.Transform(Table.Column(' + inn() + ', ' + mStr(cfg.pivotColumn) + '), Text.From))';
        return 'Table.Pivot(' + inn() + ', ' + pv + ', ' + mStr(cfg.pivotColumn) + ', ' + mStr(cfg.valueColumn) + aggm + ')';
      }
      case 'output.csv': case 'output.json':
        return inn();   // Power Query has no file-write; the query result is the table

      default:
        throw new Error("The Power Query (M) export does not support node type '" + t + "'.");
    }
  }

  function generateMQuery(def) {
    const params = {};
    (def.parameters || []).forEach(p => { if (p && p.name) params[p.name] = String(p.default == null ? '' : p.default); });
    const resolve = s => String(s == null ? '' : s).replace(/\$\{([A-Za-z0-9_]+)\}/g, (m, n) => (n in params) ? params[n] : m);

    const order = topoOrder(def);
    const byId = {}; def.nodes.forEach(n => { byId[n.id] = n; });
    const steps = order.map(id => '    ' + ref(id) + ' = ' + nodeExpr(def, byId[id], resolve));

    const hasOut = {}; (def.edges || []).forEach(e => { hasOut[e.from] = 1; });
    const terminals = order.filter(id => !hasOut[id]);
    const result = terminals.length ? terminals[terminals.length - 1] : order[order.length - 1];

    return [
      '// Power Query M -- generated by PSPipeline Designer.',
      '// Paste into Power Query: Excel = Data > Get Data > Blank Query > Advanced Editor;',
      '// Power BI = Home > Transform data > New Source > Blank Query > Advanced Editor.',
      '// Columns import as text; set column types in Power Query as needed',
      '// (the export coerces numbers inside aggregations, but does not type the table).',
      'let',
      steps.join(',\n'),
      'in',
      '    ' + ref(result),
      ''
    ].join('\n');
  }

  if (typeof module !== 'undefined' && module.exports) module.exports = { generateMQuery };
  else root.generateMQuery = generateMQuery;

  if (typeof require !== 'undefined' && typeof module !== 'undefined' && require.main === module) {
    const fs = require('fs');
    process.stdout.write(generateMQuery(JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))));
  }

})(typeof globalThis !== 'undefined' ? globalThis : this);
