# ---------------------------------------------------------------------------
# PSPipeline shell runtime -- the *nix analog of Core/PipelineFunctions.ps1.
# Inlined into every generated POSIX sh + awk script as its engine library
# (after the generated header/usage, before the compiled pipeline body).
#
# Hard constraints (mirror the PowerShell engine's):
#   * POSIX sh + POSIX awk only -- no bash-isms, no gawk extensions, so it runs
#     on busybox/mawk/nawk as well as gawk. No installs, no network.
#   * Intermediate data between nodes is unit-separator (US, 0x1F) delimited with
#     a header row first, so commas/tabs inside data never clash between steps.
#     Only input nodes parse the source format; only output nodes emit it.
#
# String comparisons are case-insensitive to match the PowerShell engine
# (PowerShell -eq/-lt/-like and Sort-Object are case-insensitive by default).
#
# The generated header supplies the shebang, "set -eu", --help, and the BASE
# directory; this fragment defines the work area and the awk helper library.
# ---------------------------------------------------------------------------
WORK="$(mktemp -d 2>/dev/null || mktemp -d -t pspl)"
trap 'rm -rf "$WORK"' EXIT INT TERM
US=$(printf '\037')

AWKLIB='
function trim(s){ sub(/^[ \t\r\n]+/,"",s); sub(/[ \t\r\n]+$/,"",s); return s }
function is_num(x){ return (x ~ /^[ \t]*[-+]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][-+]?[0-9]+)?[ \t]*$/) }
function cmp(a,b){ if(is_num(a)&&is_num(b)){a+=0;b+=0;return (a<b)?-1:(a>b?1:0)} a=tolower(a);b=tolower(b);return (a<b)?-1:(a>b?1:0) }
function op_eq(a,b){ return (is_num(a)&&is_num(b)) ? (a+0==b+0) : (tolower(a)==tolower(b)) }
function csv_split(line, D, arr,   n,i,c,field,len,inq){
  n=0; field=""; len=length(line); inq=0
  for(i=1;i<=len;i++){ c=substr(line,i,1)
    if(inq){ if(c=="\""){ if(substr(line,i+1,1)=="\""){field=field "\"";i++} else inq=0 } else field=field c }
    else { if(c=="\""){inq=1} else if(c==D){n++;arr[n]=field;field=""} else field=field c }
  }
  n++; arr[n]=field; return n
}
function csv_quote(s){ gsub(/"/,"\"\"",s); return "\"" s "\"" }
function lit_replace(s, from, to,   out,p,flen){
  if(from=="") return s
  out=""; flen=length(from)
  while((p=index(s,from))>0){ out=out substr(s,1,p-1) to; s=substr(s,p+flen) }
  return out s
}
function txt_before(s,d,  i){ if(d=="")return ""; i=index(s,d); return (i>0)?substr(s,1,i-1):"" }
function txt_after(s,d,  i){ if(d=="")return ""; i=index(s,d); return (i>0)?substr(s,i+length(d)):"" }
function txt_between(s,a,b,  i,start,tail,j){ if(a=="")return ""; i=index(s,a); if(i==0)return ""; start=i+length(a); tail=substr(s,start); if(b=="")return tail; j=index(tail,b); return (j>0)?substr(tail,1,j-1):tail }
function txt_title(s,  n,w,i,out){ n=split(tolower(s),w,/ /); out=""; for(i=1;i<=n;i++){ if(length(w[i])>0) w[i]=toupper(substr(w[i],1,1)) substr(w[i],2); out=out (i>1?" ":"") w[i] } return out }
function txt_op(s,op,a,b){ if(op=="lower")return tolower(s); if(op=="upper")return toupper(s); if(op=="title")return txt_title(s); if(op=="before")return txt_before(s,a); if(op=="after")return txt_after(s,a); if(op=="between")return txt_between(s,a,b); return trim(s) }
'
# --- compiled pipeline body follows ---
