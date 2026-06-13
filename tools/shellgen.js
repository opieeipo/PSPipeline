'use strict';
// PSPipeline shell (POSIX sh + awk) backend generator.
// Authored/tested here in Node, then mirrored into designer/index.html as
// BACKENDS.shell.generate. Pure function of (def, runtimeText) -> script string.

function generateShellScript(def, runtime) {
  const bad = collectTokenViolations(def);
  if (bad.length) throw new Error('The shell target supports ${parameter} tokens only in input/output paths; found tokens in node(s): ' + bad.join(', ') + '. Use the PowerShell target, or put the parameter in a path.');
  return runtime.replace(/\s+$/, '') + '\n\n' + shellParamBlock(def) + generateShellBody(def) + '\n';
}

// shell single-quote
function shq(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }
// awk string literal
function aws(s) {
  return '"' + String(s)
    .replace(/\\/g, '\\\\').replace(/"/g, '\\"')
    .replace(/\n/g, '\\n').replace(/\r/g, '\\r').replace(/\t/g, '\\t') + '"';
}
function col(name) { return '$(c[' + aws(name) + '])'; }
function wf(id) { return '"$WORK/' + id + '"'; }

// --- pipeline parameters ----------------------------------------------------
// escape for inside a double-quoted shell string
function shDqEscape(s) { return String(s).replace(/([\\"$`])/g, '\\$1'); }
// a path config string: ${Name} tokens -> ${P_Name} shell vars; plain literal otherwise
function shellPath(s) {
  s = String(s);
  if (!/\$\{[A-Za-z0-9_]+\}/.test(s)) return shq(s);
  let out = '"', last = 0, m; const re = /\$\{([A-Za-z0-9_]+)\}/g;
  while ((m = re.exec(s)) !== null) { out += shDqEscape(s.slice(last, m.index)) + '${P_' + m[1] + '}'; last = re.lastIndex; }
  return out + shDqEscape(s.slice(last)) + '"';
}
function shellParamBlock(def) {
  const ps = (def.parameters || []).filter(p => p && p.name);
  if (!ps.length) return '';
  return ps.map(p => 'P_' + p.name + '="${PSPL_' + p.name + ':-' + shDqEscape(String(p.default == null ? '' : p.default)) + '}"').join('\n') + '\n\n';
}
// shell target supports ${parameter} tokens only in input/output paths
function collectTokenViolations(def) {
  const bad = new Set();
  function scan(val, allowed, id) {
    if (typeof val === 'string') { if (!allowed && /\$\{[A-Za-z0-9_]+\}/.test(val)) bad.add(id); return; }
    if (Array.isArray(val)) { val.forEach(v => scan(v, false, id)); return; }
    if (val && typeof val === 'object') { Object.keys(val).forEach(k => scan(val[k], false, id)); return; }
  }
  (def.nodes || []).forEach(n => { const cfg = n.config || {}; Object.keys(cfg).forEach(k => scan(cfg[k], k === 'path', n.id)); });
  return [...bad];
}

function topoOrder(def) {
  const indeg = {}, adj = {};
  for (const n of def.nodes) { indeg[n.id] = 0; adj[n.id] = []; }
  for (const e of (def.edges || [])) {
    if (!(e.to in indeg) || !(e.from in adj)) throw new Error("Edge references a missing node: " + e.from + " -> " + e.to);
    indeg[e.to]++; adj[e.from].push(e.to);
  }
  const q = def.nodes.filter(n => indeg[n.id] === 0).map(n => n.id);
  const order = [];
  while (q.length) {
    const id = q.shift(); order.push(id);
    for (const nx of adj[id]) if (--indeg[nx] === 0) q.push(nx);
  }
  if (order.length !== def.nodes.length) throw new Error("Pipeline contains a cycle.");
  return order;
}

function inputsOf(def, id) {
  const ins = {};
  for (const e of (def.edges || [])) if (e.to === id) ins[e.toPort || 'in'] = e.from;
  return ins;
}

// awk that reads a US-delimited file, maps header names to indices in c[], prints header, then runs body
function header(extra) {
  return 'NR==1{ for(i=1;i<=NF;i++)c[$i]=i; ' + extra + ' next }';
}

function deriveExpr(template) {
  // split into literal/token parts; token -> field lookup with literal fallback
  const parts = [];
  const re = /\{([^}]+)\}/g; let last = 0, m;
  while ((m = re.exec(template)) !== null) {
    if (m.index > last) parts.push(aws(template.slice(last, m.index)));
    const name = m[1];
    parts.push('(' + aws(name) + ' in c ? $(c[' + aws(name) + ']) : ' + aws('{' + name + '}') + ')');
    last = re.lastIndex;
  }
  if (last < template.length) parts.push(aws(template.slice(last)));
  return parts.length ? parts.join(' ') : '""';
}

function condExpr(cond) {
  const f = col(cond.column), v = aws(String(cond.value == null ? '' : cond.value));
  switch (String(cond.operator)) {
    case 'eq': return 'op_eq(' + f + ',' + v + ')';
    case 'ne': return '!op_eq(' + f + ',' + v + ')';
    case 'gt': return '(cmp(' + f + ',' + v + ')>0)';
    case 'ge': return '(cmp(' + f + ',' + v + ')>=0)';
    case 'lt': return '(cmp(' + f + ',' + v + ')<0)';
    case 'le': return '(cmp(' + f + ',' + v + ')<=0)';
    case 'contains':   return '(index(tolower(' + f + '),tolower(' + v + '))>0)';
    case 'startswith': return '(substr(tolower(' + f + '),1,length(' + v + '))==tolower(' + v + '))';
    case 'endswith':   return '(length(' + f + ')>=length(' + v + ') && substr(tolower(' + f + '),length(' + f + ')-length(' + v + ')+1)==tolower(' + v + '))';
    case 'isempty':    return '(' + f + '=="")';
    case 'isnotempty': return '(' + f + '!="")';
    default: throw new Error("Unknown filter operator '" + cond.operator + "'.");
  }
}

function awkStep(prog, inFiles, outId) {
  return "awk -v US=\"$US\" \"$AWKLIB\"'\n" + prog + "\n' " + inFiles + ' > ' + wf(outId);
}

function genNode(def, node) {
  const cfg = node.config || {};
  const ins = inputsOf(def, node.id);
  const t = String(node.type);
  const label = '# ' + node.id + ' (' + t + ')' + (node.label ? '  ' + node.label.replace(/\n/g, ' ') : '');

  if (t === 'input.json' || t === 'output.json') {
    throw new Error("The shell target does not support JSON nodes yet (node '" + node.id + "'). Use delimited text, or generate the PowerShell target.");
  }

  let prog;
  switch (t) {
    case 'input.csv': {
      const d = cfg.delimiter ? String(cfg.delimiter) : ',';
      prog = '{ sub(/\\r$/,""); if($0=="")next; n=csv_split($0, ' + aws(d) + ', f); o=""; for(i=1;i<=n;i++) o=o (i>1?US:"") f[i]; print o }';
      return label + '\n' + awkStep(prog, shellPath(String(cfg.path)), node.id);
    }
    case 'input.fixedwidth': {
      const cols = (cfg.columns || []);
      const head = cols.map(cc => aws(String(cc.name))).join(' US ');
      const skip = cfg.skipLines ? parseInt(cfg.skipLines, 10) : 0;
      const extract = cols.map(cc => 'trim(substr($0,' + parseInt(cc.start, 10) + ',' + parseInt(cc.length, 10) + '))').join(' US ');
      prog = 'BEGIN{ print ' + head + ' }\n'
           + (skip > 0 ? 'NR<=' + skip + '{next}\n' : '')
           + '{ sub(/\\r$/,""); if($0=="")next; print ' + extract + ' }';
      return label + '\n' + 'awk -v US="$US" "$AWKLIB"\'\n' + prog + '\n\' ' + shellPath(String(cfg.path)) + ' > ' + wf(node.id);
    }
    case 'transform.select': {
      const cols = (cfg.columns || []).map(String);
      const h = cols.map(aws).join(' OFS ');
      const body = cols.map(col).join(' OFS ');
      prog = 'BEGIN{FS=US;OFS=US}\n' + header('print ' + h + ';') + '\n{ print ' + body + ' }';
      return label + '\n' + awkStep(prog, wf(ins['in']), node.id);
    }
    case 'transform.drop': {
      const drops = (cfg.columns || []).map(String);
      const init = drops.map(d => 'drop[' + aws(d) + ']=1;').join(' ');
      prog = 'BEGIN{FS=US;OFS=US; ' + init + '}\n'
           + 'NR==1{ k=0; h=""; for(i=1;i<=NF;i++){ if(!($i in drop)){ keep[++k]=i; h=h (k>1?OFS:"") $i } } print h; next }\n'
           + '{ o=""; for(i=1;i<=k;i++) o=o (i>1?OFS:"") $(keep[i]); print o }';
      return label + '\n' + awkStep(prog, wf(ins['in']), node.id);
    }
    case 'transform.rename': {
      const init = (cfg.renames || []).map(r => 'ren[' + aws(String(r.from)) + ']=' + aws(String(r.to)) + ';').join(' ');
      prog = 'BEGIN{FS=US;OFS=US; ' + init + '}\n'
           + 'NR==1{ h=""; for(i=1;i<=NF;i++){ nm=$i; if(nm in ren)nm=ren[nm]; h=h (i>1?OFS:"") nm } print h; next }\n'
           + '{ print $0 }';
      return label + '\n' + awkStep(prog, wf(ins['in']), node.id);
    }
    case 'transform.derive': {
      prog = 'BEGIN{FS=US;OFS=US}\n' + header('print $0 OFS ' + aws(String(cfg.name)) + ';') + '\n{ print $0 OFS (' + deriveExpr(String(cfg.template || '')) + ') }';
      return label + '\n' + awkStep(prog, wf(ins['in']), node.id);
    }
    case 'transform.filter': {
      const conds = (cfg.conditions || []).map(condExpr);
      const joined = conds.length ? conds.join(String(cfg.match) === 'Any' ? ' || ' : ' && ') : '1';
      prog = 'BEGIN{FS=US;OFS=US}\nNR==1{ for(i=1;i<=NF;i++)c[$i]=i; print $0; next }\n{ if(' + joined + ') print $0 }';
      return label + '\n' + awkStep(prog, wf(ins['in']), node.id);
    }
    case 'transform.sort': {
      const keys = (cfg.sortBy || []);
      const capture = keys.map((k, i) => 'kv' + i + '[n]=' + col(k.column)).join('; ');
      let cmpBody = '';
      keys.forEach((k, i) => {
        const dir = (k.descending ? '-' : '') ;
        cmpBody += 'r=' + dir + 'cmp(kv' + i + '[a],kv' + i + '[b]); if(r!=0)return r; ';
      });
      prog = 'BEGIN{FS=US;OFS=US}\n'
           + 'function keycmp(a,b,  r){ ' + cmpBody + 'return 0 }\n'
           + 'NR==1{ for(i=1;i<=NF;i++)c[$i]=i; print $0; next }\n'
           + '{ rows[++n]=$0; idx[n]=n; ' + capture + ' }\n'
           + 'END{ for(p=2;p<=n;p++){ pi=idx[p]; q=p-1; while(q>=1 && keycmp(idx[q],pi)>0){ idx[q+1]=idx[q]; q-- } idx[q+1]=pi } for(i=1;i<=n;i++) print rows[idx[i]] }';
      return label + '\n' + awkStep(prog, wf(ins['in']), node.id);
    }
    case 'transform.distinct': {
      const cols = (cfg.columns || []).map(String);
      const keyExpr = cols.length ? cols.map(col).join(' US ') : '$0';
      const capture = cols.length ? cols.map((cn, i) => 'kv' + i + '[n]=' + col(cn)).join('; ') : 'kv0[n]=$0';
      let cmpBody = '';
      const kcols = cols.length ? cols : ['__row__'];
      kcols.forEach((cn, i) => { cmpBody += 'r=cmp(kv' + i + '[a],kv' + i + '[b]); if(r!=0)return r; '; });
      prog = 'BEGIN{FS=US;OFS=US}\n'
           + 'function keycmp(a,b,  r){ ' + cmpBody + 'return 0 }\n'
           + 'NR==1{ for(i=1;i<=NF;i++)c[$i]=i; print $0; next }\n'
           + '{ rows[++n]=$0; idx[n]=n; key[n]=' + keyExpr + '; ' + capture + ' }\n'
           + 'END{ for(p=2;p<=n;p++){ pi=idx[p]; q=p-1; while(q>=1 && keycmp(idx[q],pi)>0){ idx[q+1]=idx[q]; q-- } idx[q+1]=pi } '
           + 'for(i=1;i<=n;i++){ kk=key[idx[i]]; if(!(kk in seen)){ seen[kk]=1; print rows[idx[i]] } } }';
      return label + '\n' + awkStep(prog, wf(ins['in']), node.id);
    }
    case 'transform.limit': {
      const mode = String(cfg.mode || 'Top');
      const count = cfg.count != null ? parseInt(cfg.count, 10) : 10;
      const start = cfg.start != null ? parseInt(cfg.start, 10) : 1;
      let end;
      if (mode === 'Bottom') end = 'END{ s=n-' + count + '+1; if(s<1)s=1; for(i=s;i<=n;i++)print rows[i] }';
      else if (mode === 'Range') end = 'END{ s=' + start + '; if(s<1)s=1; e=s+' + count + '-1; if(e>n)e=n; for(i=s;i<=e;i++)print rows[i] }';
      else end = 'END{ e=' + count + '; if(e>n)e=n; for(i=1;i<=e;i++)print rows[i] }';
      prog = 'BEGIN{FS=US;OFS=US}\nNR==1{ print; next }\n{ rows[++n]=$0 }\n' + end;
      return label + '\n' + awkStep(prog, wf(ins['in']), node.id);
    }
    case 'transform.index': {
      const start = cfg.start != null ? parseInt(cfg.start, 10) : 1;
      prog = 'BEGIN{FS=US;OFS=US; idx=' + start + '}\nNR==1{ print $0 OFS ' + aws(String(cfg.name || 'Index')) + '; next }\n{ print $0 OFS idx; idx++ }';
      return label + '\n' + awkStep(prog, wf(ins['in']), node.id);
    }
    case 'transform.replace': {
      const colName = aws(String(cfg.column));
      const find = aws(cfg.find != null ? String(cfg.find) : '');
      const repl = aws(cfg.replaceWith != null ? String(cfg.replaceWith) : '');
      const apply = cfg.wholeCell
        ? 'if(tolower(v)==tolower(' + find + ')) v=' + repl + ';'
        : 'v=lit_replace(v,' + find + ',' + repl + ');';
      prog = 'BEGIN{FS=US;OFS=US}\nNR==1{ for(i=1;i<=NF;i++)c[$i]=i; print; next }\n{ ci=c[' + colName + ']; if(ci){ v=$ci; ' + apply + ' $ci=v } print }';
      return label + '\n' + awkStep(prog, wf(ins['in']), node.id);
    }
    case 'transform.fill': {
      const loop = String(cfg.direction) === 'Up' ? 'for(i=rn;i>=1;i--)' : 'for(i=1;i<=rn;i++)';
      const blocks = (cfg.columns || []).map(cn =>
        'ci=c[' + aws(String(cn)) + ']; if(ci){ last=""; ' + loop + '{ if(cell[i,ci]==""){ if(last!="") cell[i,ci]=last } else last=cell[i,ci] } }'
      ).join(' ');
      prog = 'BEGIN{FS=US;OFS=US}\n'
           + 'NR==1{ for(i=1;i<=NF;i++)c[$i]=i; nf=NF; print; next }\n'
           + '{ rn++; for(j=1;j<=nf;j++) cell[rn,j]=$j }\n'
           + 'END{ ' + blocks + ' for(i=1;i<=rn;i++){ line=cell[i,1]; for(j=2;j<=nf;j++) line=line OFS cell[i,j]; print line } }';
      return label + '\n' + awkStep(prog, wf(ins['in']), node.id);
    }
    case 'transform.conditional': {
      let body = 'matched=0; res="";\n';
      (cfg.rules || []).forEach(r => {
        body += 'if(!matched && (' + condExpr(r) + ')){ res=' + deriveExpr(String(r.result == null ? '' : r.result)) + '; matched=1 }\n';
      });
      body += 'if(!matched){ res=' + deriveExpr(String(cfg['else'] == null ? '' : cfg['else'])) + ' }\n';
      prog = 'BEGIN{FS=US;OFS=US}\n' + header('print $0 OFS ' + aws(String(cfg.name)) + ';') + '\n{ ' + body + ' print $0 OFS res }';
      return label + '\n' + awkStep(prog, wf(ins['in']), node.id);
    }
    case 'transform.text': {
      const col = aws(String(cfg.column));
      const op = aws(String(cfg.op || 'trim'));
      const find = aws(cfg.find != null ? String(cfg.find) : '');
      const find2 = aws(cfg.find2 != null ? String(cfg.find2) : '');
      const as = cfg.as ? String(cfg.as) : '';
      const headExtra = as ? ('print $0 OFS ' + aws(as) + ';') : 'print;';
      const dataLine = as ? 'print $0 OFS v' : 'if(ci)$ci=v; print';
      prog = 'BEGIN{FS=US;OFS=US}\n'
           + 'NR==1{ for(i=1;i<=NF;i++)c[$i]=i; ' + headExtra + ' next }\n'
           + '{ ci=c[' + col + ']; v=(ci?txt_op($ci,' + op + ',' + find + ',' + find2 + '):""); ' + dataLine + ' }';
      return label + '\n' + awkStep(prog, wf(ins['in']), node.id);
    }
    case 'transform.union': {
      const sources = (def.edges || []).filter(e => e.to === node.id).map(e => e.from);
      const files = sources.map(s => wf(s)).join(' ');
      prog = 'BEGIN{FS=US;OFS=US}\n'
           + 'FNR==1{ fno++; nf[fno]=NF; for(i=1;i<=NF;i++){ hdr[fno,i]=$i; if(!($i in cseen)){ cseen[$i]=1; ucol[++uc]=$i } } next }\n'
           + '{ rn++; for(i=1;i<=nf[fno];i++) cell[rn,hdr[fno,i]]=$i }\n'
           + 'END{ line=ucol[1]; for(j=2;j<=uc;j++) line=line OFS ucol[j]; print line; '
           + 'for(r=1;r<=rn;r++){ out=""; for(j=1;j<=uc;j++){ k=r SUBSEP ucol[j]; v=(k in cell)?cell[k]:""; out=out (j>1?OFS:"") v } print out } }';
      return label + '\n' + awkStep(prog, files, node.id);
    }
    case 'transform.date': {
      // Self-implemented JDN + ISO-ish parse so the result is identical to the other engines.
      const DATEFNS =
        'function jdn(y,m,d,  a,y2,m2){a=int((14-m)/12);y2=y+4800-a;m2=m+12*a-3;return d+int((153*m2+2)/5)+365*y2+int(y2/4)-int(y2/100)+int(y2/400)-32045}\n' +
        'function dparse(s,  t,n,arr){t=s;sub(/^[ \\t]+/,"",t);if(t !~ /^[0-9][0-9][0-9][0-9][^0-9]+[0-9]+[^0-9]+[0-9]+/)return 0;n=split(t,arr,/[^0-9]+/);DY=arr[1]+0;DM=arr[2]+0;DD=arr[3]+0;return 1}\n' +
        'function dfmt(y,m,d,f){if(f=="yyyy/MM/dd")return sprintf("%04d/%02d/%02d",y,m,d);if(f=="MM/dd/yyyy")return sprintf("%02d/%02d/%04d",m,d,y);if(f=="dd/MM/yyyy")return sprintf("%02d/%02d/%04d",d,m,y);if(f=="yyyyMMdd")return sprintf("%04d%02d%02d",y,m,d);if(f=="yyyy-MM")return sprintf("%04d-%02d",y,m);return sprintf("%04d-%02d-%02d",y,m,d)}\n';
      const dcol = aws(String(cfg.column));
      const op = String(cfg.op || 'year');
      const tgt = aws(cfg.as ? String(cfg.as) : String(cfg.column));
      let setR;
      switch (op) {
        case 'month':    setR = 'r=DM;'; break;
        case 'day':      setR = 'r=DD;'; break;
        case 'weekday':  setR = 'r=(jdn(DY,DM,DD)%7)+1;'; break;
        case 'format':   setR = 'r=dfmt(DY,DM,DD,' + aws(String(cfg.format || 'yyyy-MM-dd')) + ');'; break;
        case 'diffdays': setR = 'jd=jdn(DY,DM,DD); ci2=c[' + aws(String(cfg.column2 || '')) + ']; if(dparse($(ci2))) r=jd-jdn(DY,DM,DD); else r="";'; break;
        default:         setR = 'r=DY;';
      }
      prog = DATEFNS + 'BEGIN{FS=US;OFS=US}\n'
           + 'NR==1{ for(i=1;i<=NF;i++)c[$i]=i; if(' + tgt + ' in c) print $0; else print $0 OFS ' + tgt + '; next }\n'
           + '{ ci=c[' + dcol + ']; r=""; if(dparse($(ci))){ ' + setR + ' } ti=(' + tgt + ' in c)?c[' + tgt + ']:0; if(ti){ $(ti)=r; print } else { print $0 OFS r } }';
      return label + '\n' + awkStep(prog, wf(ins['in']), node.id);
    }
    case 'transform.cast': {
      const ccol = aws(String(cfg.column));
      const to = String(cfg.to || 'text');
      const castBody = to === 'number' ? 'if(is_num(v)) v=v+0;' : (to === 'integer' ? 'if(is_num(v)) v=int(v+0);' : '');
      prog = 'BEGIN{FS=US;OFS=US;CONVFMT="%.15g";OFMT="%.15g"}\n'
           + 'NR==1{ for(i=1;i<=NF;i++)c[$i]=i; print; next }\n'
           + '{ ci=c[' + ccol + ']; if(ci){ v=$(ci); ' + castBody + ' $(ci)=v } print }';
      return label + '\n' + awkStep(prog, wf(ins['in']), node.id);
    }
    case 'transform.unpivot': {
      const keepInit = (cfg.keep || []).map(k => 'keep[' + aws(String(k)) + ']=1;').join(' ');
      const attr = aws(String(cfg.attributeName || 'Attribute'));
      const val = aws(String(cfg.valueName || 'Value'));
      prog = 'BEGIN{FS=US;OFS=US; ' + keepInit + '}\n'
           + 'NR==1{ for(i=1;i<=NF;i++) name[i]=$i; kn=0; vn=0; for(i=1;i<=NF;i++){ if($i in keep){ ki[++kn]=i } else { vi[++vn]=i } } '
           + 'h=""; for(j=1;j<=kn;j++) h=h (j>1?OFS:"") name[ki[j]]; if(kn>0) h=h OFS; h=h ' + attr + ' OFS ' + val + '; print h; next }\n'
           + '{ for(v=1;v<=vn;v++){ line=""; for(j=1;j<=kn;j++) line=line (j>1?OFS:"") $(ki[j]); if(kn>0) line=line OFS; line=line name[vi[v]] OFS $(vi[v]); print line } }';
      return label + '\n' + awkStep(prog, wf(ins['in']), node.id);
    }
    case 'transform.pivot':
      throw new Error("Pivot is not supported in the shell target (its output columns are data-dependent); use the PowerShell or M target for node '" + node.id + "'.");
    case 'transform.join': {
      const jt = String(cfg.joinType || 'Inner');
      const right = wf(ins['right']), left = wf(ins['left']);
      prog = 'BEGIN{FS=US;OFS=US}\n'
           + 'function emit(lrow,rrow,  i,la,ra,o){ if(lrow!=""){split(lrow,la,US)}else{for(i=1;i<=lnf;i++)la[i]=""} if(rrow!=""){split(rrow,ra,US)}else{for(i=1;i<=rnf;i++)ra[i]=""} o=""; for(i=1;i<=lnf;i++)o=o (i>1?OFS:"") la[i]; for(i=1;i<=rnf;i++)o=o OFS ra[i]; print o }\n'
           + 'FNR==NR{ if(FNR==1){ rnf=NF; for(i=1;i<=NF;i++){rh[i]=$i;ridx[$i]=i}; next } rk=$(ridx[' + aws(String(cfg.rightKey)) + ']); rn[rk]++; rrows[rk,rn[rk]]=$0; next }\n'
           + 'FNR==1{ lnf=NF; for(i=1;i<=NF;i++){lh[i]=$i;lidx[$i]=i;lname[$i]=1} h=""; for(i=1;i<=lnf;i++)h=h (i>1?OFS:"") lh[i]; for(i=1;i<=rnf;i++){nm=rh[i]; if(nm in lname)nm="Right_" nm; h=h OFS nm} print h; next }\n'
           + '{ lk=$(lidx[' + aws(String(cfg.leftKey)) + ']); if(lk in rn){ matched[lk]=1; for(m=1;m<=rn[lk];m++) emit($0,rrows[lk,m]) } else if(' + aws(jt) + '=="Left"||' + aws(jt) + '=="Full"){ emit($0,"") } }\n'
           + 'END{ if(' + aws(jt) + '=="Right"||' + aws(jt) + '=="Full"){ for(k in rn){ if(!(k in matched)) for(m=1;m<=rn[k];m++) emit("",rrows[k,m]) } } }';
      return label + '\n' + awkStep(prog, right + ' ' + left, node.id);
    }
    case 'transform.aggregate': {
      const gb = (cfg.groupBy || []).map(String);
      const aggs = (cfg.aggregations || []);
      const keyExpr = gb.map(col).join(' US ');
      const saveG = gb.map((g, i) => 'g' + i + '[key]=' + col(g)).join('; ');
      const headOut = gb.map(aws).concat(aggs.map(a => aws(String(a.as || (a.function + '_' + a.column))))).join(' OFS ');
      // accumulators
      let acc = '', medFns = '';
      aggs.forEach((a, i) => {
        const f = col(a.column), fn = String(a.function);
        if (fn === 'Count') acc += '';
        else if (fn === 'First') acc += 'if(!(key in cnt)) first' + i + '[key]=' + f + '; ';
        else if (fn === 'CountDistinct') acc += '{ dk=key SUBSEP tolower(' + f + '); if(!(dk in dseen' + i + ')){ dseen' + i + '[dk]=1; dc' + i + '[key]++ } } ';
        else if (fn === 'StringJoin') acc += '{ if(key in sj' + i + ') sj' + i + '[key]=sj' + i + '[key] ", " ' + f + '; else sj' + i + '[key]=' + f + ' } ';
        else if (fn === 'Median') {
          acc += 'if(is_num(' + f + ')) mv' + i + '[key, ++mn' + i + '[key]]=' + f + '+0; ';
          medFns += 'function med' + i + '(k,  a,n,j,p,t){ n=mn' + i + '[k]+0; for(j=1;j<=n;j++) a[j]=mv' + i + '[k,j]; for(p=2;p<=n;p++){ t=a[p]; j=p-1; while(j>=1 && a[j]>t){ a[j+1]=a[j]; j-- } a[j+1]=t } if(n==0) return ""; if(n%2==1) return a[int((n+1)/2)]; return (a[int(n/2)]+a[int(n/2)+1])/2 }\n';
        }
        else acc += 'if(is_num(' + f + ')){ v=' + f + '+0; if(!(key in nseen' + i + ')){ nseen' + i + '[key]=1; s' + i + '[key]=v; mn' + i + '[key]=v; mx' + i + '[key]=v; sc' + i + '[key]=1 } else { s' + i + '[key]+=v; if(v<mn' + i + '[key])mn' + i + '[key]=v; if(v>mx' + i + '[key])mx' + i + '[key]=v; sc' + i + '[key]++ } } ';
      });
      let outFields = gb.map((g, i) => 'g' + i + '[k]');
      aggs.forEach((a, i) => {
        const fn = String(a.function);
        if (fn === 'Count') outFields.push('cnt[k]');
        else if (fn === 'Sum') outFields.push('(s' + i + '[k]+0)');
        else if (fn === 'Average') outFields.push('(sc' + i + '[k]?(s' + i + '[k]/sc' + i + '[k]):"")');
        else if (fn === 'Min') outFields.push('((k in mn' + i + ')?mn' + i + '[k]:"")');
        else if (fn === 'Max') outFields.push('((k in mx' + i + ')?mx' + i + '[k]:"")');
        else if (fn === 'First') outFields.push('first' + i + '[k]');
        else if (fn === 'CountDistinct') outFields.push('(k in dc' + i + '?dc' + i + '[k]:0)');
        else if (fn === 'StringJoin') outFields.push('(k in sj' + i + '?sj' + i + '[k]:"")');
        else if (fn === 'Median') outFields.push('med' + i + '(k)');
        else throw new Error("Unknown aggregate function '" + a.function + "'.");
      });
      prog = medFns + 'BEGIN{FS=US;OFS=US}\n'
           + 'NR==1{ for(i=1;i<=NF;i++)c[$i]=i; print ' + headOut + '; next }\n'
           + '{ key=' + keyExpr + '; if(!(key in cnt0)){ cnt0[key]=1; order[++no]=key; ' + saveG + ' } '
           + acc + ' cnt[key]++ }\n'
           + 'END{ for(i=1;i<=no;i++){ k=order[i]; print ' + outFields.join(' OFS ') + ' } }';
      return label + '\n' + awkStep(prog, wf(ins['in']), node.id);
    }
    case 'output.csv': {
      const d = cfg.delimiter ? String(cfg.delimiter) : ',';
      const dest = String(cfg.path);
      const dir = dest.replace(/[\\/][^\\/]*$/, '');
      const mk = (dir && dir !== dest) ? 'mkdir -p ' + shellPath(dir.replace(/\\/g, '/')) + '\n' : '';
      prog = 'BEGIN{FS=US}\n{ o=""; for(i=1;i<=NF;i++) o=o (i>1?' + aws(d) + ':"") csv_quote($i); print o }';
      return label + '\n' + mk + 'awk -v US="$US" "$AWKLIB"\'\n' + prog + '\n\' ' + wf(ins['in']) + ' > ' + shellPath(dest.replace(/\\/g, '/'));
    }
    default:
      throw new Error("Unknown node type '" + t + "'.");
  }
}

function generateShellBody(def) {
  const order = topoOrder(def);
  const byId = {}; for (const n of def.nodes) byId[n.id] = n;
  return order.map(id => genNode(def, byId[id])).join('\n\n');
}

// CLI harness (Node only):  node shellgen.js <runtime.sh> <pipeline.json>
// Guarded so this same file also runs when embedded in the browser, where it
// just defines generateShellScript/generateShellBody as globals.
if (typeof require !== 'undefined' && typeof module !== 'undefined' && require.main === module) {
  const fs = require('fs');
  const runtime = fs.readFileSync(process.argv[2], 'utf8');
  const def = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
  process.stdout.write(generateShellScript(def, runtime));
}
if (typeof module !== 'undefined' && module.exports) {
  module.exports = { generateShellScript, generateShellBody };
}
